// "Recently added" used to trust the order the Hive box iterated in. That is
// not a record of when anything was added — a cloud restore repopulates the
// box in whatever order the rows arrive.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/prefs/list_sort.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';

MyListEntry _e(String title, {int? savedAtMs}) => MyListEntry(
  MediaItem(
    id: title,
    title: title,
    url: 'zm://anime/mal:$title',
    type: ProviderType.anime,
    sourceId: 'zm',
    savedAtMs: savedAtMs,
  ),
  null,
);

void main() {
  test('newest first uses the save date, not the order given', () {
    // Deliberately handed over in the wrong order, as a restore would.
    final src = [
      _e('middle', savedAtMs: 200),
      _e('oldest', savedAtMs: 100),
      _e('newest', savedAtMs: 300),
    ];

    final out = sortLibrary(src, ListSort.added, true);

    expect(out.map((e) => e.item.title), ['newest', 'middle', 'oldest']);
  });

  test('oldest first is the reverse', () {
    final src = [
      _e('newest', savedAtMs: 300),
      _e('oldest', savedAtMs: 100),
    ];

    final out = sortLibrary(src, ListSort.added, false);

    expect(out.map((e) => e.item.title), ['oldest', 'newest']);
  });

  test('undated entries stay at the old end', () {
    // Saved before the date existed: they must not jump to the top of
    // "recently added" just because they have no date.
    final src = [
      _e('dated', savedAtMs: 100),
      _e('legacy'),
    ];

    final newestFirst = sortLibrary(src, ListSort.added, true);

    expect(newestFirst.map((e) => e.item.title), ['dated', 'legacy']);
  });

  test('sorting does not disturb the caller list', () {
    final src = [_e('b', savedAtMs: 2), _e('a', savedAtMs: 1)];

    sortLibrary(src, ListSort.added, true);

    expect(src.map((e) => e.item.title), ['b', 'a']);
  });
}
