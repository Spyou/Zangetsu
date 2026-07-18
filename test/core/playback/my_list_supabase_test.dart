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

  test(
    'all() survives a row whose coverHeaders is Map<dynamic,dynamic> '
    '(the After-restart My List grey-screen crash)',
    () {
      // On a cold read from disk Hive returns nested maps as
      // Map<dynamic,dynamic>, which MediaItem.fromJson used to reject with a
      // cast error — crashing the whole My List body into a grey error box.
      // Reproduce that exact runtime type here.
      Hive.box<Map>(MyListStore.boxName).put('src::withHeaders', <String, dynamic>{
        'id': 'withHeaders',
        'title': 'Renegade Immortal',
        'cover': 'c.png',
        'coverHeaders': <dynamic, dynamic>{
          'Referer': 'https://anikototv.to/',
          'User-Agent': 'Mozilla/5.0',
        },
        'url': 'https://x/withHeaders',
        'type': 'anime',
        'sourceId': 'src',
      });

      late List<MediaItem> items;
      expect(() => items = store.all(), returnsNormally);
      final item = items.firstWhere((m) => m.id == 'withHeaders');
      expect(item.coverHeaders?['Referer'], 'https://anikototv.to/');
      expect(item.coverHeaders?['User-Agent'], 'Mozilla/5.0');
    },
  );

  // ── Watch-status cloud sync ───────────────────────────────────────────────

  test('status sync: the cloud row carries the local watch status', () async {
    final localStatus = <String, String?>{};
    final store2 = MyListStore(
      SupabaseService(),
      () => 'user1',
      remote: fake,
      statusOf: (m) => localStatus['${m.sourceId}::${m.id}'],
    );

    await store2.add(_item(id: 'a')); // no status yet
    expect(fake.rows.single['status'], isNull);

    localStatus['src::a'] = 'completed'; // user marks it Completed
    await store2.pushStatus(_item(id: 'a'));
    expect(fake.rows.single['status'], 'completed');
  });

  test('status sync: pullFromCloud hydrates the local status from the cloud',
      () async {
    final hydrated = <String, String?>{};
    final store2 = MyListStore(
      SupabaseService(),
      () => 'user1',
      remote: fake,
      onStatusPulled: (key, name) => hydrated[key] = name,
    );
    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'item_id': 'c',
      'title': 'T',
      'cover': null,
      'cover_headers': null,
      'url': 'https://x/c',
      'type': 'anime',
      'status': 'watching',
      'added_at': 0,
    });

    await store2.pullFromCloud();
    expect(hydrated['src::c'], 'watching');
  });

  test('status sync: pullFromCloud back-fills a local status the cloud lacks',
      () async {
    final localStatus = <String, String?>{'src::d': 'completed'};
    final store2 = MyListStore(
      SupabaseService(),
      () => 'user1',
      remote: fake,
      statusOf: (m) => localStatus['${m.sourceId}::${m.id}'],
    );
    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'item_id': 'd',
      'title': 'T',
      'cover': null,
      'cover_headers': null,
      'url': 'https://x/d',
      'type': 'anime',
      'status': null, // cloud has no status yet
      'added_at': 0,
    });

    await store2.pullFromCloud();
    await Future<void>.delayed(const Duration(milliseconds: 10)); // let backfill run
    final row = fake.rows.firstWhere((r) => r['item_id'] == 'd');
    expect(row['status'], 'completed');
  });
}
