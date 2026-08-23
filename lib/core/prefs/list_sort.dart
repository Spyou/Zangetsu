import 'package:hive/hive.dart';

import '../../features/home/cubit/my_list_cubit.dart';

/// How a library list is ordered.
///
/// Not every list offers every option — your own saved list has no scores and
/// no release years, so offering them there would give a menu entry that does
/// nothing. [optionsFor] is the source of truth for what a given list shows.
enum ListSort {
  /// Alphabetical.
  title,

  /// The order titles were saved in. Free: the local store already returns
  /// items in insertion order, so this is today's behaviour with a name.
  added,

  /// The user's score on a tracker. Tracker lists only.
  score,

  /// When the tracker last changed the entry. Tracker lists only — the own
  /// list keeps no such timestamp.
  updated,
}

/// Labels, worded for the field rather than a generic ascending/descending —
/// "Z → A" reads better than "descending" on a title.
String listSortLabel(ListSort s) => switch (s) {
      ListSort.title => 'Title',
      ListSort.added => 'Recently added',
      ListSort.score => 'Score',
      ListSort.updated => 'Last updated',
    };

String listSortDirectionLabel(ListSort s, bool desc) => switch (s) {
      ListSort.title => desc ? 'Z → A' : 'A → Z',
      ListSort.added => desc ? 'Newest first' : 'Oldest first',
      ListSort.score => desc ? 'High → Low' : 'Low → High',
      ListSort.updated => desc ? 'Recent first' : 'Oldest first',
    };

/// What a given list can honestly sort by.
List<ListSort> optionsFor({required bool isMyList}) => isMyList
    ? const [ListSort.added, ListSort.title]
    : const [ListSort.score, ListSort.updated, ListSort.title];

/// The default for a list that hasn't been sorted before: your own list keeps
/// the order you built it in, a tracker list leads with your best-rated.
ListSort defaultSortFor({required bool isMyList}) =>
    isMyList ? ListSort.added : ListSort.score;

/// Returns a NEW list in the requested order.
///
/// Never sorts in place and never writes anything: the saved list lives in
/// Hive and is only ever reordered for display. Nothing here can lose or
/// reorder what's stored.
List<MyListEntry> sortLibrary(
  List<MyListEntry> src,
  ListSort by,
  bool desc,
) {
  // Copy first — `src` belongs to the cubit, and sorting it in place would
  // quietly reorder the caller's state.
  final out = List<MyListEntry>.of(src);
  switch (by) {
    case ListSort.added:
      // Store order IS the order things were added, so ascending is simply
      // what came in; only the reverse needs doing.
      break;
    case ListSort.title:
      out.sort((a, b) =>
          a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()));
    case ListSort.updated:
      // Entries the tracker gave no date for sink to the bottom either way,
      // for the same reason an unscored title does: "unknown" isn't "ancient".
      final dated = out.where((e) => e.updatedAt != null).toList()
        ..sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
      final undated = out.where((e) => e.updatedAt == null).toList();
      return [...(desc ? dated : dated.reversed), ...undated];
    case ListSort.score:
      // Unscored titles sink to the bottom either way — a missing score is
      // "not rated", not "rated zero", so it shouldn't lead an ascending sort.
      out.sort((a, b) {
        final x = a.score, y = b.score;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x); // high → low before the reverse below
      });
      if (!desc) {
        return out.reversed.where((e) => e.score != null).toList()
          ..addAll(out.where((e) => e.score == null));
      }
      return out;
  }
  return desc ? out.reversed.toList() : out;
}

/// Remembers the chosen sort. One setting shared by every list — four hidden
/// states would be worse than one obvious one.
///
/// Uses the `ui_prefs` box that AnimationPrefs already opens at boot, so this
/// adds no new box to open (and can't fail on a box that isn't ready).
class ListSortPrefs {
  static const String boxName = 'ui_prefs';
  static const String _byKey = 'libSortBy';
  static const String _descKey = 'libSortDesc';

  static Box? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  static ListSort? get sortBy {
    final name = _box?.get(_byKey) as String?;
    if (name == null) return null;
    for (final s in ListSort.values) {
      if (s.name == name) return s;
    }
    return null; // unknown value (older/newer build) → fall back to the default
  }

  static bool get descending => (_box?.get(_descKey) as bool?) ?? true;

  static Future<void> save(ListSort by, bool desc) async {
    final b = _box;
    if (b == null) return; // box not open (tests) — the sort still works
    await b.put(_byKey, by.name);
    await b.put(_descKey, desc);
  }
}
