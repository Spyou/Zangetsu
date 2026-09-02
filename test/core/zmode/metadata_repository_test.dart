import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/mal_catalogue.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _al({int? chapters, int? episodes = 12}) => {
  'id': 1, 'idMal': 100, 'title': {'romaji': 'FMA', 'english': null},
  'coverImage': {'large': 'c'}, 'episodes': episodes, 'chapters': chapters,
  'status': 'FINISHED', 'genres': [], 'description': null, 'seasonYear': 2009,
  'studios': {'nodes': []}, 'nextAiringEpisode': null,
};

const _stream = [VideoSource(url: 'https://stream/1')];

MetadataRepository _metaRepo({
  required SourceRepository sources,
  required SourceMatcher matcher,
  required MatchStore store,
  required ZSourcePrefs prefs,
  required ZKind Function() browseKind,
  AniListCatalogue? anilist,
  MalCatalogue? mal,
  void Function(String message)? onProviderFallback,
  List<({String id, String name})> Function(ZKind)? candidates,
}) =>
    MetadataRepository(
      anilist: anilist ??
          AniListCatalogue((q, v) async {
            if (q.contains('Media(')) {
              return {'Media': _al(chapters: browseKind() == ZKind.anime ? null : 5)};
            }
            final aliases = RegExp(r'(r\d+):').allMatches(q).map((m) => m.group(1)!);
            return {for (final a in aliases) a: {'media': [_al()]}};
          }),
      tmdb: TmdbCatalogue((p, q) async => {'results': []}),
      mal: mal,
      onProviderFallback: onProviderFallback,
      sources: sources,
      matcher: matcher,
      matchStore: store,
      sourcePrefs: prefs,
      health: SourceHealthStore(),
      candidates: candidates ?? ((_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: browseKind,
    );

class _Src implements SourceRepository {
  _Src({this.streams = _stream});
  final List<VideoSource> streams;
  final log = <String>[];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources =>
      [(id: 'allanime', name: 'AllAnime')];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      [MediaItem(id: 'fma', title: 'FMA', url: 'https://src/fma', type: ProviderType.anime, sourceId: 'allanime')];
  @override
  Future<List<Episode>> episodes(String url, {String category = 'sub', String? sourceId}) async {
    log.add('episodes:$url');
    return [
      const Episode(id: 'a', title: 'Ep 1', number: 1, url: 'https://src/fma/1'),
      const Episode(id: 'b', title: 'Ep 2', number: 2, url: 'https://src/fma/2'),
    ];
  }
  @override
  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId, bool fast = false}) async {
    log.add('sources:$episodeUrl:$sourceId');
    return streams;
  }
}

class _EpSrc implements SourceRepository {
  _EpSrc(this._eps, {this.streams = _stream});
  final List<Episode> _eps;
  final List<VideoSource> streams;
  final log = <String>[];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources =>
      [(id: 'allanime', name: 'AllAnime')];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async =>
      [MediaItem(id: 'fma', title: 'FMA', url: 'https://src/fma', type: ProviderType.anime, sourceId: 'allanime')];
  @override
  Future<List<Episode>> episodes(String url, {String category = 'sub', String? sourceId}) async => _eps;
  @override
  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId, bool fast = false}) async {
    log.add('sources:$episodeUrl:$sourceId');
    return streams;
  }
}

void main() {
  late Directory dir;
  late _Src src;
  late MetadataRepository repo;
  late MatchStore store;
  late ZSourcePrefs prefs;
  var kind = ZKind.anime;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('metarepo');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    src = _Src();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    repo = _metaRepo(
      sources: src,
      store: store,
      prefs: prefs,
      browseKind: () => kind,
      matcher: SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
    );
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('home follows browseKind', () async {
    kind = ZKind.anime;
    expect((await repo.home()).first.items.single.type, ProviderType.anime);
    kind = ZKind.manga;
    expect((await repo.home()).first.items.single.type, ProviderType.manga);
  });

  test('home falls back to MAL when AniList returns empty', () async {
    kind = ZKind.anime;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                'data': [
                  {
                    'node': {
                      'id': 100,
                      'title': 'FMA',
                      'main_picture': {'large': 'https://example.com/c.jpg'},
                      'alternative_titles': {},
                      'genres': [],
                    },
                    'ranking': {'rank': 1},
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    String? fallback;
    final r = _metaRepo(
      sources: src,
      store: store,
      prefs: prefs,
      browseKind: () => kind,
      matcher: SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
      anilist: AniListCatalogue((q, v) async => null),
      mal: MalCatalogue(dio),
      onProviderFallback: (name) => fallback = name,
    );
    final rows = await r.home();
    expect(rows, isNotEmpty);
    expect(fallback, 'MyAnimeList');
  });

  test('sourceId is the pseudo id and displayName is human', () {
    expect(repo.sourceId, ZmodeIds.sourceId);
    expect(repo.displayName(ZmodeIds.sourceId), isNotEmpty);
    expect(repo.hasSource(ZmodeIds.sourceId), isTrue);
  });

  test('sources() resolves the show then plays the same-numbered episode', () async {
    kind = ZKind.anime;
    await repo.sources('zm://anime/mal:100/ep/2', fast: true);
    expect(src.log, ['episodes:https://src/fma', 'sources:https://src/fma/2:allanime']);
  });

  test('sources() with no match throws NoSourceMatch', () async {
    final dead = _NoHits();
    final r = _metaRepo(
      sources: dead,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.anime,
      candidates: (_) => [(id: 'x', name: 'X')],
      matcher: SourceMatcher(
        sources: dead,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'x', name: 'X')],
      ),
      anilist: AniListCatalogue((q, v) async => {'Media': _al()}),
    );
    expect(() => r.sources('zm://anime/mal:100/ep/1'), throwsA(isA<NoSourceMatch>()));
  });

  test('manga detail carries the matched source chapters and ids', () async {
    kind = ZKind.manga;
    final d = await repo.detail('zm://manga/mal:100');
    expect(d.sourceId, 'allanime');
    expect(d.id, 'fma');
    expect(d.episodes.length, 2);
    expect(d.episodes.first.url, 'https://src/fma/1');
    expect(d.title, 'FMA');
  });

  test('anime detail shows catalogue episodes without source matching', () async {
    kind = ZKind.anime;
    final d = await repo.detail('zm://anime/mal:100');
    expect(d.sourceId, ZmodeIds.sourceId);
    expect(d.id, 'mal:100');
    expect(d.episodes.length, 12);
    expect(d.episodes.first.title, 'Episode 1');
    expect(d.episodes.first.url, 'zm://anime/mal:100/ep/1');
    expect(src.log, isEmpty);
  });

  test('unmatched anime detail keeps the synthesised catalogue episode list', () async {
    final dead = _NoHits();
    final r = _metaRepo(
      sources: dead,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.anime,
      matcher: SourceMatcher(
        sources: dead,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'x', name: 'X')],
      ),
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al()} : {'Page': {'media': [_al()]}}),
    );
    final d = await r.detail('zm://anime/mal:100');
    expect(d.episodes.length, 12);
    expect(d.episodes.first.url, 'zm://anime/mal:100/ep/1');
    expect(d.sourceId, ZmodeIds.sourceId);
  });

  test('sources() plays the episode url that detail() displays', () async {
    kind = ZKind.anime;
    final d = await repo.detail('zm://anime/mal:100');
    await repo.sources(d.episodes[1].url, fast: true);
    expect(src.log.last, 'sources:https://src/fma/2:allanime');
  });

  test('unmatched manga detail drops the synthesised chapter list', () async {
    final dead = _NoHits();
    final r = _metaRepo(
      sources: dead,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.manga,
      matcher: SourceMatcher(
        sources: dead,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'x', name: 'X')],
      ),
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al(chapters: 5)} : {'Page': {'media': [_al()]}}),
    );
    final d = await r.detail('zm://manga/mal:100');
    expect(d.episodes, isEmpty);
    expect(d.sourceId, ZmodeIds.sourceId);
  });

  test('episode missing on all sources throws EpisodeNotAvailable', () async {
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ep 1', number: 1, url: 'https://src/fma/1'),
      Episode(id: 'b', title: 'Ep 2', number: 2, url: 'https://src/fma/2'),
    ]);
    final r = _metaRepo(
      sources: es,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.anime,
      matcher: SourceMatcher(
        sources: es,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al()} : {'Page': {'media': [_al()]}}),
    );
    expect(
      () => r.sources('zm://anime/mal:100/ep/5'),
      throwsA(isA<EpisodeNotAvailable>()),
    );
  });

  test('unnumbered source episodes resolve by position at play time', () async {
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ch 1', url: 'https://src/fma/1'),
      Episode(id: 'b', title: 'Ch 2', url: 'https://src/fma/2'),
    ]);
    final r = _metaRepo(
      sources: es,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.anime,
      matcher: SourceMatcher(
        sources: es,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
    );
    await r.sources('zm://anime/mal:100/ep/2');
    expect(es.log, ['sources:https://src/fma/2:allanime']);
  });

  test('detail shows catalogue numbering; play uses source list position', () async {
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ep 0', number: 0, url: 'https://src/fma/0'),
      Episode(id: 'b', title: 'Ep 1', number: 1, url: 'https://src/fma/1'),
    ]);
    final r = _metaRepo(
      sources: es,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      browseKind: () => ZKind.anime,
      matcher: SourceMatcher(
        sources: es,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
    );
    final d = await r.detail('zm://anime/mal:100');
    expect(d.episodes[0].title, 'Episode 1');
    expect(d.episodes[0].url, 'zm://anime/mal:100/ep/1');
    await r.sources(d.episodes[0].url, fast: true);
    expect(es.log, ['sources:https://src/fma/0:allanime']);
  });

  test('a saved match skips search when title is already cached', () async {
    const canonical = ZCanonical(ZKind.anime, 'mal:100');
    await store.save(canonical, const SourceMatch(
      sourceId: 'allanime', showUrl: 'https://src/fma', showId: 'fma', showTitle: 'FMA', pinned: false,
    ));
    prefs.set(canonical.kind, 'allanime');
    var gqlCalls = 0;
    final r = _metaRepo(
      sources: src,
      store: store,
      prefs: prefs,
      browseKind: () => ZKind.anime,
      matcher: SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => [(id: 'allanime', name: 'AllAnime')],
      ),
      anilist: AniListCatalogue((q, v) async {
        gqlCalls++;
        return {'Media': _al()};
      }),
    );
    await r.detail('zm://anime/mal:100');
    gqlCalls = 0;
    src.log.clear();
    await r.sources('zm://anime/mal:100/ep/2');
    expect(gqlCalls, 0);
    expect(src.log, ['episodes:https://src/fma', 'sources:https://src/fma/2:allanime']);
  });
}

class _NoHits implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get loadedSources => [(id: 'x', name: 'X')];
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async => const [];
}
