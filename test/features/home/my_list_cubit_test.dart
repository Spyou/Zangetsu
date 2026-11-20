import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/series_groups.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/features/home/cubit/my_list_cubit.dart';

MediaItem _item(String sourceId, String id, String title) => MediaItem(
  sourceId: sourceId,
  id: id,
  title: title,
  type: ProviderType.anime,
  url: '$sourceId::$id',
  cover: '',
  savedAtMs: 0,
);

/// Mirrors `_FakeMyListStore` in `my_list_screen_tv_test.dart` — only `all()`
/// and `revision` are read by `MyListCubit`.
class _FakeMyListStore implements MyListStore {
  _FakeMyListStore(this._items) : revision = ValueNotifier<int>(0);
  final List<MediaItem> _items;
  @override
  final ValueNotifier<int> revision;
  @override
  List<MediaItem> all() => List<MediaItem>.from(_items);
  @override
  bool contains(MediaItem m) => _items.any((i) => i.id == m.id);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeListStatusStore implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  WatchStatus? statusOf(MediaItem m) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Only `all()`, `groupOf()` and `revision` are read by `MyListCubit`.
class _FakeSeriesGroupStore implements SeriesGroupStore {
  _FakeSeriesGroupStore(this._groups) : revision = ValueNotifier<int>(0);
  List<SeriesGroup> _groups;
  @override
  final ValueNotifier<int> revision;
  @override
  List<SeriesGroup> all() => _groups;
  @override
  SeriesGroup? groupOf(String key) {
    for (final g in _groups) {
      if (g.memberKeys.contains(key)) return g;
    }
    return null;
  }

  void replace(List<SeriesGroup> groups) {
    _groups = groups;
    revision.value++;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('grouped entries collapse into one SeriesCardEntry', () async {
    final a = _item('s', '1', 'Show A');
    final b = _item('s', '2', 'Show A S2');
    final group = SeriesGroup(
      id: 'g1',
      title: 'Show A (merged)',
      position: 0,
      memberKeys: const ['s::1', 's::2'],
    );
    final cubit = MyListCubit(
      _FakeMyListStore([a, b]),
      _FakeListStatusStore(),
      _FakeSeriesGroupStore([group]),
    );
    addTearDown(cubit.close);

    expect(cubit.state.length, 1);
    final entry = cubit.state.single;
    expect(entry, isA<SeriesCardEntry>());
    expect((entry as SeriesCardEntry).memberItems.length, 2);
    expect(entry.group.id, 'g1');
    expect(entry.item.title, 'Show A (merged)');
  });

  test('an ungrouped entry passes through unchanged', () async {
    final a = _item('s', '1', 'Solo Show');
    final cubit = MyListCubit(
      _FakeMyListStore([a]),
      _FakeListStatusStore(),
      _FakeSeriesGroupStore(const []),
    );
    addTearDown(cubit.close);

    expect(cubit.state.length, 1);
    expect(cubit.state.single, isNot(isA<SeriesCardEntry>()));
  });

  test('a single-member group still renders as a SeriesCardEntry', () async {
    final a = _item('s', '1', 'Show A');
    final group = SeriesGroup(
      id: 'g1',
      title: 'Show A (merged)',
      position: 0,
      memberKeys: const ['s::1'],
    );
    final cubit = MyListCubit(
      _FakeMyListStore([a]),
      _FakeListStatusStore(),
      _FakeSeriesGroupStore([group]),
    );
    addTearDown(cubit.close);

    expect(cubit.state.single, isA<SeriesCardEntry>());
  });

  test('renaming a group re-emits with the new title', () async {
    final a = _item('s', '1', 'Show A');
    final series = _FakeSeriesGroupStore([
      SeriesGroup(
        id: 'g1',
        title: 'Old name',
        position: 0,
        memberKeys: const ['s::1'],
      ),
    ]);
    final cubit = MyListCubit(
      _FakeMyListStore([a]),
      _FakeListStatusStore(),
      series,
    );
    addTearDown(cubit.close);
    expect(cubit.state.single.item.title, 'Old name');

    series.replace([
      SeriesGroup(
        id: 'g1',
        title: 'New name',
        position: 0,
        memberKeys: const ['s::1'],
      ),
    ]);
    expect(cubit.state.single.item.title, 'New name');
  });

  test('changing a member re-emits even when the cover stays put', () async {
    final a = _item('s', '1', 'Show A');
    final b = _item('s', '2', 'Show A S2');
    final c = _item('s', '3', 'Show A S3');
    final series = _FakeSeriesGroupStore([
      SeriesGroup(
        id: 'g1',
        title: 'Show A',
        position: 0,
        memberKeys: const ['s::1', 's::2'],
        coverMode: SeriesCoverMode.entry,
        coverMemberKey: 's::1',
      ),
    ]);
    final cubit = MyListCubit(
      _FakeMyListStore([a, b, c]),
      _FakeListStatusStore(),
      series,
    );
    addTearDown(cubit.close);
    expect(cubit.state.length, 2);
    expect(
      (cubit.state.first as SeriesCardEntry).memberItems.last.title,
      'Show A S2',
    );

    series.replace([
      SeriesGroup(
        id: 'g1',
        title: 'Show A',
        position: 0,
        memberKeys: const ['s::1', 's::3'],
        coverMode: SeriesCoverMode.entry,
        coverMemberKey: 's::1',
      ),
    ]);
    expect(cubit.state.length, 2);
    expect(
      (cubit.state.first as SeriesCardEntry).memberItems.last.title,
      'Show A S3',
    );
  });
}
