import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AniyomiSourceInfo _makeInfo({
  int id = 1,
  String name = 'TestSource',
  String lang = 'en',
  String pkg = 'com.test',
}) =>
    AniyomiSourceInfo(
      id: id,
      name: name,
      lang: lang,
      baseUrl: 'https://example.com',
      pkg: pkg,
      nsfw: false,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── AniyomiManager unit tests (no GetIt, no Hive) ─────────────────────────
  group('AniyomiManager', () {
    late AniyomiManager manager;

    setUp(() => manager = AniyomiManager());

    test('get() returns null when nothing is registered', () {
      expect(manager.get('ani:999'), isNull);
    });

    test('register() then get() returns the provider by sourceId', () {
      final provider = AniyomiProvider(info: _makeInfo(id: 1, name: 'HiAnime'));
      manager.register(provider);
      expect(manager.get('ani:1'), same(provider));
      expect(manager.get('ani:1')?.displayName, 'HiAnime');
    });

    test('_label equivalent: ani: id resolves to "Ani · <name>"', () {
      // The _label getter in SourceSwitcher performs exactly this lookup.
      manager.register(AniyomiProvider(info: _makeInfo(id: 8272, name: 'HiAnime')));
      final name = manager.get('ani:8272')?.displayName;
      expect(name, 'HiAnime');
      final label =
          (name != null && name.isNotEmpty) ? 'Ani · $name' : 'ani:8272';
      expect(label, 'Ani · HiAnime');
    });

    test('get() returns raw id fallback when source is not registered', () {
      const currentId = 'ani:8272';
      final name = manager.get(currentId)?.displayName;
      // When name is null, the getter falls back to the raw id.
      final label =
          (name != null && name.isNotEmpty) ? 'Ani · $name' : currentId;
      expect(label, 'ani:8272');
    });

    test('registerAll() registers every provider in the list', () {
      manager.registerAll([
        AniyomiProvider(info: _makeInfo(id: 1, name: 'A', pkg: 'com.a')),
        AniyomiProvider(info: _makeInfo(id: 2, name: 'B', pkg: 'com.b')),
      ]);
      expect(manager.all, hasLength(2));
    });

    test('removeWhere() removes matching provider by pkg', () {
      manager.registerAll([
        AniyomiProvider(info: _makeInfo(id: 1, pkg: 'com.s1')),
        AniyomiProvider(info: _makeInfo(id: 2, pkg: 'com.s2')),
      ]);
      manager.removeWhere(
        (p) => p is AniyomiProvider && p.info.pkg == 'com.s1',
      );
      expect(manager.get('ani:1'), isNull);
      expect(manager.get('ani:2'), isNotNull);
    });

    test('removeWhere() is a no-op when predicate matches nothing', () {
      manager.register(AniyomiProvider(info: _makeInfo(id: 1, pkg: 'com.keep')));
      manager.removeWhere((p) => p is AniyomiProvider && p.info.pkg == 'com.gone');
      expect(manager.all, hasLength(1));
    });
  });

  // ── categorizedSources includes Aniyomi (integration, uses GetIt + Hive) ──
  // Uses setUpAll/tearDownAll so Hive is initialised once for the group,
  // avoiding the "box already open" conflict caused by per-test reinit.
  group('categorizedSources', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('cat_src_ani_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(
          downloader: _FakeFetcher(),
          manager: _FakeManager(),
        ),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());

      final aniMgr = AniyomiManager();
      aniMgr.register(
        AniyomiProvider(
          info: _makeInfo(id: 42, name: 'HiAnime', pkg: 'eu.kanade.hianime'),
        ),
      );
      sl.registerSingleton<AniyomiManager>(aniMgr);
    });

    tearDownAll(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('Aniyomi source appears in anime bucket with correct id and label', () {
      final buckets = categorizedSources();
      final aniRow =
          buckets.anime.where((r) => r.id == 'ani:42').toList();
      expect(aniRow, hasLength(1));
      expect(aniRow.first.label, 'Ani · HiAnime');
      expect(aniRow.first.repo, 'Aniyomi');
    });

    test('Aniyomi source does NOT appear in movies or nsfw buckets', () {
      final buckets = categorizedSources();
      expect(buckets.movies.any((r) => r.id == 'ani:42'), isFalse);
      expect(buckets.nsfw.any((r) => r.id == 'ani:42'), isFalse);
    });
  });
}
