// Line 2 of the reading-mode chapter row: how the meta line degrades when the
// source gives us little or nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/chapter_meta.dart';

Episode chapter({String? date, String? scanlator}) => Episode(
      id: 'c1',
      title: 'Chapter 1',
      url: '/c1',
      number: 1,
      date: date,
      scanlator: scanlator,
    );

void main() {
  final now = DateTime(2026, 8, 7, 12);
  String? at(Duration ago) => relativeDate(
        now.subtract(ago).toIso8601String(),
        now: now,
      );

  group('scanlator on the meta line', () {
    // Several groups release the same chapter number, so a list can honestly
    // read 1, 1, 2, 2 — the group name is what tells them apart.
    test('shows group and date together', () {
      expect(
        chapterMetaLine(
          chapter(scanlator: 'Asura Scans', date: now.toIso8601String()),
          now: now,
        ),
        'Asura Scans  ·  Today',
      );
    });

    test('group alone when the source gives no date', () {
      expect(
        chapterMetaLine(chapter(scanlator: 'Hades Scans'), now: now),
        'Hades Scans',
      );
    });

    test('date alone when there is no group — unchanged from before', () {
      expect(
        chapterMetaLine(chapter(date: now.toIso8601String()), now: now),
        'Today',
      );
    });

    test('an invisible group name counts as no group at all', () {
      // Found on a real Mihon source: scanlator was a single ZERO WIDTH SPACE,
      // which trim() leaves alone, so it rendered as an empty filter chip and
      // put a stray leading separator on every chapter row.
      expect(scanlatorLabel('\u200B'), isNull);
      expect(scanlatorLabel('\uFEFF'), isNull);
      expect(scanlatorLabel('\u200E'), isNull); // LTR mark
      expect(scanlatorLabel('  \u200B  '), isNull);
      expect(scanlatorLabel(''), isNull);
      expect(scanlatorLabel(null), isNull);
      // A real name survives, including one padded with invisibles.
      expect(scanlatorLabel('Asura Scans'), 'Asura Scans');
      expect(scanlatorLabel('\u200EAsura Scans '), 'Asura Scans');

      expect(
        chapterMetaLine(
          chapter(scanlator: scanlatorLabel('\u200B'), date: now.toIso8601String()),
          now: now,
        ),
        'Today',
        reason: 'no phantom leading separator',
      );
    });

    test('blank or whitespace group is not shown as an empty segment', () {
      // Episode.scanlator is normalised at ingest by [scanlatorLabel], so the
      // meta line trusts it — go through the same door a real chapter does
      // rather than hand-building a value the mappers can never produce.
      expect(
        chapterMetaLine(chapter(scanlator: scanlatorLabel('   ')), now: now),
        isNull,
      );
      expect(
        chapterMetaLine(
          chapter(scanlator: scanlatorLabel('  '), date: now.toIso8601String()),
          now: now,
        ),
        'Today',
      );
    });

    test('a chapter with neither loses the line entirely', () {
      expect(chapterMetaLine(chapter(), now: now), isNull);
    });
  });

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
