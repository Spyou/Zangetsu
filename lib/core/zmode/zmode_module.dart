import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../repository/catalogue_repository.dart';
import '../repository/catalogue_router.dart';
import '../repository/source_repository.dart';
import 'anilist_catalogue.dart';
import 'mal_catalogue.dart';
import 'simkl_catalogue.dart';
import 'metadata_provider_prefs.dart';

import '../ui/app_toast.dart';
import '../ui/global_messenger.dart';
import 'match_store.dart';
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

  sl.registerSingleton<SourceMatcher>(
    SourceMatcher(
      sources: sl<SourceRepository>(),
      store: matchStore,
      prefs: sourcePrefs,
      candidates: (kind) => candidatesForKind(sl<SourceRepository>(), kind),
    ),
  );

  final providerPrefs = await MetadataProviderPrefs.open();
  sl.registerSingleton<MetadataProviderPrefs>(providerPrefs);

  sl.registerSingleton<MetadataRepository>(
    MetadataRepository(
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
      browseKind: () =>
          browseKindFor(sl<ContentModeCubit>().state, ZModePrefs.streamKind),
    ),
  );

  sl.registerSingleton<CatalogueRepository>(
    CatalogueRouter(
      source: sl<SourceRepository>(),
      metadata: sl<MetadataRepository>(),
      enabled: () => ZModePrefs.enabled,
    ),
  );
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
    ZKind.manga => [
      for (final s in all)
        if (s.id.startsWith('mihon:')) s,
    ],
    ZKind.novel => [
      for (final s in all)
        if (s.id.startsWith('lnr:')) s,
    ],
    // Anime and movie/TV share one streaming pool. Which of the two a title
    // is has already been decided by the metadata catalogue; the source only
    // has to be able to play it, and plenty carry both.
    _ => [
      for (final s in all)
        if (!s.id.startsWith('mihon:') && !s.id.startsWith('lnr:')) s,
    ],
  };
}

/// The catalogue kind to browse: the content mode, with Movie/TV split out of
/// `anime` by the stream kind. Pure, so it is unit-testable.
ZKind browseKindFor(ContentMode mode, StreamKind stream) => switch (mode) {
  ContentMode.manga => ZKind.manga,
  ContentMode.novel => ZKind.novel,
  ContentMode.anime => stream == StreamKind.movie ? ZKind.movie : ZKind.anime,
};
