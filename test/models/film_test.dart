import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/film.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  Episode ep(String title, {double? number = 1}) =>
      Episode(id: '1', title: title, number: number, url: '/e');

  group('isFilm', () {
    test('zm movie url is a film (TMDB/Simkl films)', () {
      expect(
        isFilmContent(
          episodes: [ep('Whatever')],
          zmUrl: 'zm://movie/tmdb:1234',
          showTitle: 'A',
        ),
        isTrue,
      );
    });

    test('an anime catalogue movie follows its explicit movie format', () {
      expect(
        isFilmContent(
          episodes: [ep('Episode 1')],
          zmUrl: 'zm://anime/mal:1',
          format: 'MOVIE',
        ),
        isTrue,
      );
    });

    test(
      'a known series is not a movie because its first entry matches its title',
      () {
        expect(
          isFilmContent(
            episodes: [ep('Show')],
            showTitle: 'Show',
            format: 'TV',
          ),
          isFalse,
        );
        expect(
          isFilmContent(
            episodes: [ep('Show')],
            showTitle: 'Show',
            tmdbId: 9,
            tmdbIsTv: true,
          ),
          isFalse,
        );
      },
    );

    test('zm tv url is not a film', () {
      expect(
        isFilmContent(
          episodes: [ep('Whatever')],
          zmUrl: 'zm://tv/tmdb:1234',
          showTitle: 'A',
        ),
        isFalse,
      );
    });

    test('AniList format MOVIE is a film even with many entries', () {
      expect(
        isFilmContent(
          episodes: [ep('Part 1'), ep('Part 2')],
          format: 'Movie',
          showTitle: 'A',
        ),
        isTrue,
      );
    });

    test('TMDB id without tv is a film', () {
      expect(
        isFilmContent(
          episodes: [ep('X')],
          tmdbId: 42,
          tmdbIsTv: false,
          showTitle: 'A',
        ),
        isTrue,
      );
      expect(
        isFilmContent(
          episodes: [ep('E1'), ep('E2')],
          tmdbId: 42,
          tmdbIsTv: true,
          showTitle: 'A',
        ),
        isFalse,
      );
    });

    test('more than one entry and no metadata is not a film', () {
      expect(
        isFilmContent(episodes: [ep('E1'), ep('E2')], showTitle: 'A'),
        isFalse,
      );
    });

    test(
      'single entry titled like the show is a film (metadata-less source)',
      () {
        expect(isFilmContent(episodes: [ep('A')], showTitle: 'A'), isTrue);
        expect(
          isFilmContent(episodes: [ep('Full Movie')], showTitle: 'A'),
          isTrue,
        );
        // Case/whitespace insensitive.
        expect(isFilmContent(episodes: [ep(' a ')], showTitle: 'a'), isTrue);
      },
    );

    test(
      'single generic "Episode 1" entry is NOT a film (airing show, partial source)',
      () {
        expect(
          isFilmContent(episodes: [ep('Episode 1')], showTitle: 'A'),
          isFalse,
        );
        expect(isFilmContent(episodes: [ep('')], showTitle: 'A'), isFalse);
      },
    );

    test('movie special inside a series is not a film (many entries)', () {
      expect(
        isFilmContent(episodes: [ep('Movie'), ep('Episode 2')], showTitle: 'A'),
        isFalse,
      );
    });
  });

  group('MediaDetailFilm', () {
    test('reading titles never get movie presentation', () {
      for (final type in [ProviderType.manga, ProviderType.novel]) {
        final detail = MediaDetail(
          id: 'r',
          title: 'Movie',
          url: '/r',
          sourceId: 'test',
          type: type,
          format: 'MOVIE',
          episodes: const [Episode(id: '1', title: 'Movie', url: '/1')],
        );
        expect(detail.isFilm, isFalse);
      }
    });
    test('forwards the detail fields', () {
      const d = MediaDetail(
        id: 'zm://movie/tmdb:9',
        title: 'Film',
        url: 'zm://movie/tmdb:9',
        sourceId: 'zm',
        type: ProviderType.movie,
      );
      expect(d.isFilm, isTrue);
    });
  });
}
