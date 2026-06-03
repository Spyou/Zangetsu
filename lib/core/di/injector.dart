import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../playback/my_list.dart';
import '../playback/playback_prefs.dart';
import '../playback/resume_store.dart';
import '../playback/title_prefs.dart';
import '../playback/watch_history.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/provider_settings_repository.dart';
import '../repository/source_repository.dart';
import '../state/active_source_cubit.dart';
import '../trailer/trailer_service.dart';
import '../appwrite/appwrite_service.dart';
import '../download/download_manager.dart';
import '../../features/auth/auth_cubit.dart';
import '../../features/home/cubit/home_cubit.dart';

final GetIt sl = GetIt.instance;

/// One-time app bootstrap: Hive boxes, Dio, the shared provider runtime,
/// the provider registry (built-in providers seeded from assets + any
/// repo-installed providers), and the bundled extractors.
Future<void> initDependencies() async {
  await Hive.initFlutter();
  await ProviderDownloader.init();

  // Appwrite first (no network on construct) so the library stores can use it
  // for cloud sync. Public project id/endpoint only — no server key.
  sl.registerSingleton<AppwriteService>(AppwriteService());
  // Resolved lazily at call time (AuthCubit registers further down); null when
  // signed out so the stores stay local-only.
  String? currentUserId() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.user?.$id : null;

  await ResumeStore.init();
  sl.registerSingleton<ResumeStore>(ResumeStore());
  await WatchHistory.init();
  sl.registerSingleton<WatchHistory>(
    WatchHistory(sl<AppwriteService>(), currentUserId),
  );
  await MyListStore.init();
  sl.registerSingleton<MyListStore>(
    MyListStore(sl<AppwriteService>(), currentUserId),
  );
  await TitlePrefsStore.init();
  sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
  await PlaybackPrefs.init();
  sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());

  final dio = Dio(
    BaseOptions(
      // 8s bounds every provider/extractor fetch (incl. embed hosts that hang,
      // e.g. streamlare's anti-bot endpoint) so source resolution can't stall ~20s.
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': 'Mozilla/5.0 (WATCH_APP) Chrome/120.0'},
    ),
  );
  sl.registerSingleton<Dio>(dio);

  // Metadata-API trailer lookups (AniList for anime, TMDB for movie/TV).
  sl.registerSingleton<TrailerService>(TrailerService(dio));

  // AuthCubit is global so any widget can gate on login. AppwriteService is
  // already registered above (the library stores depend on it).
  sl.registerSingleton<AuthCubit>(AuthCubit(sl<AppwriteService>()));

  final manager = ProviderManager(dio: dio);
  sl.registerSingleton<ProviderManager>(manager);
  final downloader = ProviderDownloader(dio: dio);
  sl.registerSingleton<ProviderDownloader>(downloader);

  // --- Provider registry data layer ---------------------------------
  await ProviderReposRegistry.init();
  await ProviderRegistry.init();
  await ProviderSettingsRepository.init();

  final repos = ProviderReposRegistry(dio: dio);
  final settings = ProviderSettingsRepository();
  final registry = ProviderRegistry(
    downloader: downloader,
    manager: manager,
    repos: repos,
  );
  sl.registerSingleton<ProviderReposRegistry>(repos);
  sl.registerSingleton<ProviderSettingsRepository>(settings);
  sl.registerSingleton<ProviderRegistry>(registry);

  // Load bundled extractor BEFORE the providers so getVideoSources can resolve.
  // Extractors are NOT providers — they stay loaded directly on the manager.
  final extractorJs = await rootBundle.loadString(
    'extractors/example_embed.js',
  );
  manager.loadExtractor(extractorId: 'example_embed', jsSource: extractorJs);

  // Real embed-host extractors. Order doesn't matter; each registers its
  // own hosts in __extractors and is reached via extractVideo().
  for (final ex in ['okru', 'mp4upload', 'streamlare', 'doodstream']) {
    final js = await rootBundle.loadString('extractors/$ex.js');
    manager.loadExtractor(extractorId: ex, jsSource: js);
  }

  // The app ships with NO built-in providers — every source comes from a repo
  // (the Zangetsu repo is installed on first launch via onboarding). Drop any
  // legacy `bundled://` entries left by older installs, then load the
  // repo-installed providers persisted from previous launches.
  await registry.purgeBundled();
  await registry.loadAll();

  // Push every saved per-provider settings row into the runtime so the
  // first provider call sees the user's choices. Strip the repoUrl prefix
  // off the composite key → sourceId.
  for (final entry in settings.getAll().entries) {
    final sourceId = ProviderRegistry.sourceIdOf(entry.key);
    manager.setSettings(sourceId, entry.value);
  }

  // Global cubit so any widget can read/write the active source id and
  // descendants can react via BlocBuilder/BlocListener. Persists the pick to a
  // Hive box and restores it on launch, validated against the providers that
  // actually loaded (so a removed/disabled source falls back to allanime).
  await ActiveSourceCubit.init();
  sl.registerSingleton<ActiveSourceCubit>(
    ActiveSourceCubit(
      box: Hive.box(ActiveSourceCubit.boxName),
      valid: manager.installedIds.toSet(),
    ),
  );

  sl.registerSingleton<SourceRepository>(
    SourceRepository(manager: manager, activeSource: sl<ActiveSourceCubit>()),
  );

  // Offline downloads (background_downloader). setup() restores persisted
  // records and starts listening for task progress/status updates.
  await DownloadManager.init();
  sl.registerSingleton<DownloadManager>(
    DownloadManager(sl<SourceRepository>(), sl<Dio>())..setup(),
  );

  // Home data cubit as a singleton so the splash can warm it (preload the
  // rows for the active source) while the intro animation plays — Home then
  // appears already populated instead of flashing skeletons.
  sl.registerLazySingleton<HomeCubit>(() => HomeCubit(sl<SourceRepository>()));
}
