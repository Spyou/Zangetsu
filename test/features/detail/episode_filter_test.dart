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

  group('episode range helpers', () {
    test('episodeRangeCount splits at 50', () {
      expect(episodeRangeCount(0), 0);
      expect(episodeRangeCount(1), 1);
      expect(episodeRangeCount(50), 1);
      expect(episodeRangeCount(51), 2);
      expect(episodeRangeCount(60), 2);
      expect(episodeRangeCount(100), 2);
      expect(episodeRangeCount(101), 3);
    });

    test('episodeRangeIndex maps local index to chunk', () {
      expect(episodeRangeIndex(-1), 0);
      expect(episodeRangeIndex(0), 0);
      expect(episodeRangeIndex(49), 0);
      expect(episodeRangeIndex(50), 1);
    });

    test('episodeRangeSlice returns inclusive start, exclusive end', () {
      expect(episodeRangeSlice(0, 60), (start: 0, end: 50));
      expect(episodeRangeSlice(1, 60), (start: 50, end: 60));
      expect(episodeRangeSlice(0, 50), (start: 0, end: 50));
    });

    test('episodeRangeLabel uses episode numbers with fallbacks', () {
      final numbered = [
        for (var i = 1; i <= 60; i++)
          ep('$i', 'Ep $i', i.toDouble()),
      ];
      expect(episodeRangeLabel(numbered, 0), '1–50');
      expect(episodeRangeLabel(numbered, 1), '51–60');

      final partial = [
        ep('a', 'First', 51),
        ep('b', 'Second', null),
      ];
      expect(episodeRangeLabel(partial, 0), '51–2');
    });
  });
}
