// A source with several scanlation groups lists every group's release in one
// flat list. Stepping to the neighbouring ROW therefore took a reader from
// group A's chapter 1 to group B's chapter 1 — the same chapter again — rather
// than on to chapter 2.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/reading/chapter_nav.dart';

Episode _c(double n, String? group) => Episode(
  id: '$n-$group',
  title: 'Chapter $n',
  number: n,
  url: 'https://s/$n/$group',
  scanlator: group,
);

void main() {
  // How a two-group source actually lists things: each chapter, once per group.
  final mixed = [
    _c(1, 'Alpha'),
    _c(1, 'Beta'),
    _c(2, 'Alpha'),
    _c(2, 'Beta'),
    _c(3, 'Alpha'),
    _c(3, 'Beta'),
  ];

  test('next stays with the group being read', () {
    // From Alpha ch1 (index 0) the neighbouring row is Beta ch1 — the bug.
    expect(adjacentChapterIndex(mixed, 0, step: 1), 2); // Alpha ch2
    expect(adjacentChapterIndex(mixed, 2, step: 1), 4); // Alpha ch3
  });

  test('so does previous', () {
    expect(adjacentChapterIndex(mixed, 4, step: -1), 2);
    expect(adjacentChapterIndex(mixed, 2, step: -1), 0);
  });

  test('the other group reads its own run, untouched', () {
    expect(adjacentChapterIndex(mixed, 1, step: 1), 3); // Beta ch2
    expect(adjacentChapterIndex(mixed, 3, step: -1), 1);
  });

  test('a group that stops hands over to the next NUMBER, not back to 1', () {
    // Alpha ends at 2; Beta carries on to 3.
    final short = [
      _c(1, 'Alpha'),
      _c(1, 'Beta'),
      _c(2, 'Alpha'),
      _c(3, 'Beta'),
    ];
    expect(adjacentChapterIndex(short, 2, step: 1), 3); // Beta ch3
  });

  test('at the true end there is no next', () {
    final single = [_c(1, 'Alpha'), _c(2, 'Alpha')];
    expect(adjacentChapterIndex(single, 1, step: 1), isNull);
    expect(adjacentChapterIndex(single, 0, step: -1), isNull);
  });

  test('a finished group does not slide onto a chapter it just read', () {
    // Alpha's last release is 2, and nobody has a 3. The row after it is Beta's
    // own 2 — the same chapter again, which is the bug. There is no next here.
    final ended = [_c(1, 'Alpha'), _c(2, 'Alpha'), _c(2, 'Beta')];
    expect(adjacentChapterIndex(ended, 1, step: 1), isNull);

    // And the same going backwards: Alpha starts at 1, so Beta's 1 is not a
    // previous chapter.
    final start = [_c(1, 'Beta'), _c(1, 'Alpha'), _c(2, 'Alpha')];
    expect(adjacentChapterIndex(start, 1, step: -1), isNull);
  });

  test('a single-group source behaves exactly as before', () {
    final plain = [_c(1, 'Alpha'), _c(2, 'Alpha'), _c(3, 'Alpha')];
    expect(adjacentChapterIndex(plain, 1, step: 1), 2);
    expect(adjacentChapterIndex(plain, 1, step: -1), 0);
  });

  test('no group at all is its own group, and still steps by number', () {
    final none = [_c(1, null), _c(2, null), _c(3, null)];
    expect(adjacentChapterIndex(none, 0, step: 1), 1);
  });

  test('an invisible-character group counts as no group, not a new one', () {
    // Sources leave zero-width junk in a "blank" field. scanlatorLabel folds it
    // away, and the grouping has to agree — otherwise the ungrouped run is torn
    // into singletons and the reader escapes into a named group's chapters.
    final junk = [
      _c(1, 'Alpha'),
      _c(1, '​'), // "blank", with junk in it
      _c(2, 'Alpha'),
      _c(2, null), // blank for real
      _c(3, 'Alpha'),
      _c(3, ''),
    ];
    // From the junk-blank chapter 1, the next ungrouped chapter is index 3.
    // Comparing the raw strings instead would skip it and hand back Alpha's 2.
    expect(adjacentChapterIndex(junk, 1, step: 1), 3);
    expect(adjacentChapterIndex(junk, 3, step: 1), 5);
  });

  test('unnumbered chapters fall back to the neighbouring row', () {
    final unnumbered = [
      const Episode(id: 'a', title: 'A', url: 'a'),
      const Episode(id: 'b', title: 'B', url: 'b'),
    ];
    expect(adjacentChapterIndex(unnumbered, 0, step: 1), 1);
  });

  test('the label is the chapter number, not the row', () {
    // Row 3 of a two-group list is chapter 2. Counting rows printed "ch 3".
    expect(chapterNumberLabel(mixed, 2), '2');
    expect(chapterNumberLabel(mixed, 5), '3');
    // And the total is the highest chapter, not the row count (6 rows here).
    expect(chapterCountLabel(mixed), '3');
  });

  test('a half chapter keeps its fraction', () {
    final half = [_c(10, 'Alpha'), _c(10.5, 'Alpha')];
    expect(chapterNumberLabel(half, 1), '10.5');
    expect(chapterCountLabel(half), '10.5');
  });

  test('an unnumbered source falls back to the row position', () {
    final unnumbered = [
      const Episode(id: 'a', title: 'A', url: 'a'),
      const Episode(id: 'b', title: 'B', url: 'b'),
    ];
    expect(chapterNumberLabel(unnumbered, 1), '2');
    expect(chapterCountLabel(unnumbered), '2');
    // Out of range says something sane instead of throwing mid-build.
    expect(chapterNumberLabel(unnumbered, 9), '10');
  });

  test('out of range and a zero step answer null rather than throwing', () {
    expect(adjacentChapterIndex(mixed, -1, step: 1), isNull);
    expect(adjacentChapterIndex(mixed, 99, step: 1), isNull);
    expect(adjacentChapterIndex(mixed, 0, step: 0), isNull);
  });
}
