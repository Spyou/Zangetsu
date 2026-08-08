import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/anilist/anilist_store.dart';
import 'package:watch_app/core/tracker/tracker.dart';

/// Fake Dio adapter that inspects the GraphQL query text it was asked to
/// send and returns a matching canned response — no real network. Lets the
/// [AniListService.flushPending] test prove which `type:` (ANIME/MANGA) a
/// replayed queued scrobble actually hit, which is the whole point of D1.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> queries = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    final query = (data is Map) ? data['query'] as String? : null;
    if (query != null) queries.add(query);

    Map<String, dynamic> body;
    if (query != null && query.contains('Media(idMal')) {
      // mediaByMalId resolution — id 999, total keyed by whichever count
      // field the manga/anime query actually asked for.
      final field = query.contains('type:MANGA') ? 'chapters' : 'episodes';
      body = {
        'data': {
          'Media': {'id': 999, field: 50},
        },
      };
    } else if (query != null && query.contains('SaveMediaListEntry')) {
      body = {
        'data': {
          'SaveMediaListEntry': {'id': 1},
        },
      };
    } else {
      body = {'data': {}};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AniListStore — D2: MAL id cache namespaced by MediaKind', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('anilist_store_test');
      Hive.init(dir.path);
      await AniListStore.init();
    });

    tearDown(() async {
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('the same malId cached for anime and manga resolves to two DIFFERENT '
        'AniList ids — no cross-kind hit', () async {
      final store = AniListStore();
      await store.cacheMediaId(
        21,
        555,
        MediaKind.anime,
      ); // e.g. One Piece anime
      await store.cacheMediaId(
        21,
        777,
        MediaKind.manga,
      ); // unrelated manga, same malId

      expect(store.cachedMediaId(21, MediaKind.anime), 555);
      expect(store.cachedMediaId(21, MediaKind.manga), 777);
    });

    test(
      'cachedMediaId defaults to the anime map, unchanged from before',
      () async {
        final store = AniListStore();
        await store.cacheMediaId(100, 200); // no kind passed — anime default
        expect(store.cachedMediaId(100), 200); // read back with no kind, too
        expect(store.cachedMediaId(100, MediaKind.anime), 200);
        expect(store.cachedMediaId(100, MediaKind.manga), isNull);
      },
    );

    test(
      'title cache and episode/chapter-total cache are namespaced too',
      () async {
        final store = AniListStore();
        await store.cacheMediaIdByTitle('naruto', 1, MediaKind.anime);
        await store.cacheMediaIdByTitle('naruto', 2, MediaKind.manga);
        expect(store.cachedMediaIdByTitle('naruto', MediaKind.anime), 1);
        expect(store.cachedMediaIdByTitle('naruto', MediaKind.manga), 2);

        await store.cacheEpisodes(1, 220, MediaKind.anime);
        await store.cacheEpisodes(1, 700, MediaKind.manga);
        expect(store.cachedEpisodes(1, MediaKind.anime), 220);
        expect(store.cachedEpisodes(1, MediaKind.manga), 700);
      },
    );
  });

  group('AniListStore — D1: offline scrobble queue persists kind', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('anilist_store_test');
      Hive.init(dir.path);
      await AniListStore.init();
    });

    tearDown(() async {
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('queueScrobble(kind: manga) persists it on the row', () async {
      final store = AniListStore();
      await store.queueScrobble(malId: 5, episode: 3, kind: MediaKind.manga);
      final rows = store.pendingScrobbles;
      expect(rows.single['kind'], 'manga');
    });

    test(
      'a row queued before kind existed (no "kind" key) reads as anime',
      () async {
        // Simulate an old queued row, written before this field existed.
        await Hive.box('anilist').put('pending', [
          {'malId': 5, 'title': null, 'episode': 3},
        ]);
        final store = AniListStore();
        final rows = store.pendingScrobbles;
        expect(
          mediaKindFromName(rows.single['kind'] as String?),
          MediaKind.anime,
        );
      },
    );

    test('queuing the same malId for anime AND manga keeps both rows — no '
        'cross-kind dedup collision', () async {
      final store = AniListStore();
      await store.queueScrobble(malId: 21, episode: 5, kind: MediaKind.anime);
      await store.queueScrobble(malId: 21, episode: 8, kind: MediaKind.manga);
      expect(store.pendingScrobbles, hasLength(2));
    });
  });

  group('AniListService.flushPending — D1: replay preserves kind', () {
    late Directory dir;
    late _RecordingAdapter adapter;
    late AniListService service;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('anilist_service_test');
      Hive.init(dir.path);
      await AniListStore.init();

      // Seed a connected session directly via the store (bypassing OAuth).
      final store = AniListStore();
      await store.saveSession(token: 'tok', expiresAt: 0); // 0 = never expires
      await store.saveViewer(id: 1, name: 'me');

      adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      service = AniListService(dio);
    });

    tearDown(() async {
      service.dispose();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a queued MANGA scrobble replays against a type:MANGA query, not '
        'type:ANIME', () async {
      await AniListStore().queueScrobble(
        malId: 42,
        episode: 7,
        kind: MediaKind.manga,
      );

      await service.flushPending();

      final resolveQueries = adapter.queries
          .where((q) => q.contains('Media(idMal'))
          .toList();
      expect(resolveQueries, isNotEmpty);
      expect(resolveQueries.single, contains('type:MANGA'));
      expect(resolveQueries.single, isNot(contains('type:ANIME')));

      // And it actually cleared from the queue (synced), proving the whole
      // replay path — resolve, save, dequeue — ran under MediaKind.manga.
      expect(AniListStore().pendingScrobbles, isEmpty);
    });

    test(
      'a queued ANIME scrobble still replays against type:ANIME (unchanged)',
      () async {
        await AniListStore().queueScrobble(
          malId: 43,
          episode: 4,
          kind: MediaKind.anime,
        );

        await service.flushPending();

        final resolveQueries = adapter.queries
            .where((q) => q.contains('Media(idMal'))
            .toList();
        expect(resolveQueries.single, contains('type:ANIME'));
      },
    );
  });
}
