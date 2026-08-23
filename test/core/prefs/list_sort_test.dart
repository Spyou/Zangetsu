import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/prefs/list_sort.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';

MyListEntry e(String title, {double? score}) => MyListEntry(
      MediaItem(
        id: title,
        title: title,
        url: '/$title',
        type: ProviderType.anime,
        sourceId: 's',
      ),
      null,
      score: score,
    );

void main() {
  group('sorting never touches the stored list', () {
    test('returns a new list and leaves the original order alone', () {
      // The saved list lives in Hive and the cubit hands out its own list.
      // Sorting in place would quietly reorder that state — this is the check
      // that a sort can never lose or rearrange what someone saved.
      final original = [e('Zebra'), e('Apple'), e('Mango')];
      final before = original.map((x) => x.item.title).toList();

      final sorted = sortLibrary(original, ListSort.title, false);

      expect(sorted, isNot(same(original)));
      expect(original.map((x) => x.item.title).toList(), before);
      expect(sorted.map((x) => x.item.title).toList(),
          ['Apple', 'Mango', 'Zebra']);
    });

    test('every entry survives the sort — nothing dropped', () {
      final src = [e('B', score: 8), e('A'), e('C', score: 5)];
      for (final by in ListSort.values) {
        for (final desc in [true, false]) {
          expect(sortLibrary(src, by, desc).length, src.length,
              reason: '$by desc=$desc lost an entry');
        }
      }
    });
  });

  group('order', () {
    test('title sorts case-insensitively, both ways', () {
      final src = [e('banana'), e('Apple'), e('cherry')];
      expect(sortLibrary(src, ListSort.title, false).map((x) => x.item.title),
          ['Apple', 'banana', 'cherry']);
      expect(sortLibrary(src, ListSort.title, true).map((x) => x.item.title),
          ['cherry', 'banana', 'Apple']);
    });

    test('recently added is just the stored order, reversed for newest', () {
      final src = [e('first'), e('second'), e('third')];
      expect(sortLibrary(src, ListSort.added, false).map((x) => x.item.title),
          ['first', 'second', 'third']);
      expect(sortLibrary(src, ListSort.added, true).map((x) => x.item.title),
          ['third', 'second', 'first']);
    });

    test('unscored titles sink to the bottom in BOTH directions', () {
      // A missing score means "not rated", not "rated zero" — it shouldn't
      // lead a low-to-high sort.
      final src = [e('none'), e('high', score: 9), e('low', score: 3)];
      expect(sortLibrary(src, ListSort.score, true).map((x) => x.item.title),
          ['high', 'low', 'none']);
      expect(sortLibrary(src, ListSort.score, false).map((x) => x.item.title),
          ['low', 'high', 'none']);
    });
  });

  group('options offered per list', () {
    test('your own list is not offered score — it has none', () {
      expect(optionsFor(isMyList: true), isNot(contains(ListSort.score)));
      expect(optionsFor(isMyList: true), contains(ListSort.added));
    });

    test('a tracker list is offered score and defaults to it', () {
      expect(optionsFor(isMyList: false), contains(ListSort.score));
      expect(defaultSortFor(isMyList: false), ListSort.score);
      expect(defaultSortFor(isMyList: true), ListSort.added);
    });
  });
}
