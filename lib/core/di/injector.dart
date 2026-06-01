import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../playback/my_list.dart';
import '../playback/resume_store.dart';
import '../playback/watch_history.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/provider_settings_repository.dart';
import '../repository/source_repository.dart';
import '../state/active_source_cubit.dart';

final GetIt sl = GetIt.instance;

/// One-time app bootstrap: Hive boxes, Dio, the shared provider runtime,
/// the provider registry (built-in providers seeded from assets + any
/// repo-installed providers), and the bundled extractors.
Future<void> initDependencies() async {
  await Hive.initFlutter();
  await ProviderDownloader.init();
  await ResumeStore.init();
  sl.registerSingleton<ResumeStore>(ResumeStore());
  await WatchHistory.init();
  sl.registerSingleton<WatchHistory>(WatchHistory());
  await MyListStore.init();
  sl.registerSingleton<MyListStore>(MyListStore());

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

  // --- Seed built-in providers via the registry ---------------------
  // installFromBundled writes an enabled `bundled://` entry, caches the
  // JS for later reloads, and loads it into the runtime immediately.
  final allanimeJs = await rootBundle.loadString('providers/allanime.js');
  await registry.installFromBundled(
    name: 'allanime',
    jsSource: allanimeJs,
    displayName: 'AllAnime',
  );

  // NetMirror is ONE provider file backing FOUR OTT platform sourceIds;
  // each instance derives its ott / path prefix / poster CDN from its
  // sourceId (__SOURCE_ID). All four share the same in-memory JS source.
  final netmirrorJs = await rootBundle.loadString('providers/netmirror.js');
  const netmirrorPlatforms = {
    'netmirror_nf': 'Netflix',
    'netmirror_pv': 'Prime Video',
    'netmirror_hs': 'Hotstar',
    'netmirror_dp': 'Disney+',
  };
  for (final e in netmirrorPlatforms.entries) {
    await registry.installFromBundled(
      name: e.key,
      jsSource: netmirrorJs,
      displayName: e.value,
    );
  }

  // Load every enabled entry into the runtime. installFromBundled already
  // loaded the built-ins; loadAll re-loads any repo-installed providers
  // persisted from previous launches (and is a no-op for already-loaded
  // bundled ids).
  await registry.loadAll();

  // Push every saved per-provider settings row into the runtime so the
  // first provider call sees the user's choices. Strip the repoUrl prefix
  // off the composite key → sourceId.
  for (final entry in settings.getAll().entries) {
    final sourceId = ProviderRegistry.sourceIdOf(entry.key);
    manager.setSettings(sourceId, entry.value);
  }

  // Global cubit so any widget can read/write the active source id and
  // descendants can react via BlocBuilder/BlocListener.
  sl.registerSingleton<ActiveSourceCubit>(ActiveSourceCubit());

  sl.registerSingleton<SourceRepository>(
    SourceRepository(manager: manager, activeSource: sl<ActiveSourceCubit>()),
  );
}
