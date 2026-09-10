import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../playback/source_health_store.dart';
import '../repository/catalogue_repository.dart';
import '../repository/catalogue_router.dart';
import '../repository/source_repository.dart';
import 'anilist_catalogue.dart';
import 'mal_catalogue.dart';
import 'simkl_catalogue.dart';
import 'metadata_provider_prefs.dart';

import '../ui/app_toast.dart';
import '../ui/global_messenger.dart';
import '../ui/source_switcher.dart';
import 'match_store.dart';
import 'playback_resolver.dart';
import 'source_order_prefs.dart';
import 'zmode_source_prefs.dart';
import 'metadata_repository.dart';
import 'source_matcher.dart';
import 'tmdb_catalogue.dart';
import 'zmode_ids.dart';
import 'zmode_prefs.dart';

/// Everything Z Mode needs, registered in one place.
///
/// Registered even when the toggle is off: the router reads the pref per call,
/// so flipping the toggle never re-registers anything. Call once from
/// `initDependencies`, after `SourceRepository` and `ContentModeCubit`.
Future<void> registerZangetsuMode(GetIt sl) async {
  final matchStore = await MatchStore.open();
  sl.registerSingleton<MatchStore>(matchStore);

  final sourcePrefs = await ZSourcePrefs.open();
  sl.registerSingleton<ZSourcePrefs>(sourcePrefs);

  final sourceOrderPrefs = await SourceOrderPrefs.open();
  sl.registerSingleton<SourceOrderPrefs>(sourceOrderPrefs);

  // Shared by both the matcher (Detail's per-title resolve) and the playback
  // resolver (via MetadataRepository below) so Auto Resolve sweeps — and
  // playback's own health/pin tie-breaks — agree on the user's priority order.
  List<({String id, String name})> orderedCandidates(ZKind kind) {
    // Switched-off sources are dropped HERE and nowhere else: this is the
    // sweep's list. `candidatesForKind` stays whole, so the per-title picker
    // still offers every installed source — turning one off means "stop
    // trying it automatically", not "hide it from me".
    return activeSources(
      sweepOrder(
        candidatesForKind(sl<SourceRepository>(), kind),
        kind,
        sourceOrderPrefs.get(kind),
      ),
      excluded: sourceOrderPrefs.excluded(kind),
    );
  }

  sl.registerSingleton<SourceMatcher>(SourceMatcher(
    sources: sl<SourceRepository>(),
    store: matchStore,
    prefs: sourcePrefs,
    candidates: orderedCandidates,
  ));

  final providerPrefs = await MetadataProviderPrefs.open();
  sl.registerSingleton<MetadataProviderPrefs>(providerPrefs);

  sl.registerSingleton<MetadataRepository>(MetadataRepository(
    anilist: AniListCatalogue(AniListCatalogue.dioGql(sl<Dio>())),
    tmdb: TmdbCatalogue(TmdbCatalogue.dioGet(sl<Dio>())),
    mal: MalCatalogue(sl<Dio>()),
    simkl: SimklCatalogue(sl<Dio>()),
    providerPrefs: providerPrefs,
    // Say it out loud when the chosen provider was unreachable — silently
    // serving different data is how "why do my rows look wrong" starts.
    onProviderFallback: (name) {
      // A toast, not a SnackBar: the app uses toasts everywhere else, and a
      // SnackBar shoves the layout up and sits under the floating dock.
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) showAppToast(ctx, 'Showing results from $name');
    },
    sources: sl<SourceRepository>(),
    matcher: sl<SourceMatcher>(),
    matchStore: matchStore,
    sourcePrefs: sourcePrefs,
    health: sl<SourceHealthStore>(),
    candidates: orderedCandidates,
    browseKind: () => browseKindFor(
      sl<ContentModeCubit>().state,
      ZModePrefs.streamKind,
    ),
  ));

  sl.registerSingleton<CatalogueRepository>(CatalogueRouter(
    source: sl<SourceRepository>(),
    metadata: sl<MetadataRepository>(),
    enabled: () => ZModePrefs.enabled,
  ));

  // Expose PlaybackResolver directly so TvNativePlayer can invalidate the
  // winner cache when the native player reports a playback error.
  sl.registerSingleton<PlaybackResolver>(sl<MetadataRepository>().playbackResolver);
}

/// Which installed sources may play a title of [kind]. Prefix rules match
/// `ContentModeCubit._sourceInMode`: `mihon:` is manga, `lnr:` is novel,
/// everything else plays video.
List<({String id, String name})> candidatesForKind(
  SourceRepository repo,
  ZKind kind,
) {
  // pickableSources, not loadedSources: this is an explicit per-title choice,
  // so a source the language preference hides from browse must still be
  // offerable here. The two lists had already drifted — the home switcher
  // showed Aniyomi sources this picker did not.
  final all = repo.pickableSources;
  return switch (kind) {
    ZKind.manga => [for (final s in all) if (s.id.startsWith('mihon:')) s],
    ZKind.novel => [for (final s in all) if (s.id.startsWith('lnr:')) s],
    // Anime and movie/TV share one streaming pool. Which of the two a title
    // is has already been decided by the metadata catalogue; the source only
    // has to be able to play it, and plenty carry both. Kind affinity is NOT
    // applied here — this list also feeds the per-title picker, where the user
    // is choosing by hand. The sweep gets it in [sweepOrder].
    _ => [
      for (final s in all)
        if (!s.id.startsWith('mihon:') && !s.id.startsWith('lnr:')) s,
    ],
  };
}

/// The order a sweep actually walks: the user's saved priority, then kind
/// affinity applied WITHIN it.
///
/// The two used to run the other way round — affinity inside
/// [candidatesForKind], then [applySourceOrder] rebuilding the list from the
/// saved order — so the moment anyone set a priority the affinity pass was
/// thrown away wholesale, and an anime source ranked first was asked about
/// every live-action film before anything that could carry one.
///
/// Order within a group is still entirely the user's; only the two groups
/// swap. One saved list, read differently depending on what is being opened.
List<({String id, String name})> sweepOrder(
  List<({String id, String name})> pool,
  ZKind kind,
  List<String> savedOrder,
) => byKindAffinity(applySourceOrder(pool, savedOrder), kind);

/// The same pool, reordered so sources that DECLARE this kind are swept first.
///
/// A STABLE partition: `where` keeps the incoming order inside each half, so
/// running this over the user's saved priority list moves their movie sources
/// above their anime ones for a film without disturbing the order they chose
/// among either group.
///
/// Nothing is dropped — a source with both anime and films, or with no
/// declared type at all, has to stay reachable. But order matters a lot now
/// that playback sweeps: on a library of 174 sources an anime episode was
/// trying cs:Netflix, cs:Hotstar, cs:Pixar and PublicSportsIPTV — paying a
/// real search on each — before it reached an anime source.
///
/// Best-effort: [categorizedSources] reads several registries that early boot
/// and most tests do not have, so any failure just leaves the order untouched.
List<({String id, String name})> byKindAffinity(
  List<({String id, String name})> pool,
  ZKind kind,
) {
  final Set<String> declared;
  try {
    final b = categorizedSources();
    // A TV series belongs with movies, not anime. This asked "is it a movie?"
    // and sent everything else to the anime bucket — so opening a live-action
    // series put anime sources at the front of both sweeps and paid a real
    // search on each before reaching one that could have it. Everywhere else
    // in the app already pairs them (`_isTmdb`, the Movies & TV tab); this was
    // the one place that didn't.
    final wantsVideoPool = kind == ZKind.movie || kind == ZKind.tv;
    declared = {
      for (final r in wantsVideoPool ? b.movies : b.anime) r.id,
    };
  } catch (_) {
    return pool;
  }
  if (declared.isEmpty) return pool;
  return [
    ...pool.where((s) => declared.contains(s.id)),
    ...pool.where((s) => !declared.contains(s.id)),
  ];
}

/// The catalogue kind to browse: the content mode, with Movie/TV split out of
/// `anime` by the stream kind. Pure, so it is unit-testable.
ZKind browseKindFor(ContentMode mode, StreamKind stream) => switch (mode) {
  ContentMode.manga => ZKind.manga,
  ContentMode.novel => ZKind.novel,
  ContentMode.anime =>
    stream == StreamKind.movie ? ZKind.movie : ZKind.anime,
};
