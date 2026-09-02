// Relations follow the metadata provider the user picked; cast cannot, because
// neither MAL nor Simkl serves any. The payloads below are trimmed copies of
// what the live endpoints actually returned when this was written — both APIs
// accept fields they do not answer with, so the shapes are worth pinning.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/metadata/metadata_enrichment.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Object? Function(Uri uri) respond;
  final seen = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async {
    seen.add(o.uri);
    final body = respond(o.uri);
    return ResponseBody.fromString(
      jsonEncode(body ?? const <String, dynamic>{}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _malAnime = {
  'related_anime': [
    {
      'node': {
        'id': 121,
        'title': 'Fullmetal Alchemist',
        'main_picture': {'large': 'https://cdn.myanimelist.net/a.jpg'},
      },
      'relation_type_formatted': 'Alternative version',
    },
  ],
  'recommendations': [
    {
      'node': {'id': 11061, 'title': 'Hunter x Hunter (2011)'},
    },
  ],
};

const _malManga = {
  'related_manga': [
    {
      'node': {'id': 502, 'title': 'Fullmetal Alchemist: Prototype'},
      'relation_type_formatted': 'Side story',
    },
  ],
};

const _simklFull = {
  'users_recommendations': [
    {
      'title': 'Interstellar',
      'poster': '20/2052598c2716ef054',
      'ids': {'simkl': 250822},
    },
  ],
};

MediaDetail _detail({
  required ProviderType type,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
}) => MediaDetail(
  id: 'x',
  title: 'T',
  url: 'u',
  type: type,
  sourceId: 's',
  malId: malId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relations');
    Hive.init(dir.path);
    await Hive.openBox(MetadataProviderPrefs.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<MetadataProviderPrefs> prefsWith({
    AnimeProvider? anime,
    VideoProvider? video,
  }) async {
    final p = await MetadataProviderPrefs.open();
    if (anime != null) await p.setAnime(anime);
    if (video != null) await p.setVideo(video);
    return p;
  }

  MetadataEnrichment build(_Adapter a, MetadataProviderPrefs? p) {
    final dio = Dio()..httpClientAdapter = a;
    return MetadataEnrichment(dio, () => null, () => p);
  }

  test('MAL supplies an anime title\'s relations when MAL is the pick', () async {
    final a = _Adapter(
      (uri) => uri.host == 'api.myanimelist.net' ? _malAnime : null,
    );
    final out = await build(
      a,
      await prefsWith(anime: AnimeProvider.mal),
    ).fetch(_detail(type: ProviderType.anime, malId: 5114));

    expect(a.seen.any((u) => u.path == '/v2/anime/5114'), isTrue);
    expect(out.relations.map((r) => r.title), [
      'Fullmetal Alchemist',
      'Hunter x Hunter (2011)',
    ]);
    expect(out.relations.first.relation, 'Alternative version');
    // Recommendations arrive unlabelled and get one, so the row is not blank.
    expect(out.relations.last.relation, 'Recommended');
    // The anime id rides along; it sharpens the match when the tap searches.
    expect(out.relations.first.malId, 121);
  });

  test('a manga reads MAL\'s manga side and carries no id', () async {
    final a = _Adapter(
      (uri) => uri.host == 'api.myanimelist.net' ? _malManga : null,
    );
    final out = await build(
      a,
      await prefsWith(anime: AnimeProvider.mal),
    ).fetch(_detail(type: ProviderType.manga, malId: 25));

    expect(a.seen.any((u) => u.path == '/v2/manga/25'), isTrue);
    expect(out.relations.single.title, 'Fullmetal Alchemist: Prototype');
    // A manga id compared against the anime ids sources report would match the
    // wrong show, so it is deliberately dropped.
    expect(out.relations.single.malId, isNull);
  });

  test('AniList still answers when AniList is the pick', () async {
    final a = _Adapter((uri) => null);
    final out = await build(
      a,
      await prefsWith(anime: AnimeProvider.anilist),
    ).fetch(_detail(type: ProviderType.anime, malId: 5114));

    expect(a.seen.any((u) => u.host == 'api.myanimelist.net'), isFalse);
    expect(out.relations, isEmpty);
  });

  test('Simkl answers for a movie, resolving its own id first', () async {
    final a = _Adapter((uri) {
      if (uri.path == '/search/id') {
        return [
          {
            'ids': {'simkl': 472214},
          },
        ];
      }
      if (uri.path == '/movies/472214') return _simklFull;
      return null;
    });
    final out = await build(
      a,
      await prefsWith(video: VideoProvider.simkl),
    ).fetch(_detail(type: ProviderType.movie, tmdbId: 27205));

    expect(a.seen.map((u) => u.path), contains('/movies/472214'));
    expect(out.relations.single.title, 'Interstellar');
    expect(out.relations.single.cover, contains('simkl.in/posters/'));
  });

  // The two TMDB calls go out together now. The whole reason that is safe is
  // that a dead request answers null rather than throwing — if it threw, one
  // failure would take the other's result with it and blank both tabs.
  group('one failed TMDB call does not blank the other', () {
    const credits = {
      'cast': [
        {'id': 1, 'name': 'Leonardo DiCaprio', 'character': 'Cobb'},
      ],
    };
    const recs = {
      'results': [
        {'id': 157336, 'title': 'Interstellar'},
      ],
    };

    Future<void> check({
      required bool creditsOk,
      required bool recsOk,
    }) async {
      final a = _Adapter((uri) {
        if (uri.path.endsWith('/credits')) {
          if (!creditsOk) throw const SocketException('down');
          return credits;
        }
        if (uri.path.endsWith('/recommendations')) {
          if (!recsOk) throw const SocketException('down');
          return recs;
        }
        return null;
      });
      final out = await build(a, null)
          .fetch(_detail(type: ProviderType.movie, tmdbId: 27205));

      expect(out.cast.length, creditsOk ? 1 : 0);
      expect(out.relations.length, recsOk ? 1 : 0);
    }

    test('cast fails, recommendations still show', () =>
        check(creditsOk: false, recsOk: true));
    test('recommendations fail, cast still shows', () =>
        check(creditsOk: true, recsOk: false));
    test('both succeed', () => check(creditsOk: true, recsOk: true));
    test('both fail, and nothing throws', () =>
        check(creditsOk: false, recsOk: false));
  });

  // MAL numbers manga and anime separately, so a manga id read from the ANIME
  // catalogue lands on an unrelated show — MAL manga 25 is Fullmetal
  // Alchemist, MAL anime 25 is Sunabouzu. Reading titles used to take that
  // path whenever they carried an id, which is every metadata-backed one.
  group('a reading title never asks the anime catalogue', () {
    String? typeIn(String body) {
      final m = RegExp(r'type:(ANIME|MANGA)').firstMatch(body);
      return m?.group(1);
    }

    Future<String?> askedTypeFor(ProviderType type) async {
      String? asked;
      final a = _Adapter((uri) => null);
      final dio = Dio()
        ..httpClientAdapter = _Recorder((body) => asked = typeIn(body));
      await MetadataEnrichment(dio, () => null, () => null)
          .fetch(_detail(type: type, malId: 25));
      // Keeps the analyzer honest about the unused adapter above.
      expect(a.seen, isEmpty);
      return asked;
    }

    test('a manga is looked up as MANGA', () async {
      expect(await askedTypeFor(ProviderType.manga), 'MANGA');
    });

    test('a novel is looked up as MANGA — AniList files them together', () async {
      expect(await askedTypeFor(ProviderType.novel), 'MANGA');
    });

    test('an anime still goes to the anime catalogue', () async {
      expect(await askedTypeFor(ProviderType.anime), 'ANIME');
    });
  });

  test('no preference reader leaves the old behaviour alone', () async {
    final a = _Adapter((uri) => null);
    final out = await build(a, null)
        .fetch(_detail(type: ProviderType.anime, malId: 5114));

    expect(a.seen.any((u) => u.host == 'api.myanimelist.net'), isFalse);
    expect(out.relations, isEmpty);
  });
}

/// Captures the GraphQL body so the query's `type:` can be asserted.
class _Recorder implements HttpClientAdapter {
  _Recorder(this.onBody);
  final void Function(String body) onBody;

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async {
    onBody(o.data is String ? o.data as String : jsonEncode(o.data));
    return ResponseBody.fromString(
      jsonEncode({'data': {'Media': null}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
