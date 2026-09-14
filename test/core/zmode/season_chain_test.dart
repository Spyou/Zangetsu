import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_api.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/zmode/season_chain.dart';

/// Answers AniList's relations query from a table of id → neighbours, and
/// counts requests so a test can prove the walk is bounded and cached rather
/// than infer it.
class _FakeAniList implements HttpClientAdapter {
  _FakeAniList(this.graph, {this.seasonOf = const {}});

  /// id → list of (relationType, id, format)
  final Map<int, List<({String rel, int id, String format})>> graph;

  /// MAL id → the real season AniZip reports. Absent means unmapped, which is
  /// what makes the chain fall back to position numbering.
  final Map<int, int> seasonOf;
  final asked = <int>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, _) async {
    // AniZip: the fake mints MAL ids as anilistId + 1000 (see below).
    if (o.uri.host == 'api.ani.zip') {
      final mal = int.parse(o.uri.queryParameters['mal_id']!);
      final season = seasonOf[mal];
      return ResponseBody.fromString(
        jsonEncode({
          'episodes': season == null
              ? <String, dynamic>{}
              : {'1': {'seasonNumber': season, 'title': {'en': 'x'}}},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    // Dio keeps RequestOptions.data as the ORIGINAL object; only the wire
    // form is a string. Casting to String here threw, _gql swallowed it, and
    // every walk came back empty.
    final raw = o.data;
    final body = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : Map<String, dynamic>.from(raw as Map);
    final id = (body['variables'] as Map)['id'] as int;
    asked.add(id);
    final edges = [
      for (final n in graph[id] ?? const <({String rel, int id, String format})>[])
        {
          'relationType': n.rel,
          'node': {
            'id': n.id,
            'idMal': n.id + 1000,
            'format': n.format,
            'episodes': 12,
            'title': {'romaji': 'Season ${n.id}', 'english': null, 'native': null},
            'coverImage': {'medium': 'https://img/${n.id}.jpg'},
          },
        },
    ];
    return ResponseBody.fromString(
      jsonEncode({
        'data': {
          'Media': {
            'relations': {'edges': edges},
          },
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SeasonChain _chain(_FakeAniList fake) {
  final dio = Dio()..httpClientAdapter = fake;
  return SeasonChain(AniListApi(dio, () => null), EpisodeMetadataService(dio));
}

void main() {
  // EpisodeMetadataService caches AniZip payloads in a Hive box, so the season
  // lookup needs somewhere to put one.
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('season-chain');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('walking a franchise', () {
    test('orders the chain and numbers it from the first season', () async {
      // 1 → 2 → 3, opened on the MIDDLE one. AniList reports no season number,
      // so the number has to come from position once the head is found.
      final fake = _FakeAniList({
        2: [
          (rel: 'PREQUEL', id: 1, format: 'TV'),
          (rel: 'SEQUEL', id: 3, format: 'TV'),
        ],
        1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
        3: [(rel: 'PREQUEL', id: 2, format: 'TV')],
      });
      final seasons = await _chain(fake).of(anilistId: 2, currentTitle: 'S2');

      expect(seasons.map((s) => s.number), [1, 2, 3]);
      expect(seasons.map((s) => s.anilistId), [1, 2, 3]);
      expect(seasons.singleWhere((s) => s.isCurrent).number, 2);
      expect(seasons[1].title, 'S2', reason: 'the open title keeps its own name');
    });

    test('a title with no prequel and no sequel gets no section', () async {
      // Most titles. An empty list is what tells the UI to draw nothing.
      final fake = _FakeAniList({1: []});
      expect(await _chain(fake).of(anilistId: 1, currentTitle: 'Solo'), isEmpty);
    });

    test('movies, specials and OVAs stay out of the numbering', () async {
      // They are related, and they already appear under Related. Calling a film
      // "Season 2" is worse than leaving it where it is.
      final fake = _FakeAniList({
        1: [
          (rel: 'SEQUEL', id: 9, format: 'MOVIE'),
          (rel: 'SEQUEL', id: 2, format: 'TV'),
        ],
        2: [(rel: 'PREQUEL', id: 1, format: 'TV')],
      });
      final seasons = await _chain(fake).of(anilistId: 1, currentTitle: 'S1');
      expect(seasons.map((s) => s.anilistId), [1, 2]);
      expect(seasons.any((s) => s.anilistId == 9), isFalse);
    });

    test('a chain that loops back on itself still terminates', () async {
      // Real relation graphs do this: a sequel whose own sequel points back at
      // an earlier entry. Without the seen-set the walk runs to the cap every
      // time — eight wasted requests per open.
      final fake = _FakeAniList({
        1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
        2: [(rel: 'SEQUEL', id: 1, format: 'TV')],
      });
      final seasons = await _chain(fake).of(anilistId: 1, currentTitle: 'S1');
      expect(seasons.map((s) => s.anilistId), [1, 2]);
      expect(fake.asked.length, lessThan(SeasonChain.maxSeasons));
    });

    test('a very long franchise stops at the cap', () async {
      final fake = _FakeAniList({
        for (var i = 1; i <= 40; i++)
          i: [(rel: 'SEQUEL', id: i + 1, format: 'TV')],
      });
      final seasons = await _chain(fake).of(anilistId: 1, currentTitle: 'S1');
      expect(seasons.length, SeasonChain.maxSeasons + 1);
    });

    test('a failed hop keeps what it already walked', () async {
      // AniList rate-limits. Losing the whole section because hop three failed
      // would be worse than showing the two seasons already in hand.
      final fake = _FakeAniList({
        1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
        // id 2 is absent → the fake returns no edges, so the walk just ends.
      });
      final seasons = await _chain(fake).of(anilistId: 1, currentTitle: 'S1');
      expect(seasons.map((s) => s.number), [1, 2]);
    });
  });

  test('the chain is built once per franchise, not once per season', () async {
    // Opening S1 then S3 must not re-walk: every member caches the same list.
    final fake = _FakeAniList({
      1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
      2: [
        (rel: 'PREQUEL', id: 1, format: 'TV'),
        (rel: 'SEQUEL', id: 3, format: 'TV'),
      ],
      3: [(rel: 'PREQUEL', id: 2, format: 'TV')],
    });
    final chain = _chain(fake);
    await chain.of(anilistId: 1, currentTitle: 'S1');
    final firstPass = fake.asked.length;
    await chain.of(anilistId: 3, currentTitle: 'S3');
    expect(fake.asked.length, firstPass, reason: 're-walked a cached chain');
  });

  group('real season numbers collapse a split cour', () {
    // The bug this fixes, from the device: Mushoku Tensei walked to FIVE
    // entries and labelled "Mushoku Tensei II" as Season 3, because AniList
    // files each cour as its own title and position was doing the numbering.
    // AniZip stamps both halves of a cour with the same season.
    //
    // Chain 1→2→3→4→5, real seasons 1,1,2,2,3. The fake mints mal = id + 1000.
    _FakeAniList splitCour() => _FakeAniList(
      {
        1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
        2: [
          (rel: 'PREQUEL', id: 1, format: 'TV'),
          (rel: 'SEQUEL', id: 3, format: 'TV'),
        ],
        3: [
          (rel: 'PREQUEL', id: 2, format: 'TV'),
          (rel: 'SEQUEL', id: 4, format: 'TV'),
        ],
        4: [
          (rel: 'PREQUEL', id: 3, format: 'TV'),
          (rel: 'SEQUEL', id: 5, format: 'TV'),
        ],
        5: [(rel: 'PREQUEL', id: 4, format: 'TV')],
      },
      seasonOf: {1001: 1, 1002: 1, 1003: 2, 1004: 2, 1005: 3},
    );

    test('five chain entries become three seasons', () async {
      final seasons = await _chain(splitCour())
          .of(anilistId: 5, currentTitle: 'S3', currentMalId: 1005);
      expect(seasons.map((s) => s.number), [1, 2, 3],
          reason: 'position numbering would say 1,2,3,4,5');
      expect(seasons.length, 3);
    });

    test('a collapsed season points at its FIRST cour', () async {
      final seasons = await _chain(splitCour())
          .of(anilistId: 5, currentTitle: 'S3', currentMalId: 1005);
      expect(seasons.firstWhere((s) => s.number == 2).anilistId, 3,
          reason: 'season 2 starts at its first cour, not its second');
    });

    test('but points at the cour you are actually on', () async {
      // Opened on the SECOND cour of season 2 — "you are here" has to land on
      // that card, not send you back to cour one.
      final seasons = await _chain(splitCour())
          .of(anilistId: 4, currentTitle: 'S2 Part 2', currentMalId: 1004);
      final s2 = seasons.firstWhere((s) => s.number == 2);
      expect(s2.anilistId, 4);
      expect(s2.isCurrent, isTrue);
      expect(seasons.where((s) => s.isCurrent), hasLength(1));
    });

    test('one unmapped entry falls the WHOLE list back to position', () async {
      // Mixing a real "Season 2" with a guessed one leaves no way to tell
      // which is which, so it is all-or-nothing.
      final fake = _FakeAniList(
        {
          1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
          2: [(rel: 'PREQUEL', id: 1, format: 'TV')],
        },
        seasonOf: {1001: 1}, // 1002 missing — AniZip lags on new seasons
      );
      final seasons =
          await _chain(fake).of(anilistId: 1, currentTitle: 'S1', currentMalId: 1001);
      expect(seasons.map((s) => s.number), [1, 2]);
    });

    test('no AniZip mapping at all still produces an ordered list', () async {
      final fake = _FakeAniList({
        1: [(rel: 'SEQUEL', id: 2, format: 'TV')],
        2: [(rel: 'PREQUEL', id: 1, format: 'TV')],
      });
      final seasons =
          await _chain(fake).of(anilistId: 1, currentTitle: 'S1', currentMalId: 1001);
      expect(seasons.map((s) => s.number), [1, 2]);
    });
  });
}
