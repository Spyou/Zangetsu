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
  final List<Map<String, dynamic>> tombstones = [];
  final Map<String, int> versions = {};
  int listForCalls = 0;
  int changesForCalls = 0;
  int _nextSyncId = 1;
  bool failNext = false;
  bool failNextDelete = false;
  bool failNextChanges = false;
  bool failNextList = false;
  Future<void> Function()? afterListSnapshot;

  String _scope(String userKey, String? profileId) =>
      '$userKey|${profileId ?? ''}';

  int _nextVersion(String userKey, String? profileId) {
    final key = _scope(userKey, profileId);
    return versions[key] = (versions[key] ?? 0) + 1;
  }

  @override
  Future<void> upsert(Map<String, dynamic> row) async {
    if (failNext) {
      failNext = false;
      throw Exception('network down');
    }
    final previous = rows.where(
      (r) =>
          r['user_key'] == row['user_key'] &&
          r['profile_id'] == row['profile_id'] &&
          r['source_id'] == row['source_id'] &&
          r['item_id'] == row['item_id'],
    );
    final existing = previous.isEmpty ? null : previous.first;
    rows.removeWhere(identicalOrSameRow(row));
    final userKey = '${row['user_key']}';
    final profileId = row['profile_id'] as String?;
    final sourceId = '${row['source_id']}';
    final itemId = '${row['item_id']}';
    final version = _nextVersion(userKey, profileId);
    rows.add({
      ...row,
      'sync_id': existing?['sync_id'] ?? _nextSyncId++,
      'sync_version': version,
    });
    tombstones.removeWhere(
      (r) =>
          r['user_key'] == userKey &&
          r['profile_scope'] == (profileId ?? '') &&
          r['source_id'] == sourceId &&
          r['item_id'] == itemId,
    );
  }

  bool Function(Map<String, dynamic>) identicalOrSameRow(
    Map<String, dynamic> row,
  ) =>
      (r) =>
          r['user_key'] == row['user_key'] &&
          r['profile_id'] == row['profile_id'] &&
          r['source_id'] == row['source_id'] &&
          r['item_id'] == row['item_id'];

  @override
  Future<void> deleteRow(
    String userKey,
    String sourceId,
    String itemId, {
    String? profileId,
  }) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw Exception('network down');
    }
    final matched = rows
        .where(
          (r) =>
              r['user_key'] == userKey &&
              r['profile_id'] == profileId &&
              r['source_id'] == sourceId &&
              r['item_id'] == itemId,
        )
        .toList();
    if (matched.isEmpty) return;
    rows.removeWhere(
      (r) =>
          r['user_key'] == userKey &&
          r['profile_id'] == profileId &&
          r['source_id'] == sourceId &&
          r['item_id'] == itemId,
    );
    tombstones.removeWhere(
      (r) =>
          r['user_key'] == userKey &&
          r['profile_scope'] == (profileId ?? '') &&
          r['source_id'] == sourceId &&
          r['item_id'] == itemId,
    );
    tombstones.add({
      'user_key': userKey,
      'profile_scope': profileId ?? '',
      'source_id': sourceId,
      'item_id': itemId,
      'sync_version': _nextVersion(userKey, profileId),
    });
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(
    String userKey, {
    String? profileId,
  }) async {
    listForCalls++;
    if (failNextList) {
      failNextList = false;
      throw Exception('network down');
    }
    final snapshot = rows
        .where((r) => r['user_key'] == userKey && r['profile_id'] == profileId)
        .toList();
    final callback = afterListSnapshot;
    afterListSnapshot = null;
    await callback?.call();
    return snapshot;
  }

  @override
  Future<int> currentVersion(String userKey, {String? profileId}) async =>
      versions[_scope(userKey, profileId)] ?? 0;

  @override
  Future<List<Map<String, dynamic>>> changesFor(
    String userKey, {
    String? profileId,
    required int afterVersion,
    required int throughVersion,
  }) async {
    changesForCalls++;
    if (failNextChanges) {
      failNextChanges = false;
      throw Exception('network down');
    }
    return [
      for (final row in rows)
        if (row['user_key'] == userKey &&
            row['profile_id'] == profileId &&
            (row['sync_version'] as int? ?? 0) > afterVersion &&
            (row['sync_version'] as int? ?? 0) <= throughVersion)
          {'sync_version': row['sync_version'], 'deleted': false, 'row': row},
      for (final row in tombstones)
        if (row['user_key'] == userKey &&
            row['profile_scope'] == (profileId ?? '') &&
            (row['sync_version'] as int) > afterVersion &&
            (row['sync_version'] as int) <= throughVersion)
          {...row, 'deleted': true},
    ]..sort(
      (a, b) => (a['sync_version'] as int).compareTo(b['sync_version'] as int),
    );
  }

  @override
  Future<Set<String>> deletedKeysFor(
    String userKey, {
    String? profileId,
  }) async => {
    for (final row in tombstones)
      if (row['user_key'] == userKey &&
          row['profile_scope'] == (profileId ?? ''))
        '${row['source_id']}::${row['item_id']}',
  };
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

  test(
    'profile scoped lists stay separate while the default keeps legacy keys',
    () async {
      var activeProfileId = 'default';
      final scoped = MyListStore(
        SupabaseService(),
        () => 'user1',
        remote: fake,
        currentProfileId: () => activeProfileId,
      );

      await scoped.add(_item(id: 'shared'));
      activeProfileId = 'kid';
      await scoped.add(_item(id: 'shared'));

      expect(scoped.all(), hasLength(1));
      expect(fake.rows.map((r) => r['profile_id']), [null, 'kid']);

      activeProfileId = 'default';
      expect(scoped.all(), hasLength(1));
      expect(scoped.contains(_item(id: 'shared')), isTrue);
      expect(
        Hive.box<Map>(MyListStore.boxName).containsKey('src::shared'),
        isTrue,
      );
    },
  );

  test(
    'failed upsert enqueues pending key; retryPending() re-sends it',
    () async {
      fake.failNext = true;
      await store.add(_item());

      expect(fake.rows, isEmpty); // cloud write failed
      expect(store.pendingKeys(), contains('src::id'));

      await store.retryPending();

      expect(fake.rows, hasLength(1));
      expect(store.pendingKeys(), isNot(contains('src::id')));
    },
  );

  test(
    'pullFromCloud() replaces local with remote rows, preserving pending adds',
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
    },
  );

  test(
    'a second pull does not download the unchanged full list again',
    () async {
      await store.add(_item(id: 'cached'));
      await store.pullFromCloud();
      final fullListReads = fake.listForCalls;
      final deltaReads = fake.changesForCalls;

      await store.pullFromCloud();

      expect(fake.listForCalls, fullListReads);
      expect(fake.changesForCalls, deltaReads);
      expect(store.all().map((item) => item.id), contains('cached'));
    },
  );

  test(
    'incremental pull applies a remote add without reading the full list',
    () async {
      await store.add(_item(id: 'cached'));
      await store.pullFromCloud();
      final fullListReads = fake.listForCalls;

      await fake.upsert({
        'user_key': 'user1',
        'source_id': 'src',
        'item_id': 'fromOtherDevice',
        'title': 'Cloud Title',
        'cover': 'cloud.png',
        'cover_headers': null,
        'url': 'https://x/cloud',
        'type': 'anime',
        'added_at': 0,
      });
      await store.pullFromCloud();

      expect(fake.listForCalls, fullListReads);
      expect(
        store.all().map((item) => item.id),
        containsAll(['cached', 'fromOtherDevice']),
      );
    },
  );

  test(
    'first sync replays an add that arrives during the full snapshot',
    () async {
      await store.add(_item(id: 'beforeSnapshot'));
      fake.afterListSnapshot = () => fake.upsert({
        'user_key': 'user1',
        'source_id': 'src',
        'item_id': 'duringSnapshot',
        'title': 'Concurrent item',
        'cover': null,
        'cover_headers': null,
        'url': 'https://x/during',
        'type': 'anime',
      });

      await store.pullFromCloud();

      expect(
        store.all().map((item) => item.id),
        containsAll(['beforeSnapshot', 'duringSnapshot']),
      );
    },
  );

  test(
    'incremental pull applies a remote deletion without losing other rows',
    () async {
      await store.add(_item(id: 'keep'));
      await store.add(_item(id: 'remove'));
      await store.pullFromCloud();
      final fullListReads = fake.listForCalls;

      await fake.deleteRow('user1', 'src', 'remove');
      await store.pullFromCloud();

      expect(fake.listForCalls, fullListReads);
      expect(store.all().map((item) => item.id), {'keep'});
    },
  );

  test('failed incremental pull retries from the previous cursor', () async {
    await store.add(_item(id: 'cached'));
    await store.pullFromCloud();
    final fullListReads = fake.listForCalls;
    await fake.upsert({
      'user_key': 'user1',
      'source_id': 'src',
      'item_id': 'offlineChange',
      'title': 'Cloud Title',
      'cover': null,
      'cover_headers': null,
      'url': 'https://x/offline',
      'type': 'anime',
    });
    fake.failNextChanges = true;

    await store.pullFromCloud();
    expect(
      store.all().map((item) => item.id),
      isNot(contains('offlineChange')),
    );
    await store.pullFromCloud();

    expect(fake.listForCalls, fullListReads);
    expect(store.all().map((item) => item.id), contains('offlineChange'));
  });

  test(
    'failed first snapshot leaves the local list visible and retries fully',
    () async {
      await store.add(_item(id: 'cached'));
      fake.failNextList = true;

      await store.pullFromCloud();

      expect(store.all().map((item) => item.id), contains('cached'));
      final readsAfterFailure = fake.listForCalls;
      await store.pullFromCloud();

      expect(fake.listForCalls, readsAfterFailure + 1);
      expect(store.all().map((item) => item.id), contains('cached'));
    },
  );

  test('all() survives a row whose coverHeaders is Map<dynamic,dynamic> '
      '(the After-restart My List grey-screen crash)', () {
    // On a cold read from disk Hive returns nested maps as
    // Map<dynamic,dynamic>, which MediaItem.fromJson used to reject with a
    // cast error — crashing the whole My List body into a grey error box.
    // Reproduce that exact runtime type here.
    Hive.box<Map>(MyListStore.boxName).put(
      'src::withHeaders',
      <String, dynamic>{
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
      },
    );

    late List<MediaItem> items;
    expect(() => items = store.all(), returnsNormally);
    final item = items.firstWhere((m) => m.id == 'withHeaders');
    expect(item.coverHeaders?['Referer'], 'https://anikototv.to/');
    expect(item.coverHeaders?['User-Agent'], 'Mozilla/5.0');
  });

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

  test(
    'status sync: pullFromCloud hydrates the local status from the cloud',
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
    },
  );

  test(
    'status sync: pullFromCloud back-fills a local status the cloud lacks',
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
      await Future<void>.delayed(
        const Duration(milliseconds: 10),
      ); // let backfill run
      final row = fake.rows.firstWhere((r) => r['item_id'] == 'd');
      expect(row['status'], 'completed');
    },
  );

  // ── Backfill / cross-device seed ──────────────────────────────────────────

  test('pushAllLocalToCloud() is absent-only: uploads missing items, never '
      'clobbers a row the cloud already has', () async {
    // Cloud already has "shared" with a status; local has a status-less copy
    // plus a local-only item.
    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'item_id': 'shared',
      'title': 'T',
      'cover': null,
      'cover_headers': null,
      'url': 'u',
      'type': 'anime',
      'status': 'completed',
      'added_at': 0,
    });
    final loggedOut = MyListStore(SupabaseService(), () => null, remote: fake);
    await loggedOut.add(_item(id: 'shared'));
    await loggedOut.add(_item(id: 'localOnly'));

    final r = await store.pushAllLocalToCloud();

    expect(r.failed, 0);
    expect(r.pushed, 1); // only localOnly
    // "shared" untouched — its cloud status survives.
    expect(
      fake.rows.firstWhere((r) => r['item_id'] == 'shared')['status'],
      'completed',
    );
    expect(fake.rows.any((r) => r['item_id'] == 'localOnly'), isTrue);
  });

  test(
    'stale local rows do not resurrect a cloud-deleted item during seeding',
    () async {
      await store.add(_item(id: 'deletedElsewhere'));
      await fake.deleteRow('user1', 'src', 'deletedElsewhere');

      final result = await store.pushAllLocalToCloud();

      expect(result.failed, 0);
      expect(result.pushed, 0);
      expect(fake.rows.any((r) => r['item_id'] == 'deletedElsewhere'), isFalse);
    },
  );

  test('failed delete is retried and is not resurrected by a pull', () async {
    await store.add(_item(id: 'x'));
    await store.seedCloudIfNeeded();
    fake.failNextDelete = true;
    await store.remove(_item(id: 'x'));

    expect(store.all().map((m) => m.id), isNot(contains('x')));
    expect(store.pendingDeleteKeys(), contains('src::x'));
    expect(fake.rows.any((r) => r['item_id'] == 'x'), isTrue);

    await store.pullFromCloud();
    expect(store.all().map((m) => m.id), isNot(contains('x')));

    await store.retryPending();
    expect(fake.rows.any((r) => r['item_id'] == 'x'), isFalse);
    expect(store.pendingDeleteKeys(), isEmpty);
  });

  test('after seed, a remote delete is applied locally', () async {
    await store.add(_item(id: 'keep'));
    await store.add(_item(id: 'gone'));
    await store.seedCloudIfNeeded();
    await store.pullFromCloud(); // establish the initial-sync cursor
    await fake.deleteRow('user1', 'src', 'gone');

    await store.pullFromCloud();

    expect(store.all().map((m) => m.id).toSet(), {'keep'});
  });

  test('after seed, a pending local add survives a pull', () async {
    await store.add(_item(id: 'synced'));
    await store.seedCloudIfNeeded();
    fake.failNext = true;
    await store.add(_item(id: 'unsynced'));

    await store.pullFromCloud();

    expect(store.all().map((m) => m.id).toSet(), {'synced', 'unsynced'});
    expect(store.pendingKeys(), contains('src::unsynced'));
  });

  test(
    'pullFromCloud() with an EMPTY cloud does NOT wipe a local-only item',
    () async {
      // Add an item while logged-out so it never reaches the fake cloud, then pull
      // against the empty cloud — a merge must keep it (replace used to wipe it).
      final loggedOut = MyListStore(
        SupabaseService(),
        () => null,
        remote: fake,
      );
      await loggedOut.add(_item(id: 'localOnly'));
      expect(fake.rows.where((r) => r['user_key'] == 'user1'), isEmpty);

      await store.pullFromCloud();

      expect(store.all().map((m) => m.id), contains('localOnly'));
    },
  );

  test(
    'seedCloudIfNeeded() backfills once, then a pull keeps everything',
    () async {
      final loggedOut = MyListStore(
        SupabaseService(),
        () => null,
        remote: fake,
      );
      await loggedOut.add(_item(id: 'a'));
      await loggedOut.add(_item(id: 'b'));
      expect(fake.rows.where((r) => r['user_key'] == 'user1'), isEmpty);

      await store.seedCloudIfNeeded();
      expect(fake.rows.where((r) => r['user_key'] == 'user1'), hasLength(2));

      await store.pullFromCloud();
      expect(store.all().map((m) => m.id).toSet(), {'a', 'b'});

      // Runs once — a second call makes no new writes.
      final before = fake.rows.length;
      await store.seedCloudIfNeeded();
      expect(fake.rows.length, before);
    },
  );

  // A list written by a build with extra ProviderType values (the manga branch
  // adds `manga` and `novel`) must not take down the whole screen on a build
  // that only knows anime/movie. Records outlive the schema that wrote them.
  group('records this build cannot decode', () {
    /// Writes a raw row straight into the box, bypassing MediaItem so an
    /// unknown enum value can be stored the way the manga build left it.
    Future<void> putRaw(String key, Map<String, dynamic> row) =>
        Hive.box<Map>(MyListStore.boxName).put(key, row);

    test(
      'all() skips an unreadable row and still returns the good ones',
      () async {
        await store.add(_item(id: 'good1'));
        await store.add(_item(id: 'good2'));
        await putRaw('src::mangaone', {
          'id': 'mangaone',
          'sourceId': 'src',
          'title': 'Blue Lock',
          'cover': 'c.png',
          'url': 'https://x/mangaone',
          'type': 'unknownfuturetype', // not a ProviderType on this build
        });

        final all = store.all();

        expect(
          all.map((i) => i.id),
          containsAll(['good1', 'good2']),
          reason: 'valid rows must survive an undecodable neighbour',
        );
        expect(all.map((i) => i.id), isNot(contains('mangaone')));
        expect(all, hasLength(2));
      },
    );

    test('the unreadable row is kept on disk, not deleted', () async {
      await putRaw('src::mangaone', {
        'id': 'mangaone',
        'sourceId': 'src',
        'title': 'Blue Lock',
        'url': 'https://x/mangaone',
        'type': 'unknownfuturetype',
      });

      store.all(); // read it — must not prune

      expect(
        Hive.box<Map>(MyListStore.boxName).containsKey('src::mangaone'),
        isTrue,
        reason: 'a build that understands manga should still find the row',
      );
    });

    test('pullFromCloud skips a bad row and merges the rest', () async {
      fake.rows.addAll([
        {
          'user_key': 'user1',
          'source_id': 'src',
          'item_id': 'bad',
          'title': 'Manga Title',
          'cover': null,
          'cover_headers': null,
          'url': 'https://x/bad',
          'type': 'unknownfuturetype', // undecodable here
        },
        {
          'user_key': 'user1',
          'source_id': 'src',
          'item_id': 'good',
          'title': 'Anime Title',
          'cover': null,
          'cover_headers': null,
          'url': 'https://x/good',
          'type': 'anime',
        },
      ]);

      await store.pullFromCloud();

      expect(
        store.all().map((i) => i.id),
        contains('good'),
        reason: 'a bad row must not abort the rest of the pull',
      );
      expect(store.all().map((i) => i.id), isNot(contains('bad')));
      expect(
        Hive.box<Map>(MyListStore.boxName).containsKey('src::bad'),
        isTrue,
        reason: 'a later build may understand this stored type',
      );
    });

    test('a list with no bad rows is unaffected', () async {
      await store.add(_item(id: 'a'));
      await store.add(_item(id: 'b'));

      expect(store.all().map((i) => i.id), containsAll(['a', 'b']));
      expect(store.all(), hasLength(2));
    });
  });
}
