import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/apple_tv.dart';
import '../../../core/error/exceptions.dart';
import '../../../core/error/network_failure.dart';
import '../../../core/lnreader/novel_cloudflare.dart';
import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/app_mode.dart';
import '../../../core/di/injector.dart';
import '../../../core/mode/content_mode.dart';
import '../../../core/mode/content_mode_cubit.dart';
import '../../../core/repository/catalogue_repository.dart';
import '../../../core/zmode/metadata_repository.dart';
import '../../../core/zmode/zmode_module.dart';
import '../../../core/zmode/zmode_prefs.dart';

/// Immutable view-state for the Home screen. The rows are CloudStream-style:
/// the active provider decides what sections exist (and what they're named),
/// so the cubit just holds whatever [SourceRepository.home] returns.
///
/// A null [sections] means "not yet loaded OR failed". The first section also
/// feeds the hero carousel via [heroItems]; the screen renders the remaining
/// sections as browse rows.
class HomeState extends Equatable {
  const HomeState({
    this.sections,
    this.loading = false,
    this.cloudflareUrl,
    this.offline = false,
  });

  /// The provider's named home rows, in order. Null until the first load.
  final List<HomeSection>? sections;

  /// True while the rows are being (re)fetched.
  final bool loading;

  /// Set when the active (Mihon) source is blocked by a Cloudflare challenge the
  /// headless solver couldn't pass — the URL to open in the visible WebView
  /// solve. Null in every other state. Drives the "Solve Cloudflare" empty view.
  final String? cloudflareUrl;

  /// The last load failed because the request never left the device — no
  /// route, DNS down, captive portal. Distinct from a source that answered
  /// with nothing: both used to render as "this source returned nothing",
  /// which sent people to reinstall extensions over a dropped connection.
  final bool offline;

  /// Items that drive the hero carousel — the first section's items. Empty
  /// until something loads.
  List<MediaItem> get heroItems => (sections != null && sections!.isNotEmpty)
      ? sections!.first.items
      : const [];

  HomeState copyWith({
    List<HomeSection>? sections,
    bool? loading,
    String? cloudflareUrl,
    bool? offline,
  }) => HomeState(
    sections: sections ?? this.sections,
    loading: loading ?? this.loading,
    cloudflareUrl: cloudflareUrl ?? this.cloudflareUrl,
    offline: offline ?? this.offline,
  );

  @override
  List<Object?> get props => [sections, loading, cloudflareUrl, offline];
}

/// Owns the Home rows. Delegates entirely to [SourceRepository.home], which
/// returns the active provider's own sections (or a default set for providers
/// without `getHome`). No `sourceId` is passed — `home` uses the active source
/// by design, so a source switch simply re-runs [load].
class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._repo) : super(const HomeState());

  final CatalogueRepository _repo;

  /// Monotonic load id. Each [load] bumps it; a fetch only emits its result if
  /// it's still the latest. This makes source switches "latest wins" — a slow
  /// previous-source fetch can't land after a newer switch and clobber the UI.
  int _gen = 0;

  /// Last fetched metadata rows per streaming kind — toggling Anime ↔ Movie/TV
  /// can swap instantly instead of waiting on AniList/TMDB again.
  final Map<StreamKind, List<HomeSection>> _streamKindCache = {};

  /// Bumped when a stream-kind cache is filled without a [HomeState] emit, so
  /// TV can mount the inactive catalogue offstage before the user toggles.
  final ValueNotifier<int> streamCatalogRevision = ValueNotifier(0);

  /// Drop cached rows when the metadata provider changes — the rows themselves
  /// differ between AniList and MAL (etc.).
  void clearStreamKindCache() {
    _streamKindCache.clear();
    if (sl.isRegistered<MetadataRepository>()) {
      sl<MetadataRepository>().clearHomeCache();
    }
  }

  /// Copies prefetched metadata rows into the per-kind cache (from
  /// [MetadataRepository] warm/prefetch — not a public reload API).
  void rememberStreamKindRows(StreamKind kind, List<HomeSection> sections) {
    if (sections.isEmpty) return;
    _streamKindCache[kind] = sections;
    streamCatalogRevision.value++;
    applyMetadataCacheIfEmpty();
  }

  /// Pull any rows [MetadataRepository] already cached (prefetch / warm).
  void primeStreamKindCacheFromMetadata() {
    if (!sl.isRegistered<MetadataRepository>()) return;
    final meta = sl<MetadataRepository>();
    var changed = false;
    for (final kind in StreamKind.values) {
      final zKind = browseKindFor(ContentMode.anime, kind);
      final rows = meta.peekHomeCache(zKind);
      if (rows != null && rows.isNotEmpty) {
        _streamKindCache[kind] = rows;
        changed = true;
      }
    }
    if (changed) {
      streamCatalogRevision.value++;
      applyMetadataCacheIfEmpty();
    }
  }

  /// When metadata home prefetch succeeds after an empty/failed first fetch,
  /// paint the cached rows so Home doesn't stay on "Couldn't load AniList".
  void applyMetadataCacheIfEmpty() {
    if (!ZModePrefs.enabled || isClosed) return;
    if (state.loading) return;
    if (state.sections != null && state.sections!.isNotEmpty) return;
    if (!sl.isRegistered<ContentModeCubit>() ||
        sl<ContentModeCubit>().state != ContentMode.anime) {
      return;
    }
    final rows = _cachedRowsForStreamKind(ZModePrefs.streamKind);
    if (rows == null || rows.isEmpty) return;
    debugPrint(
      '[home] apply metadata cache · kind=${ZModePrefs.streamKind} '
      '· ${rows.length} rows',
    );
    emit(
      HomeState(
        sections: rows,
        loading: false,
        cloudflareUrl: state.cloudflareUrl,
      ),
    );
  }

  /// True when the cubit has no paintable rows — including a check of the
  /// metadata stream cache, which can fill while [sections] is still empty.
  bool get showsEmptyHome {
    if (state.loading) {
      debugPrint('[home] showsEmptyHome → false (still loading)');
      return false;
    }
    if (state.sections != null && state.sections!.isNotEmpty) {
      debugPrint(
        '[home] showsEmptyHome → false '
        '(${state.sections!.length} sections)',
      );
      return false;
    }
    if (ZModePrefs.enabled &&
        sl.isRegistered<ContentModeCubit>() &&
        sl<ContentModeCubit>().state == ContentMode.anime) {
      final cached = sectionsFor(ZModePrefs.streamKind);
      if (cached != null && cached.isNotEmpty) {
        debugPrint(
          '[home] showsEmptyHome → false '
          '(metadata cache: ${cached.length} rows for '
          '${ZModePrefs.streamKind})',
        );
        return false;
      }
    }
    debugPrint(
      '[home] showsEmptyHome → true '
      '(sections=${state.sections?.length ?? "null"} '
      'zMode=${ZModePrefs.enabled})',
    );
    return state.sections != null && state.sections!.isEmpty;
  }

  /// Cached rows for [kind], if a previous load/prefetch already has them.
  List<HomeSection>? sectionsFor(StreamKind kind) =>
      _cachedRowsForStreamKind(kind);

  List<HomeSection>? _cachedRowsForStreamKind(StreamKind kind) {
    final hit = _streamKindCache[kind];
    if (hit != null) return hit;
    if (!sl.isRegistered<MetadataRepository>()) return null;
    final zKind = browseKindFor(ContentMode.anime, kind);
    final rows = sl<MetadataRepository>().peekHomeCache(zKind);
    if (rows != null && rows.isNotEmpty) {
      _streamKindCache[kind] = rows;
    }
    return rows;
  }

  /// Anime ↔ Movie/TV flip. Keeps the previous rows on screen when there is no
  /// cache yet; shows cached rows immediately when revisiting a kind.
  Future<void> loadForStreamKindChange() async {
    if (!sl.isRegistered<ContentModeCubit>() ||
        sl<ContentModeCubit>().state != ContentMode.anime) {
      return load(reset: true);
    }
    final kind = ZModePrefs.streamKind;
    final sw = Stopwatch()..start();
    final tv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    debugPrint('[home] stream kind → $kind');
    final gen = ++_gen;
    final cached = _cachedRowsForStreamKind(kind);
    if (cached != null) {
      debugPrint(
        '[home] stream kind ← $kind · cache hit · ${sw.elapsedMilliseconds}ms',
      );
      // Phone Home reads cubit.state.sections. TV keeps both catalogues
      // mounted and swaps with [ZModePrefs.revision] — emitting here would
      // rebuild the 10-foot hero + every poster and freeze for seconds.
      if (!tv) {
        emit(HomeState(sections: cached, loading: false));
      }
      return;
    }
    emit(state.copyWith(loading: true));
    await _fetchHome(gen: gen, logLabel: 'stream kind ← $kind', sw: sw);
  }

  /// (Re)load the rows. Emits `loading: true` (keeping any existing sections so
  /// rows don't flash empty), fetches the provider's home, and emits the fresh
  /// result. A total failure yields an empty section list rather than throwing.
  /// [reset] clears the current rows first (used on a source switch) so the UI
  /// shows loading skeletons for the NEW source instead of lingering on the old
  /// source's content while the (possibly slow) fetch runs.
  Future<void> load({bool reset = false}) async {
    final gen = ++_gen;
    final sourceId = _repo.sourceId;
    final sw = Stopwatch()..start();
    debugPrint('[home] load(reset=$reset) · source=$sourceId');
    emit(
      reset ? const HomeState(loading: true) : state.copyWith(loading: true),
    );

    if (isAppleTv && !_repo.hasSource(sourceId)) {
      if (isClosed || gen != _gen) return;
      emit(const HomeState(sections: [], loading: false));
      debugPrint(
        '[home] load done · source=$sourceId · no provider · ${sw.elapsedMilliseconds}ms',
      );
      return;
    }

    await _fetchHome(
      gen: gen,
      logLabel: 'load done · source=$sourceId',
      sw: sw,
    );
  }

  void _rememberStreamKindCache(List<HomeSection> sections) {
    if (!ZModePrefs.enabled || sections.isEmpty) return;
    if (!sl.isRegistered<ContentModeCubit>() ||
        sl<ContentModeCubit>().state != ContentMode.anime) {
      return;
    }
    _streamKindCache[ZModePrefs.streamKind] = sections;
  }

  Future<void> _fetchHome({
    required int gen,
    required String logLabel,
    required Stopwatch sw,
  }) async {
    List<HomeSection> sections;
    String? cloudflareUrl;
    var offline = false;
    try {
      final homeFuture = _repo.home();
      sections = isAppleTv
          ? await homeFuture.timeout(const Duration(seconds: 20))
          : await homeFuture;
    } on TimeoutException catch (_) {
      debugPrint(
        '[home] $logLabel · timed out after ${sw.elapsedMilliseconds}ms',
      );
      sections = const <HomeSection>[];
      offline = true; // nothing came back at all — same story as no route
    } on CloudflareRequiredException catch (e) {
      debugPrint(
        '[home] $logLabel · needs Cloudflare · ${sw.elapsedMilliseconds}ms',
      );
      sections = const <HomeSection>[];
      cloudflareUrl = e.url;
    } catch (e, st) {
      debugPrint(
        '[home] $logLabel · failed · $e · ${sw.elapsedMilliseconds}ms\n$st',
      );
      sections = const <HomeSection>[];
      offline = await isOfflineErrorConfirmed(e);
    }

    // A novel plugin catches its own fetch errors and returns nothing, so a
    // Cloudflare challenge arrives as an empty list rather than an exception.
    // Pick it up from the latch so the solve prompt still appears. Only when
    // there is genuinely nothing to show, so a source that partly worked is
    // never interrupted.
    if (cloudflareUrl == null && sections.isEmpty) {
      cloudflareUrl = NovelCloudflare.pendingUrl;
    }
    if (sections.isNotEmpty) NovelCloudflare.clear();

    // A newer load started while we were fetching — discard this stale result.
    if (isClosed || gen != _gen) return;
    _rememberStreamKindCache(sections);
    emit(
      HomeState(
        sections: sections,
        loading: false,
        cloudflareUrl: cloudflareUrl,
        // Only meaningful when nothing came back: a partial load that hit one
        // bad row is not an offline screen.
        offline: offline && sections.isEmpty,
      ),
    );
    debugPrint(
      '[home] $logLabel · ${sections.length} rows · ${sw.elapsedMilliseconds}ms',
    );
  }
}
