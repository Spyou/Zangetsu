import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/series_groups.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('series_group_store');
    Hive.init(dir.path);
    await Hive.openBox(SeriesGroupStore.boxName);
    await Hive.openBox(SeriesGroupStore.syncMetaBox);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('create + add + reorder + remove round-trips in order', () async {
    final store = SeriesGroupStore();
    final g = (await store.create('Fate'))!;
    await store.addMember(g.id, 'a::1');
    await store.addMember(g.id, 'a::2');
    await store.addMember(g.id, 'a::1'); // dup into same group: no-op
    await store.moveMember(g.id, 'a::2', 0);
    expect(store.groupOf('a::1')!.memberKeys, ['a::2', 'a::1']);
    await store.removeMember(g.id, 'a::2');
    expect(store.groupOf('a::1')!.memberKeys, ['a::1']);
  });

  test('adding a key already in another group moves it exclusively', () async {
    final store = SeriesGroupStore();
    final a = (await store.create('A'))!;
    final b = (await store.create('B'))!;
    await store.addMember(a.id, 'x::1');
    await store.addMember(b.id, 'x::1');
    expect(store.groupOf('x::1')!.id, b.id);
    final refreshedA = store.all().firstWhere((g) => g.id == a.id);
    expect(refreshedA.memberKeys, isEmpty);
  });

  test(
    'purgeTitle drops from its group and auto-deletes an emptied group',
    () async {
      final store = SeriesGroupStore();
      final g = (await store.create('A'))!;
      await store.addMember(g.id, 's::9');
      await store.purgeTitle('s::9');
      expect(store.all().any((x) => x.id == g.id), isFalse);
    },
  );

  test('purgeTitle leaves a multi-member group intact', () async {
    final store = SeriesGroupStore();
    final g = (await store.create('A'))!;
    await store.addMember(g.id, 's::1');
    await store.addMember(g.id, 's::2');
    await store.purgeTitle('s::1');
    final remaining = store.all().firstWhere((x) => x.id == g.id);
    expect(remaining.memberKeys, ['s::2']);
  });

  test(
    'a single-member group stays a group until explicitly deleted',
    () async {
      final store = SeriesGroupStore();
      final g = (await store.create('A'))!;
      await store.addMember(g.id, 's::1');
      expect(store.all().single.memberKeys, ['s::1']);
    },
  );

  test(
    'delete removes the group but leaves no title data behind to check',
    () async {
      final store = SeriesGroupStore();
      final g = (await store.create('A'))!;
      await store.addMember(g.id, 's::1');
      await store.delete(g.id);
      expect(store.all(), isEmpty);
    },
  );

  test('pull replaces groups, cloud wins', () async {
    final remote = _FakeSeriesGroupRemote();
    final store = SeriesGroupStore(
      remote: remote,
      currentUserId: () => 'user-1',
    );
    final g = (await store.create('A'))!;
    await store.addMember(g.id, 'a');
    remote.rows = [
      {
        'id': g.id,
        'title': 'A',
        'position': 0,
        'member_keys': ['b', 'a'],
        'cover_mode': 'auto',
        'cover_member_key': null,
      },
    ];
    final before = store.revision.value;
    await store.pullFromCloud();
    expect(store.groupOf('b')!.memberKeys, ['b', 'a']);
    expect(store.revision.value, before + 1);
  });

  test('pullFromCloudIfStale skips inside maxAge, runs once stale', () async {
    final remote = _FakeSeriesGroupRemote();
    final store = SeriesGroupStore(
      remote: remote,
      currentUserId: () => 'user-1',
    );
    remote.rows = [
      {
        'id': 'g1',
        'title': 'A',
        'position': 0,
        'member_keys': <String>[],
        'cover_mode': 'auto',
        'cover_member_key': null,
      },
    ];
    await store.pullFromCloudIfStale();
    expect(remote.listCalls, 1);
    await store.pullFromCloudIfStale();
    expect(remote.listCalls, 1);
    await store.pullFromCloudIfStale(maxAge: Duration.zero);
    expect(remote.listCalls, 2);
  });
}

class _FakeSeriesGroupRemote implements SeriesGroupRemote {
  List<Map<String, dynamic>> rows = [];
  int listCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> groupsFor(String uid) async {
    listCalls++;
    return rows;
  }

  @override
  Future<void> upsertGroup(Map<String, dynamic> row) async {}

  @override
  Future<void> deleteGroup(String uid, String id) async {}
}
