import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/title_badges.dart';

void main() {
  group('certificationFrom', () {
    test('a series takes its US rating', () {
      final tmdb = {
        'content_ratings': {
          'results': [
            {'iso_3166_1': 'DE', 'rating': '16'},
            {'iso_3166_1': 'US', 'rating': 'TV-MA'},
          ],
        },
      };
      expect(certificationFrom(tmdb, isTv: true), 'TV-MA');
    });

    test('a movie takes the first filled US certification', () {
      final tmdb = {
        'release_dates': {
          'results': [
            {
              'iso_3166_1': 'US',
              'release_dates': [
                {'certification': ''},
                {'certification': 'PG-13'},
              ],
            },
          ],
        },
      };
      expect(certificationFrom(tmdb, isTv: false), 'PG-13');
    });

    test('without a US entry, the first country that has one', () {
      final tmdb = {
        'content_ratings': {
          'results': [
            {'iso_3166_1': 'JP', 'rating': ''},
            {'iso_3166_1': 'GB', 'rating': '15'},
          ],
        },
      };
      expect(certificationFrom(tmdb, isTv: true), '15');
    });

    test('nothing usable gives null', () {
      expect(certificationFrom({}, isTv: true), isNull);
      expect(
        certificationFrom({
          'release_dates': {'results': []},
        }, isTv: false),
        isNull,
      );
    });
  });

  group('imdbIdFrom', () {
    test('reads the id', () {
      expect(
        imdbIdFrom({
          'external_ids': {'imdb_id': 'tt9335498'},
        }),
        'tt9335498',
      );
    });

    test('ignores an empty or odd one', () {
      expect(
        imdbIdFrom({
          'external_ids': {'imdb_id': ''},
        }),
        isNull,
      );
      expect(
        imdbIdFrom({
          'external_ids': {'imdb_id': '123'},
        }),
        isNull,
      );
      expect(imdbIdFrom({}), isNull);
    });
  });

  group('tmdbFromFind', () {
    test('a movie match wins', () {
      final r = tmdbFromFind({
        'movie_results': [
          {'id': 1241982},
        ],
        'tv_results': [
          {'id': 5},
        ],
      });
      expect(r, (id: 1241982, isTv: false));
    });

    test('falls back to a series match', () {
      final r = tmdbFromFind({
        'movie_results': [],
        'tv_results': [
          {'id': 85937},
        ],
      });
      expect(r, (id: 85937, isTv: true));
    });

    test('no match gives null', () {
      expect(tmdbFromFind({'movie_results': [], 'tv_results': []}), isNull);
      expect(tmdbFromFind(null), isNull);
    });
  });

  group('imdbRatingFrom', () {
    test('keeps one decimal', () {
      expect(
        imdbRatingFrom({
          'meta': {'imdbRating': '8.5'},
        }),
        '8.5',
      );
      expect(
        imdbRatingFrom({
          'meta': {'imdbRating': '9'},
        }),
        '9.0',
      );
    });

    test('no rating, zero or nonsense gives null', () {
      expect(imdbRatingFrom(null), isNull);
      expect(imdbRatingFrom({'meta': {}}), isNull);
      expect(
        imdbRatingFrom({
          'meta': {'imdbRating': '0'},
        }),
        isNull,
      );
      expect(
        imdbRatingFrom({
          'meta': {'imdbRating': 'n/a'},
        }),
        isNull,
      );
    });
  });

  group('credits', () {
    test('namesFrom keeps distinct names, plain or in maps', () {
      expect(namesFrom(['A', 'B', 'A', ' ', null]), ['A', 'B']);
      expect(
        namesFrom([
          {'name': 'X'},
          {'name': 'Y'},
        ]),
        ['X', 'Y'],
      );
      expect(namesFrom(['1', '2', '3'], max: 2), ['1', '2']);
      expect(namesFrom('nope'), isEmpty);
    });

    test('cinemetaCredits reads director and writer', () {
      final c = cinemetaCredits({
        'meta': {
          'director': ['Daisuke Hiramatsu'],
          'writer': ['Koyoharu Gotouge', 'Hiroshi Seko'],
        },
      });
      expect(c.directors, ['Daisuke Hiramatsu']);
      expect(c.writers, ['Koyoharu Gotouge', 'Hiroshi Seko']);
      expect(cinemetaCredits(null).directors, isEmpty);
    });

    test('tmdbCrewCredits picks the director and the writing jobs', () {
      final c = tmdbCrewCredits({
        'credits': {
          'crew': [
            {'name': 'Ann', 'job': 'Director'},
            {'name': 'Bob', 'job': 'Screenplay'},
            {'name': 'Bob', 'job': 'Story'},
            {'name': 'Cy', 'job': 'Producer'},
          ],
        },
      });
      expect(c.directors, ['Ann']);
      expect(c.writers, ['Bob']);
    });

    test('tmdbCreators reads created_by', () {
      expect(
        tmdbCreators({
          'created_by': [
            {'name': 'Dee'},
          ],
        }),
        ['Dee'],
      );
    });

    test('anilistStaffCredits maps roles to director and writer', () {
      final c = anilistStaffCredits({
        'staff': {
          'edges': [
            {
              'role': 'Director',
              'node': {
                'name': {'full': 'Haruo'},
              },
            },
            {
              'role': 'Original Creator',
              'node': {
                'name': {'full': 'Koyoharu'},
              },
            },
            {
              'role': 'Key Animation',
              'node': {
                'name': {'full': 'Someone'},
              },
            },
          ],
        },
      });
      expect(c.directors, ['Haruo']);
      expect(c.writers, ['Koyoharu']);
    });
  });

  group('formatRuntime', () {
    test('hours and minutes', () {
      expect(formatRuntime(105), '1h 45m');
      expect(formatRuntime(120), '2h');
      expect(formatRuntime(48), '48m');
    });

    test('unknown gives null', () {
      expect(formatRuntime(null), isNull);
      expect(formatRuntime(0), isNull);
    });
  });

  test('TitleBadges knows when it is empty', () {
    expect(const TitleBadges().isEmpty, isTrue);
    expect(const TitleBadges(directors: ['A']).isEmpty, isFalse);
    expect(
      const TitleBadges(writers: ['A']),
      const TitleBadges(writers: ['A']),
    );
    expect(const TitleBadges(ageRating: 'PG').isEmpty, isFalse);
    expect(
      const TitleBadges(imdbRating: '7.0'),
      const TitleBadges(imdbRating: '7.0'),
    );
  });
}
