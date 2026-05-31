import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../playback/resume_store.dart';
import '../playback/watch_history.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../repository/source_repository.dart';

final GetIt sl = GetIt.instance;

/// One-time app bootstrap: Hive boxes, Dio, the shared provider runtime, and
/// the bundled example provider + extractor loaded from assets.
Future<void> initDependencies() async {
  await Hive.initFlutter();
  await ProviderDownloader.init();
  await ResumeStore.init();
  sl.registerSingleton<ResumeStore>(ResumeStore());
  await WatchHistory.init();
  sl.registerSingleton<WatchHistory>(WatchHistory());

  final dio = Dio(BaseOptions(
    // 8s bounds every provider/extractor fetch (incl. embed hosts that hang,
    // e.g. streamlare's anti-bot endpoint) so source resolution can't stall ~20s.
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: {'User-Agent': 'Mozilla/5.0 (WATCH_APP) Chrome/120.0'},
  ));
  sl.registerSingleton<Dio>(dio);

  final manager = ProviderManager(dio: dio);
  sl.registerSingleton<ProviderManager>(manager);
  sl.registerSingleton<ProviderDownloader>(ProviderDownloader(dio: dio));

  // Load bundled extractor BEFORE the provider so getVideoSources can resolve.
  final extractorJs = await rootBundle.loadString('extractors/example_embed.js');
  manager.loadExtractor(extractorId: 'example_embed', jsSource: extractorJs);

  // Real embed-host extractors (P2). Order doesn't matter; each registers its
  // own hosts in __extractors and is reached via extractVideo().
  for (final ex in ['okru', 'mp4upload', 'streamlare', 'doodstream']) {
    final js = await rootBundle.loadString('extractors/$ex.js');
    manager.loadExtractor(extractorId: ex, jsSource: js);
  }

  final providerJs = await rootBundle.loadString('providers/example.js');
  manager.load(
    sourceId: 'example',
    jsSource: providerJs,
    originRepoUrl: 'bundled://',
    displayName: 'Bundled',
  );

  final allanimeJs = await rootBundle.loadString('providers/allanime.js');
  manager.load(
    sourceId: 'allanime',
    jsSource: allanimeJs,
    originRepoUrl: 'bundled://',
    displayName: 'Bundled',
  );

  sl.registerSingleton<SourceRepository>(SourceRepository(manager: manager));
}
