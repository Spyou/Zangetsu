import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

Map<String, dynamic> _movie({
  int id = 438631,
  String title = 'Dune',
  String? backdrop = '/b.jpg',
}) => {
  'id': id, 'title': title, 'poster_path': '/p.jpg', 'backdrop_path': backdrop,
  'release_date': '2021-10-22', 'overview': 'sand', 'media_type': 'movie',
  'genres': [{'name': 'Sci-Fi'}], 'status': 'Released',
};
Map<String, dynamic> _tv({int id = 1399, String name = 'Game of Thrones'}) => {
  'id': id, 'name': name, 'poster_path': '/t.jpg', 'backdrop_path': '/tb.jpg',
  'first_air_date': '2011-04-17',
  'overview': 'winter', 'media_type': 'tv', 'genres': [{'name': 'Drama'}],
  'status': 'Ended', 'seasons': [
    {'season_number': 0, 'episode_count': 5},
    {'season_number': 1, 'episode_count': 10},
    {'season_number': 2, 'episode_count': 10},
  ],
};

/// The row paths [TmdbCatalogue.home] fires, in the order it fires them —
/// mirrors its private `_rows` so a test can assert the returned order
/// without depending on internals.
const _rowPaths = [
  '/movie/now_playing',
  '/tv/on_the_air',
  '/trending/all/week',
  '/movie/popular',
  '/tv/popular',
  '/movie/top_rated',
  '/movie/upcoming',
];

void main() {
  test('home rows mix movies and tv, both typed as movie sources, banner carried', () async {
    final cat = TmdbCatalogue((p, q) async => {'results': [_movie(), _tv()]});
    final rows = await cat.home();
    expect(rows.length, 7);
    // Only mixed endpoints (/trending/all, /search/multi) keep the items'
    // own media_type; /movie/* and /tv/* rows say what they hold. This mock
    // feeds every path a movie and a tv entry, so the mixed-typing
    // assertions aim at the Trending row — rows.first is Now playing.
    final trending = rows
        .firstWhere((r) => r.title == 'Trending')
        .items;
    expect(trending[0].url, 'zm://movie/tmdb:438631');
    expect(trending[0].tmdbId, 438631);
    expect(trending[0].tmdbIsTv, isFalse);
    expect(trending[0].type, ProviderType.movie);
    expect(trending[0].cover, 'https://image.tmdb.org/t/p/w500/p.jpg');
    expect(trending[0].banner, 'https://image.tmdb.org/t/p/w780/b.jpg');
    expect(trending[1].url, 'zm://tv/tmdb:1399');
    expect(trending[1].tmdbIsTv, isTrue);
    expect(trending[1].title, 'Game of Thrones');
    // …while the /movie/now_playing row forces movie typing on everything,
    // even the tv entry the unrealistic mock hands it.
    expect(rows.first.title, 'Now playing');
    expect(rows.first.items[1].tmdbIsTv, isFalse);
  });

  test('home fires every row request concurrently, not one at a time', () async {
    final calledPaths = <String>[];
    final completers = <String, Completer<Map<String, dynamic>?>>{};
    final cat = TmdbCatalogue((p, q) async {
      calledPaths.add(p);
      final c = Completer<Map<String, dynamic>?>();
      completers[p] = c;
      return c.future;
    });

    final future = cat.home();
    // All seven requests fired before any of them resolved — a serialized
    // (for-loop + await) implementation would have only issued the first.
    expect(calledPaths.toSet(), _rowPaths.toSet());

    for (final path in calledPaths) {
      completers[path]!.complete({'results': [_movie(id: path.hashCode)]});
    }
    final rows = await future;

    // Future.wait preserves input order regardless of completion order.
    expect(rows.map((r) => r.title).toList(), [
      'Now playing', 'Airing now', 'Trending', 'Popular movies',
      'Popular series', 'Top rated', 'Upcoming',
    ]);
  });

  test('a malformed/missing response for one row still yields the rows that are fine',
      () async {
    final cat = TmdbCatalogue((p, q) async {
      if (p == '/movie/popular') return {'results': 'not-a-list'}; // malformed
      if (p == '/tv/popular') return null; // missing entirely
      return {'results': [_movie()]};
    });
    final rows = await cat.home();
    final titles = rows.map((r) => r.title).toSet();
    expect(titles.contains('Popular movies'), isFalse);
    expect(titles.contains('Popular series'), isFalse);
    expect(titles.contains('Trending'), isTrue);
    expect(titles.contains('Top rated'), isTrue);
    expect(titles.contains('Now playing'), isTrue);
    expect(titles.contains('Upcoming'), isTrue);
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
    expect(d.banner, 'https://image.tmdb.org/t/p/w780/b.jpg');
  });

  test('detail banner is null when TMDB has no backdrop', () async {
    final cat = TmdbCatalogue((p, q) async => _movie(backdrop: null));
    final d = await cat.detail(const ZCanonical(ZKind.movie, 'tmdb:438631'));
    expect(d.banner, isNull);
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
