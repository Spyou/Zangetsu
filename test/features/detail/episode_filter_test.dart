import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/episode_filter.dart';

Episode ep(String id, String title, double? number) =>
    Episode(id: id, title: title, number: number, url: 'u$id');

void main() {
  final eps = [
    ep('1', 'The Beginning', 1),
    ep('2', 'A New Threat', 2),
    ep('12', 'Twelfth Night', 12),
    ep('s1', 'OVA Special', 1.5),
    ep('u', 'Untitled', null),
  ];

  group('filterEpisodes', () {
    test('empty / whitespace query returns the list unchanged', () {
      expect(filterEpisodes(eps, ''), same(eps));
      expect(filterEpisodes(eps, '   '), same(eps));
    });

    test('matches title case-insensitively', () {
      final r = filterEpisodes(eps, 'threat');
      expect(r.map((e) => e.id), ['2']);
    });

    test('matches a whole number without the trailing .0', () {
      final r = filterEpisodes(eps, '12');
      expect(r.map((e) => e.id), ['12']); // "12" -> 12.0, not a title hit
    });

    test('matches a decimal number', () {
      final r = filterEpisodes(eps, '1.5');
      expect(r.map((e) => e.id), ['s1']);
    });

    test('title and number can both contribute matches', () {
      // "1" appears in numbers 1 and 12 (as "12"/"1"), and 1.5 -> "1.5".
      final r = filterEpisodes(eps, '1');
      expect(r.map((e) => e.id).toSet(), {'1', '12', 's1'});
    });

    test('no match returns empty', () {
      expect(filterEpisodes(eps, 'zzz'), isEmpty);
    });

    test('a numberless episode still matches on title', () {
      final r = filterEpisodes(eps, 'untitled');
      expect(r.map((e) => e.id), ['u']);
    });
  });
}
