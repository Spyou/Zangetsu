import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _al({int? chapters, int? episodes = 12}) => {
  'id': 1, 'idMal': 100, 'title': {'romaji': 'FMA', 'english': null},
  'coverImage': {'large': 'c'}, 'episodes': episodes, 'chapters': chapters,
  'status': 'FINISHED', 'genres': [], 'description': null, 'seasonYear': 2009,
  'studios': {'nodes': []}, 'nextAiringEpisode': null,
};

class _Src implements SourceRepository {
  final log = <String>[];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
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
    return const [];
  }
}

/// A [SourceRepository] whose search always matches "FMA" on `allanime` but
/// whose episode list is whatever the test hands it — for exercising the
/// number/index fallback in `_sourceEpisode`.
class _EpSrc implements SourceRepository {
  _EpSrc(this._eps);
  final List<Episode> _eps;
  final log = <String>[];
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
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
    return const [];
  }
}

void main() {
  late Directory dir;
  late _Src src;
  late MetadataRepository repo;
  var kind = ZKind.anime;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('metarepo');
    Hive.init(dir.path);
    src = _Src();
    final store = await MatchStore.open();
    repo = MetadataRepository(
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al(chapters: kind == ZKind.anime ? null : 5)}
                               : {'Page': {'media': [_al()]}}),
      tmdb: TmdbCatalogue((p, q) async => {'results': []}),
      sources: src,
      matcher: SourceMatcher(sources: src, store: store,
          candidates: (_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: () => kind,
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
    final store = await MatchStore.open();
    final dead = _NoHits();
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async => {'Media': _al()}),
      tmdb: TmdbCatalogue((p, q) async => null),
      sources: dead,
      matcher: SourceMatcher(sources: dead, store: store,
          candidates: (_) => [(id: 'x', name: 'X')]),
      browseKind: () => ZKind.anime,
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
    expect(d.title, 'FMA'); // metadata title kept
  });

  test('anime detail keeps zm episode urls', () async {
    kind = ZKind.anime;
    final d = await repo.detail('zm://anime/mal:100');
    expect(d.sourceId, ZmodeIds.sourceId);
    expect(d.episodes.first.url, 'zm://anime/mal:100/ep/1');
  });

  test('unmatched manga detail drops the synthesised chapter list', () async {
    final store = await MatchStore.open();
    final dead = _NoHits();
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al(chapters: 5)} : {'Page': {'media': [_al()]}}),
      tmdb: TmdbCatalogue((p, q) async => null),
      sources: dead,
      matcher: SourceMatcher(sources: dead, store: store,
          candidates: (_) => [(id: 'x', name: 'X')]),
      browseKind: () => ZKind.manga,
    );
    final d = await r.detail('zm://manga/mal:100');
    expect(d.episodes, isEmpty);
    expect(d.sourceId, ZmodeIds.sourceId);
  });

  test('episode missing on a matched source throws EpisodeNotOnSource, not NoSourceMatch', () async {
    final store = await MatchStore.open();
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ep 1', number: 1, url: 'https://src/fma/1'),
      Episode(id: 'b', title: 'Ep 2', number: 2, url: 'https://src/fma/2'),
    ]);
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al()} : {'Page': {'media': [_al()]}}),
      tmdb: TmdbCatalogue((p, q) async => null),
      sources: es,
      matcher: SourceMatcher(sources: es, store: store,
          candidates: (_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: () => ZKind.anime,
    );
    expect(() => r.sources('zm://anime/mal:100/ep/5'), throwsA(isA<EpisodeNotOnSource>()));
  });

  test('unnumbered source episodes fall back to positional index', () async {
    final store = await MatchStore.open();
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ch 1', url: 'https://src/fma/1'),
      Episode(id: 'b', title: 'Ch 2', url: 'https://src/fma/2'),
    ]);
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al()} : {'Page': {'media': [_al()]}}),
      tmdb: TmdbCatalogue((p, q) async => null),
      sources: es,
      matcher: SourceMatcher(sources: es, store: store,
          candidates: (_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: () => ZKind.anime,
    );
    await r.sources('zm://anime/mal:100/ep/2');
    expect(es.log, ['sources:https://src/fma/2:allanime']);
  });

  test('a zero-based source does not silently guess the wrong episode', () async {
    final store = await MatchStore.open();
    final es = _EpSrc(const [
      Episode(id: 'a', title: 'Ep 0', number: 0, url: 'https://src/fma/0'),
      Episode(id: 'b', title: 'Ep 1', number: 1, url: 'https://src/fma/1'),
    ]);
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async =>
          q.contains('Media(') ? {'Media': _al()} : {'Page': {'media': [_al()]}}),
      tmdb: TmdbCatalogue((p, q) async => null),
      sources: es,
      matcher: SourceMatcher(sources: es, store: store,
          candidates: (_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: () => ZKind.anime,
    );
    expect(() => r.sources('zm://anime/mal:100/ep/2'), throwsA(isA<EpisodeNotOnSource>()));
  });

  test('a saved match skips the metadata round trip entirely', () async {
    final store = await MatchStore.open();
    const canonical = ZCanonical(ZKind.anime, 'mal:100');
    await store.save(canonical, const SourceMatch(
      sourceId: 'allanime', showUrl: 'https://src/fma', showId: 'fma', showTitle: 'FMA', pinned: false,
    ));
    await store.selectSource(canonical, 'allanime');
    var gqlCalls = 0;
    final r = MetadataRepository(
      anilist: AniListCatalogue((q, v) async {
        gqlCalls++;
        return {'Media': _al()};
      }),
      tmdb: TmdbCatalogue((p, q) async {
        gqlCalls++;
        return null;
      }),
      sources: src,
      matcher: SourceMatcher(sources: src, store: store,
          candidates: (_) => [(id: 'allanime', name: 'AllAnime')]),
      browseKind: () => ZKind.anime,
    );
    await r.sources('zm://anime/mal:100/ep/2');
    expect(gqlCalls, 0);
    expect(src.log, ['episodes:https://src/fma', 'sources:https://src/fma/2:allanime']);
  });
}

class _NoHits implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  bool hasSource(String sourceId) => true;
  @override
  Future<List<MediaItem>> search(String q, {String category = 'sub', String? sourceId}) async => const [];
}
