import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

// ---------------------------------------------------------------------------
// Stubs (same shape as test/aniyomi/source_switcher_aniyomi_test.dart)
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

void main() {
  // ── Pure filter function — no DI, no Hive ─────────────────────────────────
  group('filterSourcesForMode', () {
    final srcs = {
      'js:a': ProviderType.anime,
      'js:mv': ProviderType.movie,
      'js:m': ProviderType.manga,
      'js:n': ProviderType.novel,
    };
    Map<String, ProviderType> f(ContentMode m) =>
        filterSourcesForMode(srcs, m, (t) => t);

    test('anime mode sees anime+movie sources, reading modes see only their own', () {
      expect(f(ContentMode.anime).keys, ['js:a', 'js:mv']); // unchanged today
      expect(f(ContentMode.manga).keys, ['js:m']);
      expect(f(ContentMode.novel).keys, ['js:n']);
    });

    test('anime mode is byte-identical to the unfiltered map for an anime/movie-only set', () {
      // This is the hard constraint ("don't touch anime mode") expressed as a
      // test: filtering must drop and reorder NOTHING when every source is
      // already anime or movie typed.
      final animeMovieOnly = {
        'js:a': ProviderType.anime,
        'cs:x': ProviderType.movie,
        'ani:1': ProviderType.anime,
      };
      final filtered =
          filterSourcesForMode(animeMovieOnly, ContentMode.anime, (t) => t);
      expect(filtered, animeMovieOnly);
      expect(filtered.keys.toList(), animeMovieOnly.keys.toList());
    });
  });

  // ── Wiring: sourceTypeOf + filterBucketsForMode (uses GetIt + Hive) ───────
  group('filterBucketsForMode', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('mode_filtered_src_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
      );
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());

      final aniMgr = AniyomiManager();
      aniMgr.register(
        AniyomiProvider(
          info: AniyomiSourceInfo(
            id: 42,
            name: 'HiAnime',
            lang: 'en',
            baseUrl: 'https://example.com',
            pkg: 'eu.kanade.hianime',
            nsfw: false,
          ),
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

    test('Aniyomi sources are always ProviderType.anime', () {
      expect(sourceTypeOf('ani:42'), ProviderType.anime);
    });

    test('an id with no cached manifest defaults to anime (matches categorizedSources)', () {
      expect(sourceTypeOf('js:nowhere'), ProviderType.anime);
    });

    test('anime mode: filtered buckets are byte-identical to categorizedSources()', () {
      final raw = categorizedSources();
      final filtered = filterBucketsForMode(raw, ContentMode.anime);
      expect(filtered.anime, raw.anime);
      expect(filtered.movies, raw.movies);
      expect(filtered.nsfw, raw.nsfw);
    });

    test('manga mode: an anime-only source set filters down to nothing', () {
      final raw = categorizedSources();
      expect(raw.anime.any((r) => r.id == 'ani:42'), isTrue); // sanity
      final filtered = filterBucketsForMode(raw, ContentMode.manga);
      expect(filtered.anime.any((r) => r.id == 'ani:42'), isFalse);
    });

    test(
      'anime mode never drops or reorders rows that share a sourceId '
      '(the same source installed from two different repos)',
      () {
        // A map-by-id round trip would collapse these into one row — a real
        // regression, since ProviderRegistry keys entries by repoUrl+sourceId
        // and explicitly supports the same sourceId installed twice.
        final buckets = (
          anime: <({String id, String label, String? repo})>[
            (id: 'js:dup', label: 'Dup', repo: 'repoA'),
            (id: 'js:dup', label: 'Dup', repo: 'repoB'),
            (id: 'js:solo', label: 'Solo', repo: null),
          ],
          movies: const <({String id, String label, String? repo})>[],
          nsfw: const <({String id, String label, String? repo})>[],
          manga: const <({String id, String label, String? repo})>[],
          novel: const <({String id, String label, String? repo})>[],
        );
        final filtered = filterBucketsForMode(buckets, ContentMode.anime);
        expect(filtered.anime, buckets.anime); // byte-identical: all 3 survive, in order
        expect(
          filtered.anime.map((r) => r.repo).toList(),
          ['repoA', 'repoB', null], // each duplicate keeps its own repo tag
        );
      },
    );
  });
}
