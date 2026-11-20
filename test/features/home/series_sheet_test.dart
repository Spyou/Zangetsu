import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/series_groups.dart';
import 'package:watch_app/features/home/series_sheet.dart';

class _MemorySeriesGroupStore implements SeriesGroupStore {
  @override
  final revision = ValueNotifier<int>(0);
  List<SeriesGroup> _groups = [];
  int _nextId = 1;

  @override
  List<SeriesGroup> all() => _groups;

  @override
  SeriesGroup? groupOf(String key) {
    for (final g in _groups) {
      if (g.memberKeys.contains(key)) return g;
    }
    return null;
  }

  @override
  Future<SeriesGroup?> create(String title) async {
    if (title.trim().isEmpty) return null;
    final g = SeriesGroup(
      id: 'g${_nextId++}',
      title: title.trim(),
      position: _groups.length,
    );
    _groups = [..._groups, g];
    revision.value++;
    return g;
  }

  @override
  Future<void> addMember(String groupId, String key) async {
    _groups = [
      for (final g in _groups)
        if (g.id == groupId && !g.memberKeys.contains(key))
          SeriesGroup(
            id: g.id,
            title: g.title,
            position: g.position,
            memberKeys: [...g.memberKeys, key],
            coverMode: g.coverMode,
            coverMemberKey: g.coverMemberKey,
          )
        else if (g.id != groupId && g.memberKeys.contains(key))
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
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> _pumpSheet(WidgetTester t, SeriesGroupStore store) => t.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SeriesSheet(titleKey: 's::1', store: store),
    ),
  ),
);

void main() {
  testWidgets('selecting a group assigns exclusively', (t) async {
    final store = _MemorySeriesGroupStore();
    final a = (await store.create('Group A'))!;
    final b = (await store.create('Group B'))!;
    await store.addMember(b.id, 's::1');

    await _pumpSheet(t, store);
    await t.tap(find.text('Group A'));
    await t.pumpAndSettle();

    expect(store.groupOf('s::1')!.id, a.id);
    expect(store.all().firstWhere((g) => g.id == b.id).memberKeys, isEmpty);
  });

  testWidgets('No series removes the title from its group', (t) async {
    final store = _MemorySeriesGroupStore();
    final g = (await store.create('Group A'))!;
    await store.addMember(g.id, 's::1');

    await _pumpSheet(t, store);
    await t.tap(find.text('No series'));
    await t.pumpAndSettle();

    expect(store.groupOf('s::1'), isNull);
  });

  testWidgets('a new series is created and assigned in one go', (t) async {
    final store = _MemorySeriesGroupStore();
    await _pumpSheet(t, store);
    await t.enterText(find.byType(TextField), 'Fate');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(store.all().single.title, 'Fate');
    expect(store.groupOf('s::1')!.id, store.all().single.id);
  });
}
