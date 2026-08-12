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
/// Also stubs the two title-search shapes ([AniListApi.mediaBySearch] and
/// [AniListApi.searchMedia]) so a novel-scrobble test can tell them apart.
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
    } else if (query != null && query.contains('Page(perPage')) {
      // searchMedia — the format-aware search novel resolution uses. A
      // fixed id (4242) distinct from the plain-search id below, so a test
      // can tell which path actually ran.
      body = {
        'data': {
          'Page': {
            'media': [
              {
                'id': 4242,
                'idMal': null,
                'chapters': 47,
                'volumes': 8,
                'format': 'NOVEL',
                'seasonYear': 2014,
                'title': {'romaji': 'Mushoku Tensei', 'english': null},
                'coverImage': {'medium': null},
              },
            ],
          },
        },
      };
    } else if (query != null && query.contains('Media(search')) {
      // mediaBySearch — the plain, unfiltered title search (manga/anime).
      final field = query.contains('type:MANGA') ? 'chapters' : 'episodes';
      body = {
        'data': {
          'Media': {'id': 1234, field: 30},
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

  group('AniListService.scrobble — novel resolves via format:NOVEL search', () {
    late Directory dir;
    late _RecordingAdapter adapter;
    late AniListService service;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('anilist_novel_test');
      Hive.init(dir.path);
      await AniListStore.init();

      final store = AniListStore();
      await store.saveSession(token: 'tok', expiresAt: 0);
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

    test('novel:true with no malId hits the format_in:[NOVEL] search, not '
        'the plain title search', () async {
      await service.scrobble(
        title: 'Mushoku Tensei: Jobless Reincarnation',
        episode: 5,
        kind: MediaKind.manga,
        novel: true,
      );

      final novelSearch = adapter.queries.where(
        (q) => q.contains('Page(perPage'),
      );
      expect(novelSearch, isNotEmpty);
      expect(novelSearch.single, contains('format_in:[NOVEL]'));
      expect(adapter.queries.any((q) => q.contains('Media(search')), isFalse);

      // Progress landed on the id the format-aware search returned (4242),
      // not whatever a plain search would have picked.
      expect(AniListStore().scrobbledProgress(4242), 5);
    });

    test('novel:false (plain manga) with the same title stays on the '
        'unfiltered search — byte-identical to before this fix', () async {
      await service.scrobble(
        title: 'Mushoku Tensei: Jobless Reincarnation',
        episode: 5,
        kind: MediaKind.manga,
      );

      final plainSearch = adapter.queries.where(
        (q) => q.contains('Media(search'),
      );
      expect(plainSearch, isNotEmpty);
      expect(plainSearch.single, isNot(contains('format_in')));
      expect(adapter.queries.any((q) => q.contains('Page(perPage')), isFalse);
      expect(AniListStore().scrobbledProgress(1234), 5);
    });

    test('a novel and a same-titled manga resolve independently — the title '
        'cache does not collide between them', () async {
      await service.scrobble(
        title: 'Mushoku Tensei: Jobless Reincarnation',
        episode: 1,
        kind: MediaKind.manga,
        novel: true,
      );
      await service.scrobble(
        title: 'Mushoku Tensei: Jobless Reincarnation',
        episode: 1,
        kind: MediaKind.manga,
      );

      // Both resolved over the network, each to its own id — the second
      // call did not short-circuit off the first's cached title→id entry.
      expect(adapter.queries.where((q) => q.contains('Page(perPage')), isNotEmpty);
      expect(adapter.queries.where((q) => q.contains('Media(search')), isNotEmpty);
      expect(AniListStore().scrobbledProgress(4242), 1); // the novel
      expect(AniListStore().scrobbledProgress(1234), 1); // the manga
    });
  });
}
