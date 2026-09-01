import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';

void main() {
  test('parseTmdbResults maps movie rows + drops invalid', () {
    final rows = [
      {'id': 1, 'title': 'Movie A', 'poster_path': '/a.jpg', 'release_date': '2026-08-01'},
      {'id': 2, 'title': '', 'poster_path': '/b.jpg', 'release_date': '2026-08-02'}, // no title -> drop
      {'id': 3, 'title': 'No Poster No Date'}, // neither -> drop
      {'id': 4, 'title': 'Date Only', 'release_date': '2026-08-03'}, // kept (has date)
    ];
    final out = parseTmdbResults(rows, isTv: false);
    expect(out.map((e) => e.tmdbId).toList(), [1, 4]);
    expect(out.first.isTv, isFalse);
    expect(out.first.title, 'Movie A');
    expect(out.first.posterUrl, contains('/w342/a.jpg'));
    expect(out.first.releaseDate, DateTime(2026, 8, 1));
    expect(out.last.posterUrl, isNull);
  });

  test('parseTmdbResults reads tv fields (name, first_air_date)', () {
    final rows = [
      {'id': 9, 'name': 'Show B', 'poster_path': '/s.jpg', 'first_air_date': '2026-09-09'},
    ];
    final out = parseTmdbResults(rows, isTv: true);
    expect(out.single.isTv, isTrue);
    expect(out.single.title, 'Show B');
    expect(out.single.releaseDate, DateTime(2026, 9, 9));
  });

  test('mergeSortByDate sorts ascending, nulls last', () {
    ComingSoonEntry e(int id, DateTime? d) =>
        ComingSoonEntry(tmdbId: id, isTv: false, title: 't', posterUrl: null, releaseDate: d);
    final out = mergeSortByDate(
      [e(1, DateTime(2026, 8, 5)), e(2, null)],
      [e(3, DateTime(2026, 8, 1))],
    );
    expect(out.map((x) => x.tmdbId).toList(), [3, 1, 2]);
  });

  test('onlyUpcoming drops past dates, keeps today/future + null', () {
    ComingSoonEntry e(int id, DateTime? d) =>
        ComingSoonEntry(tmdbId: id, isTv: false, title: 't', posterUrl: null, releaseDate: d);
    final now = DateTime(2026, 7, 11, 14);
    final out = onlyUpcoming([
      e(1, DateTime(1996, 7, 22)), // old on_the_air premiere -> dropped
      e(2, DateTime(2026, 7, 11)), // today -> kept
      e(3, DateTime(2026, 12, 18)), // future -> kept
      e(4, null), // TBA -> kept
    ], now);
    expect(out.map((x) => x.tmdbId).toList(), [2, 3, 4]);
  });

  group('parseSimklCalendar', () {
    // Shapes copied from the live feeds (data.simkl.in/calendar/*.json).
    Map<String, dynamic> tvRow({
      dynamic tmdb = '1399',
      String title = 'Reacher',
      String date = '2026-09-04T00:00:00-04:00',
      Map<String, dynamic>? episode = const {'season': 2, 'episode': 7},
      String? poster = '20/203711197fe23acd56',
    }) => {
          'title': title,
          'poster': poster,
          'date': date,
          'ids': {'simkl_id': 2732099, 'tmdb': tmdb, 'imdb': 'tt0000'},
          if (episode != null) 'episode': episode,
        };

    test('maps a TV airing, with its episode label', () {
      final out = parseSimklCalendar([tvRow()], isTv: true);
      expect(out, hasLength(1));
      expect(out.single.tmdbId, 1399);
      expect(out.single.isTv, isTrue);
      expect(out.single.episodeLabel, 'S2E7');
      expect(out.single.posterUrl,
          'https://simkl.in/posters/20/203711197fe23acd56_m.jpg');
    });

    test('drops rows with no TMDB id, which Detail could not open', () {
      // Detail is keyed zm://movie/tmdb:<n>; ~7% of the TV feed has no tmdb id
      // and would otherwise render as a row that opens nothing.
      expect(parseSimklCalendar([tvRow(tmdb: null)], isTv: true), isEmpty);
      expect(parseSimklCalendar([tvRow(tmdb: '')], isTv: true), isEmpty);
    });

    test('drops rows with no usable date, since the grid is by day', () {
      expect(parseSimklCalendar([tvRow(date: '')], isTv: true), isEmpty);
      expect(parseSimklCalendar([tvRow(date: 'not a date')], isTv: true), isEmpty);
    });

    test('keeps the same series on different days, drops exact repeats', () {
      final out = parseSimklCalendar([
        tvRow(date: '2026-09-04T00:00:00-04:00', episode: {'season': 2, 'episode': 7}),
        tvRow(date: '2026-09-11T00:00:00-04:00', episode: {'season': 2, 'episode': 8}),
        tvRow(date: '2026-09-04T00:00:00-04:00', episode: {'season': 2, 'episode': 7}),
      ], isTv: true);
      expect(out, hasLength(2), reason: 'a weekly airing is not a duplicate');
      expect(out.map((e) => e.episodeLabel), ['S2E7', 'S2E8']);
    });

    test('a movie row has no episode label and survives a null poster', () {
      final out = parseSimklCalendar([
        {
          'title': 'Megumi',
          'poster': null,
          'date': '2026-08-31T00:00:00-04:00',
          'ids': {'tmdb': '1727742'},
        }
      ], isTv: false);
      expect(out.single.episodeLabel, isNull);
      expect(out.single.isTv, isFalse);
      expect(out.single.posterUrl, isNull);
    });

    test('an int tmdb id parses as well as a string one', () {
      expect(parseSimklCalendar([tvRow(tmdb: 1399)], isTv: true).single.tmdbId,
          1399);
    });

    test('rank 0 reads as no rank, since the feed uses 0 for "unranked"', () {
      final row = tvRow()..['rank'] = 0;
      expect(parseSimklCalendar([row], isTv: true).single.rank, isNull);
      final ranked = tvRow()..['rank'] = 14;
      expect(parseSimklCalendar([ranked], isTv: true).single.rank, 14);
    });
  });

  group('groupSoonByLocalDay ordering', () {
    ComingSoonEntry e(String title, {int? rank}) => ComingSoonEntry(
          tmdbId: title.hashCode,
          isTv: true,
          title: title,
          posterUrl: null,
          releaseDate: DateTime(2026, 9, 1, 12),
          rank: rank,
        );

    test('most popular first, unranked last, alphabetical within a tie', () {
      // A day of this calendar is ~330 rows; alphabetical put daily serials
      // on top and buried anything worth seeing.
      final day = groupSoonByLocalDay([
        e('Zed Show', rank: 14),      // popular despite the name
        e('A Daily Serial'),          // unranked
        e('Beta Show', rank: 900),
        e('Alpha Show', rank: 900),   // ties with Beta -> alphabetical
        e('B Daily Serial'),          // unranked -> after every ranked row
      ]).values.single;

      expect(day.map((x) => x.title), [
        'Zed Show',
        'Alpha Show',
        'Beta Show',
        'A Daily Serial',
        'B Daily Serial',
      ]);
    });

    test('with no ranks at all it stays alphabetical, as movies will be', () {
      final day = groupSoonByLocalDay([e('Charlie'), e('Alpha'), e('Bravo')])
          .values
          .single;
      expect(day.map((x) => x.title), ['Alpha', 'Bravo', 'Charlie']);
    });
  });
}
