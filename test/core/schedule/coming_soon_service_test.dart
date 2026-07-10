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
}
