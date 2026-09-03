import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../core/app_mode.dart';
import '../../../core/error/exceptions.dart';
import '../../../core/error/network_failure.dart';
import '../../../core/lnreader/novel_cloudflare.dart';
import '../../../core/models/home_row.dart';
import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/mode/content_mode.dart';
import '../../../core/mode/content_mode_cubit.dart';
import '../../../core/platform/apple_tv.dart';
import '../../../core/repository/catalogue_repository.dart';
import '../../../core/tracker/tracker.dart';
import '../../../core/tracker/tracker_hub.dart';
import '../../../core/ui/home_rows_prefs.dart';
import '../../../core/zmode/metadata_provider_prefs.dart';
import '../../../core/zmode/zmode_ids.dart';
import '../../../core/zmode/zmode_module.dart' show browseKindFor;
import '../../../core/zmode/zmode_prefs.dart';
import 'home_rows_composer.dart';
import 'tracker_home_rows.dart';

final _sl = GetIt.instance;

/// Immutable view-state for the Home screen. The rows are CloudStream-style:
/// the active provider decides what sections exist (and what they're named),
/// so the cubit just holds whatever [SourceRepository.home] returns.
///
/// A null [sections] means "not yet loaded OR failed". The first section also
/// feeds the hero carousel via [heroItems]; the screen renders the remaining
/// sections as browse rows.
///
/// [rows] is the merged, user-arranged view of the same load: local continue
/// row, tracker rows (when enabled in Settings → Interface → Home rows) and
/// the provider sections, in the saved order. Additive on top of [sections],
/// which stays the raw fetch so the empty/offline/hero logic is unchanged.
class HomeState extends Equatable {
  const HomeState({
    this.sections,
    this.loading = false,
    this.cloudflareUrl,
    this.offline = false,
    this.rows,
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

  /// The merged arrangement the screens render. Null until the first load
  /// completes (skeletons show meanwhile), kept as-is across reloads so a
  /// refresh never flashes the rows away.
  final List<HomeRow>? rows;

  /// Items that drive the hero carousel. Prefers the Trending section — the
  /// banner is a trending spotlight, same as every catalogue names one (Simkl
  /// prefixes its titles, hence the startsWith) — so the opening row can be
  /// something else (recently released) without changing what the banner
  /// shows. Falls back to the first section for sources with no Trending row
  /// (CloudStream feeds, Aniyomi/Mihon Popular), which is every non-Z source.
  /// Empty until something loads.
  List<MediaItem> get heroItems {
    final s = sections;
    if (s == null || s.isEmpty) return const [];
    for (final section in s) {
      if (section.title.startsWith('Trending')) return section.items;
    }
    return s.first.items;
  }

  HomeState copyWith({
    List<HomeSection>? sections,
    bool? loading,
    String? cloudflareUrl,
    bool? offline,
    List<HomeRow>? rows,
  }) => HomeState(
    sections: sections ?? this.sections,
    loading: loading ?? this.loading,
    cloudflareUrl: cloudflareUrl ?? this.cloudflareUrl,
    offline: offline ?? this.offline,
    rows: rows ?? this.rows,
  );

  @override
  List<Object?> get props => [sections, loading, cloudflareUrl, offline, rows];
}

/// Owns the Home rows. Delegates entirely to [SourceRepository.home], which
/// returns the active provider's own sections (or a default set for providers
/// without `getHome`). No `sourceId` is passed — `home` uses the active source
/// by design, so a source switch simply re-runs [load].
///
/// The tracker library for the tracker-driven rows is read through
/// [TrackerHub] (optional so existing tests and DI setups keep working) and
/// cached for the session; connecting or disconnecting a tracker invalidates
/// the cache and re-merges.
class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._repo, {TrackerHub? trackerHub})
    : _hub = trackerHub,
      super(const HomeState());

  final CatalogueRepository _repo;
  final TrackerHub? _hub;

  TrackerHub? get _hubOrNull =>
      _hub ?? (_sl.isRegistered<TrackerHub>() ? _sl<TrackerHub>() : null);

  /// Monotonic load id. Each [load] bumps it; a fetch only emits its result if
  /// it's still the latest. This makes source switches "latest wins" — a slow
  /// previous-source fetch can't land after a newer switch and clobber the UI.
  int _gen = 0;

  /// Session cache of the tracker library, per tracker display name, so
  /// revisiting Home (or re-merging after an arrangement change) doesn't
  /// re-read the whole list. Cleared when a tracker connects/disconnects.
  (String, List<TrackerListItem>)? _trackerCache;

  /// Last-seen connection flags, so a tracker's ChangeNotifier only counts
  /// when connectivity actually flipped (it also fires for avatar/name
  /// refreshes, which must not reload Home).
  final _trackerConnected = <String, bool>{};

  bool _watchingTrackers = false;
  void _watchTrackersOnce(TrackerHub hub) {
    if (_watchingTrackers) return;
    _watchingTrackers = true;
    for (final t in hub.trackers) {
      _trackerConnected[t.displayName] = t.isConnected;
      t.addListener(() {
        final now = t.isConnected;
        if (_trackerConnected[t.displayName] == now) return;
        _trackerConnected[t.displayName] = now;
        _trackerCache = null;
        load(reset: false);
      });
    }
  }

  /// The Z Mode browse kind for this load, or null when the home is
  /// source-backed. Read per load (not cached) because mode and stream kind
  /// change under the cubit without a new registration.
  ZKind? get _browseKind {
    if (!ZModePrefs.enabled) return null;
    final mode = _sl.isRegistered<ContentModeCubit>()
        ? _sl<ContentModeCubit>().state
        : ContentMode.anime;
    return browseKindFor(mode, ZModePrefs.streamKind);
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
    emit(
      reset ? const HomeState(loading: true) : state.copyWith(loading: true),
    );

    // Tracker pick + fetch start alongside the provider fetch, so the two
    // never serialize. Best-effort throughout: no tracker, no rows.
    final kind = _browseKind;
    final hub = kind != null ? _hubOrNull : null;
    Tracker? tracker;
    Future<List<TrackerListItem>>? libraryFuture;
    if (hub != null && kind != null) {
      _watchTrackersOnce(hub);
      tracker = pickHomeTracker(hub, kind);
      if (tracker != null) {
        final cached = _trackerCache;
        libraryFuture = cached != null && cached.$1 == tracker.displayName
            ? Future.value(cached.$2)
            : tracker
                  .fetchList()
                  .timeout(
                    const Duration(seconds: 12),
                    onTimeout: () => const [],
                  )
                  .catchError((_) => const <TrackerListItem>[]);
      }
    }

    if (isAppleTv && !_repo.hasSource(sourceId)) {
      if (isClosed || gen != _gen) return;
      emit(const HomeState(sections: [], loading: false, rows: []));
      return;
    }

    List<HomeSection> sections;
    String? cloudflareUrl;
    var offline = false;
    try {
      final homeFuture = _repo.home();
      sections = isAppleTv
          ? await homeFuture.timeout(const Duration(seconds: 20))
          : await homeFuture;
    } on TimeoutException catch (_) {
      debugPrint('[home] load timed out · source=$sourceId');
      sections = const <HomeSection>[];
      offline = true; // nothing came back at all — same story as no route
    } on CloudflareRequiredException catch (e) {
      debugPrint('[home] load needs Cloudflare · source=$sourceId');
      sections = const <HomeSection>[];
      cloudflareUrl = e.url;
    } catch (e, st) {
      debugPrint('[home] load failed · source=$sourceId · $e\n$st');
      sections = const <HomeSection>[];
      offline = await isOfflineErrorConfirmed(e);
    }

    // The tracker read finishes on its own; a miss just means no tracker rows
    // this load (the provider rows are independent of it).
    List<TrackerListItem>? library;
    if (libraryFuture != null) {
      library = await libraryFuture;
      if (tracker != null) {
        _trackerCache = (tracker.displayName, library);
      }
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
    emit(
      HomeState(
        sections: sections,
        loading: false,
        cloudflareUrl: cloudflareUrl,
        // Only meaningful when nothing came back: a partial load that hit one
        // bad row is not an offline screen.
        offline: offline && sections.isEmpty,
        rows: _mergedRows(sections, kind, library, tracker),
      ),
    );
  }

  /// The sanitized, merged arrangement of one load. Pure given its inputs;
  /// kept here (not in the composer) because the layout key and platform
  /// come from app state.
  List<HomeRow> _mergedRows(
    List<HomeSection> sections,
    ZKind? kind,
    List<TrackerListItem>? library,
    Tracker? tracker,
  ) {
    final isTv = _sl.isRegistered<AppMode>() ? _sl<AppMode>().isTv : false;
    final rowSections = providerRowSections(sections, isTv: isTv);
    final withTrackerRows = kind != null;
    final providerPrefs = _sl.isRegistered<MetadataProviderPrefs>()
        ? _sl<MetadataProviderPrefs>()
        : null;
    final layoutKey = layoutKeyFor(
      sourceId: _repo.sourceId,
      zModeOn: kind != null,
      browseKind: kind,
      malPreferred: providerPrefs?.anime == AnimeProvider.mal,
      simklPreferred: providerPrefs?.video == VideoProvider.simkl,
    );
    final available = availableRowIds(
      rowSections,
      withTrackerRows: withTrackerRows,
    );
    final saved = HomeRowsPrefs.savedFor(layoutKey);
    final layout = sanitizeLayout(
      saved ??
          defaultLayout([
            for (final s in rowSections) 'section:${s.title}',
          ], withTrackerRows: withTrackerRows),
      available,
    );
    return mergeHomeRows(
      layout: layout,
      rowSections: rowSections,
      trackerRows: library != null && tracker != null
          ? buildTrackerHomeRows(
              trackerName: tracker.displayName,
              library: library,
              kind: kind!,
            )
          : const [],
    );
  }
}
