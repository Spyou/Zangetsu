import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/prefs/list_sort.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';
import 'package:watch_app/features/home/library_filter.dart';

MyListEntry _e(
  String title, {
  WatchStatus? status,
  double? score,
  List<String> customLists = const [],
}) => MyListEntry(
  MediaItem(
    id: title,
    title: title,
    url: '/$title',
    type: ProviderType.anime,
    sourceId: 's',
  ),
  status,
  score: score,
  customLists: customLists,
);

void main() {
  final watching = _e('Watching show', status: WatchStatus.watching, score: 4);
  final completed = _e('Done show', status: WatchStatus.completed, score: 9);
  final planned = _e('Later show', status: WatchStatus.planning, score: 7);

  test(
    'presentLibraryStatuses keeps the phone tab order and drops empties',
    () {
      expect(presentLibraryStatuses([completed, watching]), [
        WatchStatus.watching,
        WatchStatus.completed,
      ]);
    },
  );

  test('filterLibraryEntries can isolate a status or custom list', () {
    final entries = [
      watching,
      completed,
      _e('Custom', status: WatchStatus.watching, customLists: const ['Gym']),
    ];
    expect(
      filterLibraryEntries(
        entries,
        status: WatchStatus.completed,
      ).map((e) => e.item.title),
      ['Done show'],
    );
    expect(
      filterLibraryEntries(entries, customList: 'Gym').map((e) => e.item.title),
      ['Custom'],
    );
  });

  test(
    'tracker default sort puts the highest score first, not fetch order',
    () {
      final shown = sortLibrary(
        [watching, planned, completed],
        defaultSortFor(isMyList: false),
        true,
      );
      expect(shown.map((e) => e.item.title), [
        'Done show',
        'Later show',
        'Watching show',
      ]);
    },
  );
}
