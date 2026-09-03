import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/platform/apple_tv.dart';
import '../../../core/error/exceptions.dart';
import '../../../core/error/network_failure.dart';
import '../../../core/lnreader/novel_cloudflare.dart';
import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/repository/catalogue_repository.dart';

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

    if (isAppleTv && !_repo.hasSource(sourceId)) {
      if (isClosed || gen != _gen) return;
      emit(const HomeState(sections: [], loading: false));
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
      ),
    );
  }
}
