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
  bool nsfw = false,
}) =>
    AniyomiSourceInfo(
      id: id,
      name: name,
      lang: 'en',
      baseUrl: 'https://example.com',
      pkg: 'com.test.$id',
      nsfw: nsfw,
    );

AniyomiProvider _provider({int id = 1, String name = 'Src', bool nsfw = false}) =>
    AniyomiProvider(info: _makeInfo(id: id, name: name, nsfw: nsfw));

/// Simulates the loadedSources filter: runs [providers] through
/// [aniyomiNsfwVisible] with [showNsfwAniyomi] and returns the ids.
List<String> _filteredIds(
  List<AniyomiProvider> providers, {
  required bool showNsfwAniyomi,
}) =>
    providers
        .where((p) => aniyomiNsfwVisible(p, showNsfwAniyomi: showNsfwAniyomi))
        .map((p) => p.sourceId)
        .toList();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── aniyomiNsfwVisible unit tests (no Hive, no GetIt) ────────────────────

  group('aniyomiNsfwVisible', () {
    test('non-NSFW Aniyomi provider is visible regardless of pref', () {
      final p = _provider(id: 1, nsfw: false);
      expect(aniyomiNsfwVisible(p, showNsfwAniyomi: false), isTrue);
      expect(aniyomiNsfwVisible(p, showNsfwAniyomi: true), isTrue);
    });

    test('NSFW Aniyomi provider hidden when pref is false', () {
      final p = _provider(id: 2, nsfw: true);
      expect(aniyomiNsfwVisible(p, showNsfwAniyomi: false), isFalse);
    });

    test('NSFW Aniyomi provider visible when pref is true', () {
      final p = _provider(id: 3, nsfw: true);
      expect(aniyomiNsfwVisible(p, showNsfwAniyomi: true), isTrue);
    });
  });

  // ── loadedSources-style filter (no GetIt, no Hive) ───────────────────────

  group('filter logic (loadedSources equivalent)', () {
    test('excludes NSFW source when pref is off', () {
      final sources = [
        _provider(id: 10, nsfw: false, name: 'Safe'),
        _provider(id: 11, nsfw: true, name: 'Adult'),
      ];
      final ids = _filteredIds(sources, showNsfwAniyomi: false);
      expect(ids, contains('ani:10'));
      expect(ids, isNot(contains('ani:11')));
    });

    test('includes NSFW source when pref is true', () {
      final sources = [
        _provider(id: 20, nsfw: false, name: 'Safe'),
        _provider(id: 21, nsfw: true, name: 'Adult'),
      ];
      final ids = _filteredIds(sources, showNsfwAniyomi: true);
      expect(ids, contains('ani:20'));
      expect(ids, contains('ani:21'));
    });

    test('all non-NSFW sources always present', () {
      final sources = [
        _provider(id: 30, nsfw: false, name: 'A'),
        _provider(id: 31, nsfw: false, name: 'B'),
      ];
      final ids = _filteredIds(sources, showNsfwAniyomi: false);
      expect(ids, containsAll(['ani:30', 'ani:31']));
    });
  });

  // ── AniyomiManager + categorizedSources integration (uses GetIt + Hive) ──
  // Uses setUpAll/tearDownAll so Hive is initialised once for the group,
  // avoiding "box already open" conflicts caused by per-test re-init.
  group('AniyomiManager NSFW filtering via GetIt', () {
    late Directory tempDir;
    late AniyomiManager aniManager;
    late PlaybackPrefs prefs;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('nsfw_ani_getit_test');
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
      prefs = PlaybackPrefs();
      sl.registerSingleton<PlaybackPrefs>(prefs);
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());

      aniManager = AniyomiManager();
      sl.registerSingleton<AniyomiManager>(aniManager);
    });

    tearDownAll(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    setUp(() {
      aniManager.removeWhere((_) => true);
    });

    test('only non-NSFW providers visible when pref is off', () async {
      aniManager.registerAll([
        _provider(id: 40, nsfw: false, name: 'Safe'),
        _provider(id: 41, nsfw: true, name: 'Adult'),
      ]);
      await prefs.setShowNsfwAniyomi(false);

      final visible = aniManager.all
          .where((p) => aniyomiNsfwVisible(p, showNsfwAniyomi: prefs.showNsfwAniyomi))
          .map((p) => p.sourceId)
          .toList();

      expect(visible, contains('ani:40'));
      expect(visible, isNot(contains('ani:41')));
    });

    test('all providers visible when pref is true', () async {
      aniManager.registerAll([
        _provider(id: 50, nsfw: false, name: 'Safe'),
        _provider(id: 51, nsfw: true, name: 'Adult'),
      ]);
      await prefs.setShowNsfwAniyomi(true);

      final visible = aniManager.all
          .where((p) => aniyomiNsfwVisible(p, showNsfwAniyomi: prefs.showNsfwAniyomi))
          .map((p) => p.sourceId)
          .toList();

      expect(visible, containsAll(['ani:50', 'ani:51']));
    });

    test('pref persists after set', () async {
      await prefs.setShowNsfwAniyomi(true);
      expect(prefs.showNsfwAniyomi, isTrue);
      await prefs.setShowNsfwAniyomi(false);
      expect(prefs.showNsfwAniyomi, isFalse);
    });
  });
}
