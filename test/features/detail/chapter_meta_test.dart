// Line 2 of the reading-mode chapter row: how the meta line degrades when the
// source gives us little or nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/chapter_meta.dart';

Episode chapter({String? date}) =>
    Episode(id: 'c1', title: 'Chapter 1', url: '/c1', number: 1, date: date);

void main() {
  final now = DateTime(2026, 8, 7, 12);
  String? at(Duration ago) => relativeDate(
        now.subtract(ago).toIso8601String(),
        now: now,
      );

  group('relativeDate', () {
    test('null / empty / whitespace gives nothing to show', () {
      expect(relativeDate(null, now: now), isNull);
      expect(relativeDate('', now: now), isNull);
      expect(relativeDate('   ', now: now), isNull);
    });

    test('an unparseable date is passed through verbatim (trimmed)', () {
      expect(relativeDate('  Fall 2019  ', now: now), 'Fall 2019');
    });

    test('buckets by whole days', () {
      expect(at(const Duration(hours: 3)), 'Today');
      expect(at(const Duration(days: 1)), 'Yesterday');
      expect(at(const Duration(days: 2)), '2 days ago');
      expect(at(const Duration(days: 6)), '6 days ago');
      expect(at(const Duration(days: 7)), '1 week ago');
      expect(at(const Duration(days: 20)), '2 weeks ago');
      expect(at(const Duration(days: 31)), '1 month ago');
      expect(at(const Duration(days: 200)), '6 months ago');
      expect(at(const Duration(days: 800)), '2 years ago');
    });

    test('a future date reads as Today rather than a negative age', () {
      expect(at(const Duration(days: -5)), 'Today');
    });
  });

  group('chapterMetaLine', () {
    test('is the date when the chapter has one', () {
      final ep = chapter(
        date: now.subtract(const Duration(days: 2)).toIso8601String(),
      );
      expect(chapterMetaLine(ep, now: now), '2 days ago');
    });

    test('is null when the chapter has no date, so the row drops the line', () {
      expect(chapterMetaLine(chapter(), now: now), isNull);
      expect(chapterMetaLine(chapter(date: ''), now: now), isNull);
    });
  });
}
