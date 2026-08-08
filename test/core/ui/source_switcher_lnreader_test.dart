import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

/// Task 6's fix: `categorizedSources()` enumerated ProviderRegistry,
/// CloudStreamManager, AniyomiManager, and MihonManager, but never
/// LnReaderManager — installed LNReader novel plugins never made it into the
/// novel bucket, so `hasReadingSourcesFor(ContentMode.novel)` stayed false
/// forever. Mirrors `source_switcher_mihon_test.dart`'s shape for the twin
/// LNReader case.

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

const _metaA = LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: 'https://cdn.test/a.png',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('categorizedSources + hasReadingSourcesFor with an LnReaderManager', () {
    late Directory tempDir;
    late LnReaderManager lnrManager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('src_switch_lnreader_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(AniyomiManager());

      final service = LnReaderExtensionService(
        httpGet: (url) async =>
            throw StateError('unexpected httpGet($url) — only stored meta should be read'),
      );
      lnrManager = LnReaderManager(
        service: service,
        fetch: (url, init) async =>
            throw StateError('fetch should not be called — categorizedSources never loads a plugin'),
      );
      await lnrManager.init(); // opens the box only, no runtime
      // Install without going through the network — writes meta straight to
      // the box the way service.install() would, minus the httpGet round trip.
      await Hive.box<Map>(LnReaderExtensionService.boxName)
          .put(_metaA.id, {..._metaA.toMap(), 'js': ''});
      sl.registerSingleton<LnReaderManager>(lnrManager);
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('an installed LNReader plugin lands in the novel bucket as lnr:<id>', () {
      final b = categorizedSources();
      final rows = b.novel.where((r) => r.id == 'lnr:plugin-a').toList();
      expect(rows, hasLength(1));
      expect(rows.single.label, 'LNReader · Plugin A');
      expect(rows.single.repo, 'LNReader');
    });

    test('the LNReader row appears in NO anime/movies/nsfw/manga bucket', () {
      final b = categorizedSources();
      expect(b.anime.any((r) => r.id == 'lnr:plugin-a'), isFalse);
      expect(b.movies.any((r) => r.id == 'lnr:plugin-a'), isFalse);
      expect(b.nsfw.any((r) => r.id == 'lnr:plugin-a'), isFalse);
      expect(b.manga.any((r) => r.id == 'lnr:plugin-a'), isFalse);
    });

    test('hasReadingSourcesFor(novel) is true once an LNReader source exists', () {
      expect(hasReadingSourcesFor(ContentMode.novel), isTrue);
      expect(hasReadingSourcesFor(ContentMode.manga), isFalse);
      expect(hasReadingSourcesFor(ContentMode.anime), isFalse);
    });

    test('reading the novel bucket never builds the LNReader QuickJS runtime', () {
      categorizedSources();
      hasReadingSourcesFor(ContentMode.novel);
      expect(lnrManager.runtimeBuilt, isFalse);
    });
  });

  // A GetIt with no LnReaderManager at all is the state every pre-Task-6 test
  // runs in — categorizedSources must not crash there.
  group('categorizedSources without a registered LnReaderManager', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('src_switch_nolnreader');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();
      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(AniyomiManager());
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('does not throw, and novel bucket is simply empty', () {
      expect(sl.isRegistered<LnReaderManager>(), isFalse);
      final b = categorizedSources();
      expect(b.novel, isEmpty);
      expect(hasReadingSourcesFor(ContentMode.novel), isFalse);
    });
  });
}
