import '../models/episode.dart';

/// The chapter to move to from [from], one step in [step] (+1 next, -1 prev).
///
/// A source with several scanlation groups lists every group's release in one
/// flat list, so the neighbouring ROW is usually the same chapter again from
/// another group. Stepping by position therefore sent a reader from group A's
/// chapter 1 to group B's chapter 1 instead of onward to chapter 2.
///
/// So: stay with the group being read. When that group has nothing further,
/// move to the nearest chapter whose NUMBER is actually further on, whoever
/// released it — a group that stops at 10 should hand over to someone else's
/// 11, never back to their 1.
///
/// Returns null at the true end. Position is only used when the source gives
/// no chapter numbers at all, which is the one case where there is nothing
/// better to go on.
int? adjacentChapterIndex(
  List<Episode> chapters,
  int from, {
  required int step,
}) {
  if (from < 0 || from >= chapters.length || step == 0) return null;
  final current = chapters[from];
  final group = scanlatorLabel(current.scanlator);

  for (var i = from + step; i >= 0 && i < chapters.length; i += step) {
    if (scanlatorLabel(chapters[i].scanlator) == group) return i;
  }

  final n = current.number;
  if (n != null) {
    for (var i = from + step; i >= 0 && i < chapters.length; i += step) {
      final m = chapters[i].number;
      if (m == null) continue;
      if (step > 0 ? m > n : m < n) return i;
    }
    // Numbered, and nothing further in that direction — this really is the end.
    return null;
  }

  final i = from + step;
  return (i >= 0 && i < chapters.length) ? i : null;
}

/// What to call the chapter at [index] on screen.
///
/// Not the row position: a source with several scanlation groups lists every
/// chapter once per group, so row 3 of a two-group list is chapter 2, and
/// counting rows printed "ch 3". Use the number the source gave. The position
/// is only a fallback for a source that numbers nothing.
String chapterNumberLabel(List<Episode> chapters, int index) {
  if (index < 0 || index >= chapters.length) return '${index + 1}';
  final n = chapters[index].number;
  if (n == null) return '${index + 1}';
  return n == n.truncateToDouble() ? '${n.toInt()}' : '$n';
}

/// The total to print beside it. Same reason: a two-group list holds twice as
/// many rows as the show has chapters, so the row count reads as double.
String chapterCountLabel(List<Episode> chapters) {
  var highest = 0.0;
  var numbered = false;
  for (final c in chapters) {
    final n = c.number;
    if (n == null) continue;
    numbered = true;
    if (n > highest) highest = n;
  }
  if (!numbered) return '${chapters.length}';
  return highest == highest.truncateToDouble()
      ? '${highest.toInt()}'
      : '$highest';
}
