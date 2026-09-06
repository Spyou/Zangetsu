// Opening a show from a source's own browse screen has to land on the SAME
// show Home opens, or the app keeps two progress records for it — two rows in
// Continue Watching at two different episodes, and only the catalogue one ever
// reaches a tracker.
//
// The rule is deliberately strict. Guessing wrong here opens somebody else's
// show, which is worse than the duplicate it is trying to avoid, so anything
// short of an exact title (or an exact MAL id) must return null and let the
// caller open the source's own item exactly as before.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/mal_catalogue.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

Map<String, dynamic> _al({
  int id = 1,
  int? idMal = 100,
  String romaji = 'Fullmetal Alchemist',
  String? english = 'FMA',
  int? chapters,
  int? episodes = 64,
}) => {
  'id': id,
  'idMal': idMal,
  'title': {'romaji': romaji, 'english': english},
  'coverImage': {'large': 'c'},
  'episodes': episodes,
  'chapters': chapters,
  'status': 'FINISHED',
  'genres': <String>[],
  'description': null,
  'seasonYear': 2009,
  'studios': {'nodes': <dynamic>[]},
  'nextAiringEpisode': null,
};

class _Src implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;
  @override
  bool hasSource(String sourceId) => true;
}

MediaItem _fromSource(
  String title, {
  ProviderType type = ProviderType.anime,
  int? malId,
}) => MediaItem(
  id: 'x',
  title: title,
  url: 'https://hianime/$title',
  type: type,
  sourceId: 'hianime',
  malId: malId,
);

/// A MAL /anime endpoint that always answers with [title].
class _MalAdapter implements HttpClientAdapter {
  _MalAdapter(this.title);
  final String title;

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async => ResponseBody.fromString(
        jsonEncode({
          'data': [
            {
              'node': {
                'id': 42,
                'title': title,
                'media_type': 'tv',
                'main_picture': {'large': 'https://x/42.jpg'},
              },
            },
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory dir;
  late _Src src;
  late List<String> anilistQueries;
  late List<String> tmdbPaths;

  late SourceMatcher matcher;

  MetadataRepository build({
    List<Map<String, dynamic>> anilistResults = const [],
    List<Map<String, dynamic>> tmdbResults = const [],
    bool anilistThrows = false,
  }) {
    return MetadataRepository(
      anilist: AniListCatalogue((q, v) async {
        anilistQueries.add(q);
        if (anilistThrows) throw Exception('AniList is down');
        return {'Page': {'media': anilistResults}};
      }),
      tmdb: TmdbCatalogue((p, q) async {
        tmdbPaths.add(p);
        return {'results': tmdbResults};
      }),
      sources: src,
      matcher: matcher,
      browseKind: () => ZKind.anime,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('canonical_for');
    Hive.init(dir.path);
    src = _Src();
    anilistQueries = [];
    tmdbPaths = [];
    matcher = SourceMatcher(
      sources: src,
      store: await MatchStore.open(),
      prefs: await ZSourcePrefs.open(),
      candidates: (_) => [(id: 'hianime', name: 'HiAnime')],
    );
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('an exact title resolves to the catalogue show', () async {
    final repo = build(anilistResults: [_al()]);
    final hit = await repo.canonicalFor(_fromSource('Fullmetal Alchemist'));
    expect(hit?.url, 'zm://anime/mal:100');
  });

  test('the English title counts too', () async {
    final repo = build(anilistResults: [_al()]);
    expect((await repo.canonicalFor(_fromSource('FMA')))?.url,
        'zm://anime/mal:100');
  });

  test('a different show is NOT accepted', () async {
    // bestTitleMatch falls back to the first result when nothing matches, so
    // without the second titleMatches check this would open Naruto for a user
    // who tapped something else entirely.
    final repo = build(anilistResults: [_al(romaji: 'Naruto', english: null)]);
    expect(await repo.canonicalFor(_fromSource('Fullmetal Alchemist')), isNull);
  });

  test('an empty catalogue answer is a miss, not a crash', () async {
    final repo = build();
    expect(await repo.canonicalFor(_fromSource('Fullmetal Alchemist')), isNull);
  });

  test('a MAL id on the source item beats the title', () async {
    // Sources that expose a MAL id are exact, so a title that reads nothing
    // like the catalogue's still resolves.
    final repo = build(anilistResults: [_al(romaji: 'Hagane no Renkinjutsushi')]);
    final hit = await repo.canonicalFor(
      _fromSource('FMA:B 2009 [Dual Audio]', malId: 100),
    );
    expect(hit?.url, 'zm://anime/mal:100');
  });

  test('a manga item is looked up in the manga catalogue', () async {
    // The kind comes from the item, not from whatever the app is browsing —
    // browseKind here is anime, and a manga source must not search anime.
    final repo = build(anilistResults: [_al(chapters: 108, episodes: null)]);
    final hit = await repo.canonicalFor(
      _fromSource('Fullmetal Alchemist', type: ProviderType.manga),
    );
    expect(hit?.url, 'zm://manga/mal:100');
  });

  test('a movie item goes to TMDB, not AniList', () async {
    final repo = build(tmdbResults: [
      {'id': 55, 'title': 'Dune', 'poster_path': '/p.jpg', 'media_type': 'movie'},
    ]);
    final hit = await repo.canonicalFor(
      _fromSource('Dune', type: ProviderType.movie),
    );
    expect(hit?.url, startsWith('zm://'));
    expect(anilistQueries, isEmpty);
    expect(tmdbPaths, isNotEmpty);
  });

  test('a season entry does NOT become the base show', () async {
    // The shared title matcher strips "Season 3" before comparing, which is
    // right when hunting a known title on a source and wrong here: linking
    // this would file season 3's progress under season 1 and scrobble it.
    final repo = build(anilistResults: [
      _al(romaji: 'Attack on Titan', english: null),
    ]);
    expect(await repo.canonicalFor(_fromSource('Attack on Titan Season 3')),
        isNull);
  });

  test('a remake does NOT inherit the original', () async {
    final repo = build(anilistResults: [
      _al(romaji: 'Fruits Basket', english: null),
    ]);
    expect(await repo.canonicalFor(_fromSource('Fruits Basket (2019)')), isNull);
  });

  test('wrapper and quality noise is still stripped', () async {
    // "Watch … Online HD" carries no identity, so it must not cost a match.
    final repo = build(anilistResults: [_al(romaji: 'One Piece', english: null)]);
    expect((await repo.canonicalFor(_fromSource('Watch One Piece Online HD')))?.url,
        'zm://anime/mal:100');
  });

  test('a MAL id still wins over decorations', () async {
    final repo = build(anilistResults: [
      _al(romaji: 'Shingeki no Kyojin', english: null),
    ]);
    final hit = await repo.canonicalFor(
      _fromSource('Attack on Titan Season 3 [1080p]', malId: 100),
    );
    expect(hit?.url, 'zm://anime/mal:100');
  });

  test('a catalogue that is down is a miss, never a throw', () async {
    final repo = build(anilistThrows: true);
    expect(await repo.canonicalFor(_fromSource('Fullmetal Alchemist')), isNull);
  });

  test('a title that is already canonical is returned untouched', () async {
    final repo = build();
    const item = MediaItem(
      id: 'mal:100',
      title: 'FMA',
      url: 'zm://anime/mal:100',
      type: ProviderType.anime,
      sourceId: 'zm',
    );
    expect((await repo.canonicalFor(item))?.url, 'zm://anime/mal:100');
    expect(anilistQueries, isEmpty);
  });

  test('MyAnimeList answers when it is the chosen provider', () async {
    // The link must work on whatever catalogue the user picked, not only
    // AniList: MAL and Simkl both hand back zm:// items of their own.
    final prefs = await MetadataProviderPrefs.open();
    await prefs.setAnime(AnimeProvider.mal);
    final dio = Dio()..httpClientAdapter = _MalAdapter('Fullmetal Alchemist');
    final repo = MetadataRepository(
      anilist: AniListCatalogue((q, v) async {
        anilistQueries.add(q);
        throw Exception('AniList must not be asked');
      }),
      tmdb: TmdbCatalogue((p, q) async => {'results': []}),
      mal: MalCatalogue(dio),
      providerPrefs: prefs,
      sources: src,
      matcher: matcher,
      browseKind: () => ZKind.anime,
    );

    final hit = await repo.canonicalFor(_fromSource('Fullmetal Alchemist'));

    expect(hit?.url, 'zm://anime/mal:42');
    expect(anilistQueries, isEmpty);
  });

  test('an empty title is a miss without asking the catalogue', () async {
    final repo = build(anilistResults: [_al()]);
    expect(await repo.canonicalFor(_fromSource('   ')), isNull);
    expect(anilistQueries, isEmpty);
  });
}
