import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/series_groups.dart';
import 'package:watch_app/features/home/series_screen.dart';

class _MemorySeriesGroupStore implements SeriesGroupStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  List<SeriesGroup> _groups = [];

  @override
  List<SeriesGroup> all() => _groups;

  @override
  SeriesGroup? groupOf(String key) {
    for (final g in _groups) {
      if (g.memberKeys.contains(key)) return g;
    }
    return null;
  }

  void seed(SeriesGroup group) {
    _groups = [group];
  }

  @override
  Future<bool> rename(String id, String title) async {
    _groups = [
      for (final g in _groups)
        if (g.id == id)
          SeriesGroup(
            id: g.id,
            title: title.trim(),
            position: g.position,
            memberKeys: g.memberKeys,
            coverMode: g.coverMode,
            coverMemberKey: g.coverMemberKey,
          )
        else
          g,
    ];
    revision.value++;
    return true;
  }

  @override
  Future<void> delete(String id) async {
    _groups = _groups.where((g) => g.id != id).toList();
    revision.value++;
  }

  @override
  Future<void> removeMember(String groupId, String key) async {
    _groups = [
      for (final g in _groups)
        if (g.id == groupId)
          SeriesGroup(
            id: g.id,
            title: g.title,
            position: g.position,
            memberKeys: g.memberKeys.where((k) => k != key).toList(),
            coverMode: g.coverMode,
            coverMemberKey: g.coverMemberKey == key ? null : g.coverMemberKey,
          )
        else
          g,
    ];
    revision.value++;
  }

  @override
  Future<void> moveMember(String groupId, String key, int toIndex) async {
    final g = _groups.single;
    final members = g.memberKeys.where((k) => k != key).toList();
    members.insert(toIndex.clamp(0, members.length), key);
    _groups = [
      SeriesGroup(
        id: g.id,
        title: g.title,
        position: g.position,
        memberKeys: members,
        coverMode: g.coverMode,
        coverMemberKey: g.coverMemberKey,
      ),
    ];
    revision.value++;
  }

  @override
  Future<void> setCoverAuto(String groupId) async {
    _groups = [
      for (final g in _groups)
        if (g.id == groupId)
          SeriesGroup(
            id: g.id,
            title: g.title,
            position: g.position,
            memberKeys: g.memberKeys,
            coverMode: SeriesCoverMode.auto,
          )
        else
          g,
    ];
    revision.value++;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _group = SeriesGroup(
  id: 'g1',
  title: 'Merged',
  position: 0,
  memberKeys: ['s::1', 's::2'],
);

final _members = [
  const MediaItem(
    id: '1',
    title: 'Season 1',
    url: 's::1',
    type: ProviderType.anime,
    sourceId: 's',
  ),
  const MediaItem(
    id: '2',
    title: 'Season 2',
    url: 's::2',
    type: ProviderType.anime,
    sourceId: 's',
  ),
];

Future<void> _pump(WidgetTester t, _MemorySeriesGroupStore store) async {
  store.seed(_group);
  await sl.reset();
  addTearDown(() => sl.reset());
  sl.registerSingleton<SeriesGroupStore>(store);
  await t.pumpWidget(
    MaterialApp(
      home: SeriesScreen(group: _group, members: _members),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('members render by title', (t) async {
    await _pump(t, _MemorySeriesGroupStore());
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
  });

  testWidgets('removing a member updates the list', (t) async {
    final store = _MemorySeriesGroupStore();
    await _pump(t, store);

    await t.tap(find.byIcon(Icons.close_rounded).first);
    await t.pumpAndSettle();
    expect(store.all().single.memberKeys, ['s::2']);
    expect(find.text('Season 1'), findsNothing);
  });

  testWidgets('rename changes the title', (t) async {
    final store = _MemorySeriesGroupStore();
    await _pump(t, store);

    await t.tap(find.byIcon(Icons.edit_rounded));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Renamed');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(store.all().single.title, 'Renamed');
  });

  testWidgets('delete removes only the grouping after confirmation', (t) async {
    final store = _MemorySeriesGroupStore();
    await _pump(t, store);

    await t.tap(find.byIcon(Icons.delete_outline_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();

    expect(store.all(), isEmpty);
    expect(_members, hasLength(2));
  });
}
