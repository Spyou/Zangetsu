import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

/// In-memory fake for [MyListRemote] so the store's pending-queue and
/// pull-merge logic can be tested without a live Supabase project.
class FakeMyListRemote implements MyListRemote {
  final List<Map<String, dynamic>> rows = [];
  bool failNext = false;

  @override
  Future<void> upsert(Map<String, dynamic> row) async {
    if (failNext) {
      failNext = false;
      throw Exception('network down');
    }
    rows.removeWhere((r) =>
        r['user_key'] == row['user_key'] &&
        r['source_id'] == row['source_id'] &&
        r['item_id'] == row['item_id']);
    rows.add(row);
  }

  @override
  Future<void> deleteRow(String userKey, String sourceId, String itemId) async {
    rows.removeWhere((r) =>
        r['user_key'] == userKey &&
        r['source_id'] == sourceId &&
        r['item_id'] == itemId);
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    return rows.where((r) => r['user_key'] == userKey).toList();
  }
}

MediaItem _item({String sourceId = 'src', String id = 'id'}) => MediaItem(
      id: id,
      sourceId: sourceId,
      title: 'Title',
      cover: 'cover.png',
      url: 'https://x/$id',
      type: ProviderType.anime,
    );

void main() {
  late Directory tmpDir;
  late FakeMyListRemote fake;
  late MyListStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('my_list_test');
    Hive.init(tmpDir.path);
    await MyListStore.init();
    fake = FakeMyListRemote();
    store = MyListStore(SupabaseService(), () => 'user1', remote: fake);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('add() upserts a row with the right composite key + fields', () async {
    await store.add(_item());

    expect(fake.rows, hasLength(1));
    final row = fake.rows.single;
    expect(row['user_key'], 'user1');
    expect(row['source_id'], 'src');
    expect(row['item_id'], 'id');
    expect(row['title'], 'Title');
    expect(row['url'], 'https://x/id');
  });

  test('failed upsert enqueues pending key; retryPending() re-sends it', () async {
    fake.failNext = true;
    await store.add(_item());

    expect(fake.rows, isEmpty); // cloud write failed
    expect(store.pendingKeys(), contains('src::id'));

    await store.retryPending();

    expect(fake.rows, hasLength(1));
    expect(store.pendingKeys(), isNot(contains('src::id')));
  });

  test('pullFromCloud() replaces local with remote rows, preserving pending adds',
      () async {
    // A synced item already known to the cloud.
    await store.add(_item(id: 'synced'));

    // A local add whose upload failed — must survive the pull.
    fake.failNext = true;
    await store.add(_item(id: 'unsynced'));
    expect(store.pendingKeys(), contains('src::unsynced'));

    // A brand-new item that showed up on the cloud from another device.
    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'item_id': 'fromCloud',
      'title': 'Cloud Title',
      'cover': 'c.png',
      'cover_headers': null,
      'url': 'https://x/fromCloud',
      'type': 'anime',
      'added_at': 0,
    });

    await store.pullFromCloud();

    final all = store.all().map((m) => m.id).toSet();
    expect(all, containsAll(['synced', 'fromCloud', 'unsynced']));
    expect(store.pendingKeys(), contains('src::unsynced'));
  });
}
