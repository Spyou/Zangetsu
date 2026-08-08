import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

// ---------------------------------------------------------------------------
// Regression test for the source-switching lag bug: filterBucketsForMode (and
// categorizedSources) used to resolve each row's ProviderType via
// sourceTypeOf -> ProviderRegistry.typeOf -> ProviderReposRegistry.getAll(),
// which fully re-deserializes every cached repo manifest from Hive on EVERY
// call. That meant one getAll() per row instead of one per picker-open. This
// file proves the fixed cost, so the per-row shape can't quietly come back.
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

/// Counts calls to [getAll] — the expensive full-manifest deserialize + sort
/// — so a test can assert it's invoked a fixed number of times per picker
/// operation, not once per row.
class _CountingReposRegistry extends ProviderReposRegistry {
  _CountingReposRegistry(Dio dio) : super(dio: dio);
  int getAllCalls = 0;

  @override
  List<ProviderRepo> getAll() {
    getAllCalls++;
    return super.getAll();
  }
}

/// Same seeding shape as reading_source_buckets_test.dart / source_picker_test.dart.
Future<void> _seedJsSource({
  required String id,
  required String type,
  String repoUrl = 'https://example.com/repo/index.json',
}) async {
  final reposBox = Hive.box<Map>(ProviderReposRegistry.boxName);
  final existingRaw = reposBox.get(repoUrl);
  final existingSources = existingRaw == null
      ? const <RepoSource>[]
      : ProviderRepo.fromJson(Map<String, dynamic>.from(existingRaw)).sources;
  final repo = ProviderRepo(
    url: repoUrl,
    name: 'Test Repo',
    description: '',
    lastSyncedAt: DateTime.now(),
    sources: [
      ...existingSources,
      RepoSource(id: id, name: id, version: '1.0.0', type: type, lang: 'en', file: '$id.js'),
    ],
  );
  await reposBox.put(repoUrl, repo.toJson());

  final regBox = Hive.box<Map>(ProviderRegistry.boxName);
  final entry = ProviderRegistryEntry(
    name: id,
    url: '$repoUrl/$id.js',
    originRepoUrl: repoUrl,
    displayName: id,
  );
  await regBox.put(ProviderRegistry.providerKey(repoUrl, id), entry.toJson());
}

void main() {
  late Directory tempDir;
  late _CountingReposRegistry repos;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('source_switcher_perf_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();
    await PlaybackPrefs.init();
    await CloudStreamManager.init();

    repos = _CountingReposRegistry(Dio());
    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager(), repos: repos),
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

  test(
    'filterBucketsForMode resolves the repo-manifest map once per call, '
    'not once per row',
    () async {
      // Spread rows across two repos so getAll() has real deserialize work
      // to do on every call, matching the reported shape (N rows x R repos).
      for (var i = 0; i < 8; i++) {
        await _seedJsSource(
          id: 'js:a$i',
          type: 'anime',
          repoUrl: 'https://example.com/repoA/index.json',
        );
      }
      for (var i = 0; i < 8; i++) {
        await _seedJsSource(
          id: 'js:b$i',
          type: 'movie',
          repoUrl: 'https://example.com/repoB/index.json',
        );
      }

      final raw = categorizedSources();
      expect(raw.anime.length + raw.movies.length, 16); // sanity: rows landed

      repos.getAllCalls = 0; // isolate the call under test

      final filtered = filterBucketsForMode(raw, ContentMode.anime);

      // Before the fix this was 16 (one getAll() per row across every
      // bucket). The fix hoists the id->type resolution to one map built
      // once per filterBucketsForMode call.
      expect(repos.getAllCalls, 1);
      expect(filtered.anime.length + filtered.movies.length, 16);
    },
  );

  test(
    'categorizedSources resolves the repo-manifest map once per call, not '
    'twice per row',
    () async {
      for (var i = 0; i < 5; i++) {
        await _seedJsSource(id: 'js:x$i', type: 'anime');
      }

      repos.getAllCalls = 0;
      categorizedSources();

      // Before the fix this was 11 (1 for nsfwSourceIds() + 2 per row: one
      // via reg.typeOf(), one via sourceTypeOf()). nsfwSourceIds() is its
      // own single upfront getAll() call and is untouched by this fix, so
      // the fixed cost here is 1 (nsfw) + 1 (the hoisted type map) = 2,
      // regardless of row count.
      expect(repos.getAllCalls, 2);
    },
  );
}
