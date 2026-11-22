import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mangayomi/mangayomi_manager.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/prefs/source_lang_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

// ---------------------------------------------------------------------------
// Stubs (same shape as test/features/sources/mode_filtered_sources_test.dart)
// ---------------------------------------------------------------------------

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {}
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

/// Writes a repo manifest entry + an enabled registry entry directly into
/// the Hive boxes ProviderRegistry/ProviderReposRegistry read from — the
/// same end state a real install would leave, without any network I/O.
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
  MangayomiManager? mangayomi;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reading_buckets_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();
    await PlaybackPrefs.init();
    await CloudStreamManager.init();

    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(
        downloader: _FakeFetcher(),
        manager: _FakeManager(),
        repos: ProviderReposRegistry(dio: Dio()),
      ),
    );
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
  });

  tearDown(() async {
    mangayomi?.dispose();
    mangayomi = null;
    await sl.reset();
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'Mangayomi sources appear only in their declared picker bucket',
    () async {
      final directory = Directory('${tempDir.path}/mangayomi');
      await directory.create(recursive: true);
      final codeFileName = '${List.filled(64, '0').join()}.source';
      await File(
        '${directory.path}/$codeFileName',
      ).writeAsString('source code');
      final repository = Uri.parse('https://repo.example.com/index.json');
      final manifests = [
        for (final (id, type, name) in [
          (1, 0, 'MG Manga'),
          (2, 1, 'MG Video'),
          (3, 2, 'MG Novel'),
        ])
          {
            'id': id,
            'name': name,
            'baseUrl': 'https://source$id.example.com',
            'sourceCodeUrl': 'https://cdn.example.com/$id.dart',
            'version': '1.0.0',
            'itemType': type,
            'sourceCodeLanguage': 0,
            'lang': 'en',
          },
      ];
      await File('${directory.path}/installed.json').writeAsString(
        jsonEncode([
          for (final manifest in manifests)
            {
              'repository': repository.toString(),
              'source': manifest,
              'codeFile': codeFileName,
            },
        ]),
      );
      mangayomi = MangayomiManager(MangayomiExtensionService(directory));
      await mangayomi!.init();
      sl.registerSingleton<MangayomiManager>(mangayomi!);

      final ids = {
        for (final item in mangayomi!.installed)
          item.source.contentType: item.source.key,
      };
      final buckets = categorizedSources();
      expect(
        buckets.manga.map((row) => row.id),
        contains(ids[MangayomiContentType.manga]),
      );
      expect(
        buckets.anime.map((row) => row.id),
        contains(ids[MangayomiContentType.video]),
      );
      expect(
        buckets.novel.map((row) => row.id),
        contains(ids[MangayomiContentType.novel]),
      );
      expect(
        buckets.movies.map((row) => row.id),
        isNot(contains(ids[MangayomiContentType.manga])),
      );
      expect(
        buckets.movies.map((row) => row.id),
        isNot(contains(ids[MangayomiContentType.novel])),
      );
    },
  );

  test('a manga-typed JS source lands in categorizedSources().manga', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    final buckets = categorizedSources();
    expect(buckets.manga.map((r) => r.id), contains('js:m'));
  });

  test('a novel-typed JS source lands in categorizedSources().novel', () async {
    await _seedJsSource(id: 'js:n', type: 'novel');
    final buckets = categorizedSources();
    expect(buckets.novel.map((r) => r.id), contains('js:n'));
  });

  test(
    'a manga/novel source ALSO still lands in categorizedSources().movies — '
    'unchanged from before this task, so TvSourcePicker (which reads only '
    '.anime/.movies/.nsfw and has no mode filter) renders exactly as it did',
    () async {
      await _seedJsSource(id: 'js:m', type: 'manga');
      await _seedJsSource(id: 'js:n', type: 'novel');
      final buckets = categorizedSources();
      expect(buckets.movies.map((r) => r.id), containsAll(['js:m', 'js:n']));
      expect(buckets.anime.map((r) => r.id), isNot(contains('js:m')));
      expect(buckets.anime.map((r) => r.id), isNot(contains('js:n')));
    },
  );

  test('an anime-typed source is unaffected — lands only in .anime, never in .manga/.novel', () async {
    await _seedJsSource(id: 'js:a', type: 'anime');
    final buckets = categorizedSources();
    expect(buckets.anime.map((r) => r.id), contains('js:a'));
    expect(buckets.manga.map((r) => r.id), isNot(contains('js:a')));
    expect(buckets.novel.map((r) => r.id), isNot(contains('js:a')));
  });

  test('manga mode: filterBucketsForMode keeps only the manga row in .manga', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    await _seedJsSource(id: 'js:n', type: 'novel');
    await _seedJsSource(id: 'js:a', type: 'anime');
    final raw = categorizedSources();
    final filtered = filterBucketsForMode(raw, ContentMode.manga);
    expect(filtered.manga.map((r) => r.id).toList(), ['js:m']);
    expect(filtered.novel, isEmpty);
  });

  test('novel mode: filterBucketsForMode keeps only the novel row in .novel', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    await _seedJsSource(id: 'js:n', type: 'novel');
    final raw = categorizedSources();
    final filtered = filterBucketsForMode(raw, ContentMode.novel);
    expect(filtered.novel.map((r) => r.id).toList(), ['js:n']);
    expect(filtered.manga, isEmpty);
  });

  test('anime mode: reading buckets are always empty, regardless of what is installed', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    await _seedJsSource(id: 'js:n', type: 'novel');
    await _seedJsSource(id: 'js:a', type: 'anime');
    final raw = categorizedSources();
    final filtered = filterBucketsForMode(raw, ContentMode.anime);
    expect(filtered.manga, isEmpty);
    expect(filtered.novel, isEmpty);
  });

  test('Mangayomi sources respect the language filter in the picker', () async {
    final directory = Directory('${tempDir.path}/mangayomi');
    await directory.create(recursive: true);
    final codeFileName = '${List.filled(64, '0').join()}.source';
    await File('${directory.path}/$codeFileName').writeAsString('source code');
    final repository = Uri.parse('https://repo.example.com/index.json');
    await File('${directory.path}/installed.json').writeAsString(
      jsonEncode([
        for (final (id, name, lang) in [
          (1, 'MG Multi', 'en'),
          (2, 'MG Multi', 'pt-BR'),
        ])
          {
            'repository': repository.toString(),
            'source': {
              'id': id,
              'name': name,
              'baseUrl': 'https://source$id.example.com',
              'sourceCodeUrl': 'https://cdn.example.com/$id.dart',
              'version': '1.0.0',
              'itemType': 0,
              'sourceCodeLanguage': 0,
              'lang': lang,
            },
            'codeFile': codeFileName,
          },
      ]),
    );
    mangayomi = MangayomiManager(MangayomiExtensionService(directory));
    await mangayomi!.init();
    sl.registerSingleton<MangayomiManager>(mangayomi!);

    final prefs = MangayomiLangPrefs();
    await prefs.init();
    await prefs.setEnabled({'en'});
    sl.registerSingleton<MangayomiLangPrefs>(prefs);

    expect(prefs.enabled, {'en'});
    expect(
      mangayomi!.installed.map((item) => item.source.language),
      containsAll(['en', 'pt-BR']),
    );
    final ids = {
      for (final item in mangayomi!.installed)
        item.source.language: item.source.key,
    };
    final manga = categorizedSources().manga;
    expect(manga.map((row) => row.id), contains(ids['en']));
    expect(manga.map((row) => row.id), isNot(contains(ids['pt-BR'])));
  });

  // ── hasReadingSourcesFor (Task E2 — Home/Search/My List "no sources" gate) ─
  // The same "is there anything installed for this reading mode" check E1's
  // picker already needed (_SourcePickerSheetState._hasAnySources), pulled
  // out as a top-level function so Home/Search/My List's empty states can
  // reuse it instead of re-deriving it a third/fourth/fifth time.

  test('hasReadingSourcesFor: anime mode is always false, even with reading '
      'sources installed — anime has no reading bucket of its own', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    await _seedJsSource(id: 'js:n', type: 'novel');
    expect(hasReadingSourcesFor(ContentMode.anime), isFalse);
  });

  test('hasReadingSourcesFor: manga mode with nothing installed is false',
      () async {
    expect(hasReadingSourcesFor(ContentMode.manga), isFalse);
  });

  test('hasReadingSourcesFor: manga mode with a manga source installed is '
      'true', () async {
    await _seedJsSource(id: 'js:m', type: 'manga');
    expect(hasReadingSourcesFor(ContentMode.manga), isTrue);
  });

  test('hasReadingSourcesFor: manga mode is unmoved by a novel-only install',
      () async {
    await _seedJsSource(id: 'js:n', type: 'novel');
    expect(hasReadingSourcesFor(ContentMode.manga), isFalse);
  });

  test('hasReadingSourcesFor: novel mode with a novel source installed is '
      'true', () async {
    await _seedJsSource(id: 'js:n', type: 'novel');
    expect(hasReadingSourcesFor(ContentMode.novel), isTrue);
  });
}
