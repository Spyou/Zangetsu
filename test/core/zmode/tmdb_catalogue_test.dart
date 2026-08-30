import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _movie({int id = 438631, String title = 'Dune'}) => {
  'id': id, 'title': title, 'poster_path': '/p.jpg',
  'release_date': '2021-10-22', 'overview': 'sand', 'media_type': 'movie',
  'genres': [{'name': 'Sci-Fi'}], 'status': 'Released',
};
Map<String, dynamic> _tv({int id = 1399, String name = 'Game of Thrones'}) => {
  'id': id, 'name': name, 'poster_path': '/t.jpg', 'first_air_date': '2011-04-17',
  'overview': 'winter', 'media_type': 'tv', 'genres': [{'name': 'Drama'}],
  'status': 'Ended', 'seasons': [
    {'season_number': 0, 'episode_count': 5},
    {'season_number': 1, 'episode_count': 10},
    {'season_number': 2, 'episode_count': 10},
  ],
};

void main() {
  test('home rows mix movies and tv, both typed as movie sources', () async {
    final cat = TmdbCatalogue((p, q) async => {'results': [_movie(), _tv()]});
    final rows = await cat.home();
    expect(rows.length, 4);
    final items = rows.first.items;
    expect(items[0].url, 'zm://movie/tmdb:438631');
    expect(items[0].tmdbId, 438631);
    expect(items[0].tmdbIsTv, isFalse);
    expect(items[0].type, ProviderType.movie);
    expect(items[0].cover, 'https://image.tmdb.org/t/p/w500/p.jpg');
    expect(items[1].url, 'zm://tv/tmdb:1399');
    expect(items[1].tmdbIsTv, isTrue);
    expect(items[1].title, 'Game of Thrones');
  });

  test('search uses /search/multi and drops people', () async {
    String? path;
    final cat = TmdbCatalogue((p, q) async {
      path = p;
      return {'results': [_movie(), {'id': 9, 'name': 'Zendaya', 'media_type': 'person'}]};
    });
    final r = await cat.search('dune');
    expect(path, endsWith('/search/multi'));
    expect(r.length, 1);
  });

  test('movie detail is a single playable episode', () async {
    final cat = TmdbCatalogue((p, q) async => _movie());
    final d = await cat.detail(const ZCanonical(ZKind.movie, 'tmdb:438631'));
    expect(d.episodes.length, 1);
    expect(d.episodes.single.url, 'zm://movie/tmdb:438631/ep/1');
    expect(d.genres, ['Sci-Fi']);
    expect(d.year, '2021');
    expect(d.tmdbId, 438631);
  });

  test('tv detail flattens seasons into a numbered list, skipping specials',
      () async {
    final cat = TmdbCatalogue((p, q) async => _tv());
    final d = await cat.detail(const ZCanonical(ZKind.tv, 'tmdb:1399'));
    expect(d.episodes.length, 20);
    expect(d.episodes.first.season, 1);
    expect(d.episodes.first.number, 1);
    expect(d.episodes[10].season, 2);
    expect(d.episodes[10].number, 11);
    expect(d.episodes.last.url, 'zm://tv/tmdb:1399/ep/20');
    expect(d.tmdbIsTv, isTrue);
  });

  test('a null response yields an empty home', () async {
    final cat = TmdbCatalogue((p, q) async => null);
    expect(await cat.home(), isEmpty);
  });
}
