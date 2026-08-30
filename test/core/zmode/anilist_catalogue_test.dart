import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _media({
  int id = 1,
  int? idMal = 100,
  String romaji = 'Fullmetal Alchemist',
  String? english = 'FMA',
  int? episodes = 64,
  int? chapters,
  String status = 'FINISHED',
  int? nextEp,
  String? banner = 'https://img/banner.jpg',
}) => {
  'id': id,
  'idMal': idMal,
  'title': {'romaji': romaji, 'english': english},
  'coverImage': {'large': 'https://img/$id.jpg', 'extraLarge': null},
  'bannerImage': banner,
  'episodes': episodes,
  'chapters': chapters,
  'status': status,
  'genres': ['Action'],
  'description': 'desc',
  'seasonYear': 2009,
  'studios': {'nodes': [{'name': 'Bones'}]},
  'nextAiringEpisode': nextEp == null ? null : {'episode': nextEp},
};

/// Answers a home() aliased request: `r0: Page(...){ media{...} }` etc — pull
/// out however many `rN:` aliases the query actually asked for and answer
/// each with the same page of [media], mirroring what AniList's real
/// response shape looks like for an aliased multi-query.
Map<String, dynamic> _aliasedResponse(String query, {List<dynamic>? media}) {
  final aliases = RegExp(r'(r\d+):').allMatches(query).map((m) => m.group(1)!);
  return {for (final a in aliases) a: {'media': media ?? [_media()]}};
}

void main() {
  test('home issues exactly one request for every row and maps items', () async {
    var calls = 0;
    final cat = AniListCatalogue((q, v) async {
      calls++;
      return _aliasedResponse(q);
    });
    final rows = await cat.home(ZKind.anime);
    expect(calls, 1); // one round-trip for the whole page, not one per row
    expect(rows.length, 7); // Trending, this season, next season, all-time
                             // popular, top rated, Action, Romance
    expect(rows.first.title, 'Trending');
    final item = rows.first.items.single;
    expect(item.url, 'zm://anime/mal:100');
    expect(item.sourceId, ZmodeIds.sourceId);
    expect(item.type, ProviderType.anime);
    expect(item.malId, 100);
    expect(item.title, 'Fullmetal Alchemist');
    expect(item.englishTitle, 'FMA');
    expect(item.banner, 'https://img/banner.jpg');
  });

  test('home for manga/novel also issues one request and maps items', () async {
    var calls = 0;
    final cat = AniListCatalogue((q, v) async {
      calls++;
      return _aliasedResponse(q);
    });
    final rows = await cat.home(ZKind.manga);
    expect(calls, 1);
    expect(rows.length, 5); // Trending, Popular, Top rated, Action, Romance
  });

  test('a malformed/partial multi-row response still yields the rows it can',
      () async {
    final cat = AniListCatalogue((q, v) async {
      // r0 is fine, r1 is the wrong shape, r2 is simply missing — the rest
      // (if any) never get a key either, which is the "missing" case too.
      return {
        'r0': {'media': [_media()]},
        'r1': {'media': 'not-a-list'},
      };
    });
    final rows = await cat.home(ZKind.anime);
    expect(rows.length, 1);
    expect(rows.single.title, 'Trending');
  });

  test('a null response yields an empty home, not a throw', () async {
    final cat = AniListCatalogue((q, v) async => null);
    expect(await cat.home(ZKind.anime), isEmpty);
  });

  test('falls back to the AniList id when there is no MAL id', () async {
    final cat = AniListCatalogue((q, v) async =>
        {'Page': {'media': [_media(idMal: null, id: 77)]}});
    final rows = await cat.search('x', ZKind.anime);
    expect(rows.single.url, 'zm://anime/al:77');
    expect(rows.single.malId, isNull);
  });

  test('manga and novel carry their own kind and type', () async {
    final cat = AniListCatalogue((q, v) async =>
        {'Page': {'media': [_media(chapters: 10, episodes: null)]}});
    expect((await cat.search('x', ZKind.manga)).single.type, ProviderType.manga);
    expect((await cat.search('x', ZKind.novel)).single.url,
        'zm://novel/mal:100');
  });

  test('novel search asks AniList for the NOVEL format', () async {
    String? query;
    final cat = AniListCatalogue((q, v) async {
      query = q;
      return {'Page': {'media': []}};
    });
    await cat.search('x', ZKind.novel);
    expect(query, contains('format_in:[NOVEL]'));
  });

  test('detail lists episodes 1..n with zm urls', () async {
    final cat = AniListCatalogue((q, v) async => {'Media': _media()});
    final d = await cat.detail(const ZCanonical(ZKind.anime, 'mal:100'));
    expect(d.title, 'Fullmetal Alchemist');
    expect(d.studios, ['Bones']);
    expect(d.year, '2009');
    expect(d.episodes.length, 64);
    expect(d.episodes.first.number, 1);
    expect(d.episodes.first.url, 'zm://anime/mal:100/ep/1');
    expect(d.episodes.last.url, 'zm://anime/mal:100/ep/64');
  });

  test('an airing show lists only the episodes that are out', () async {
    final cat = AniListCatalogue((q, v) async =>
        {'Media': _media(episodes: null, status: 'RELEASING', nextEp: 8)});
    final d = await cat.detail(const ZCanonical(ZKind.anime, 'mal:100'));
    expect(d.episodes.length, 7);
  });

  test('manga with no chapter count has no chapter list', () async {
    final cat = AniListCatalogue((q, v) async =>
        {'Media': _media(episodes: null, chapters: null)});
    final d = await cat.detail(const ZCanonical(ZKind.manga, 'mal:100'));
    expect(d.episodes, isEmpty);
  });

  test('detail queries by idMal for mal ids and by id for al ids', () async {
    final vars = <Map<String, dynamic>>[];
    final cat = AniListCatalogue((q, v) async {
      vars.add(v);
      return {'Media': _media()};
    });
    await cat.detail(const ZCanonical(ZKind.anime, 'mal:100'));
    await cat.detail(const ZCanonical(ZKind.anime, 'al:77'));
    expect(vars[0], {'idMal': 100});
    expect(vars[1], {'id': 77});
  });

  test('detail carries the banner image through', () async {
    final cat = AniListCatalogue((q, v) async => {'Media': _media()});
    final d = await cat.detail(const ZCanonical(ZKind.anime, 'mal:100'));
    expect(d.banner, 'https://img/banner.jpg');
  });
}
