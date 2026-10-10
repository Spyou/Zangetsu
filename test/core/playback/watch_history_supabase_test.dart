import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

/// In-memory fake for [HistoryRemote] so the store's throttle/flush logic can
/// be tested without a live Supabase project.
class FakeHistoryRemote implements HistoryRemote {
  final List<Map<String, dynamic>> rows = [];
  int upsertCalls = 0;
  bool failNextPage = false;

  @override
  Future<void> upsert(Map<String, dynamic> row) async {
    upsertCalls++;
    rows.removeWhere(
      (r) =>
          r['user_key'] == row['user_key'] &&
          r['profile_id'] == row['profile_id'] &&
          r['source_id'] == row['source_id'] &&
          r['show_id'] == row['show_id'],
    );
    rows.add(row);
  }

  @override
  Future<void> deleteRow(
    String userKey,
    String sourceId,
    String showId, {
    String? profileId,
  }) async {
    rows.removeWhere(
      (r) =>
          r['user_key'] == userKey &&
          r['profile_id'] == profileId &&
          r['source_id'] == sourceId &&
          r['show_id'] == showId,
    );
  }

  @override
  Future<void> deleteAllFor(String userKey, {String? profileId}) async {
    rows.removeWhere(
      (r) => r['user_key'] == userKey && r['profile_id'] == profileId,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(
    String userKey, {
    String? profileId,
  }) async {
    return rows
        .where((r) => r['user_key'] == userKey && r['profile_id'] == profileId)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> pageFor(
    String userKey, {
    String? profileId,
    required int offset,
  }) async {
    if (failNextPage) {
      failNextPage = false;
      throw Exception('network down');
    }
    final page =
        rows
            .where(
              (r) => r['user_key'] == userKey && r['profile_id'] == profileId,
            )
            .toList()
          ..sort((a, b) {
            final updated = (b['updated_at'] as num? ?? 0).compareTo(
              a['updated_at'] as num? ?? 0,
            );
            if (updated != 0) return updated;
            final source = '${a['source_id']}'.compareTo('${b['source_id']}');
            return source != 0
                ? source
                : '${a['show_id']}'.compareTo('${b['show_id']}');
          });
    return page.skip(offset).take(HistoryRemote.pageSize).toList();
  }
}

HistoryEntry _entry({
  String sourceId = 'src',
  String showId = 'show1',
  Duration position = const Duration(minutes: 1),
}) => HistoryEntry(
  sourceId: sourceId,
  showId: showId,
  showTitle: 'Title',
  showUrl: 'https://x/$showId',
  category: 'sub',
  episodeId: 'ep1',
  episodeNumber: 1,
  episodeUrl: 'https://x/$showId/ep1',
  position: position,
  duration: const Duration(minutes: 24),
  updatedAt: DateTime.now().millisecondsSinceEpoch,
);

void main() {
  late Directory tmpDir;
  late FakeHistoryRemote fake;
  late WatchHistory history;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('watch_history_test');
    Hive.init(tmpDir.path);
    await WatchHistory.init();
    fake = FakeHistoryRemote();
    history = WatchHistory(SupabaseService(), () => 'user1', remote: fake);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  HistoryEntry entryAt(String showId, int updatedAt) => HistoryEntry(
    sourceId: 'src',
    showId: showId,
    showTitle: 'T',
    showUrl: 'u',
    category: 'sub',
    episodeId: 'e',
    episodeNumber: 1,
    episodeUrl: 'u',
    position: const Duration(seconds: 1),
    duration: const Duration(seconds: 2),
    updatedAt: updatedAt,
  );

  test(
    'two save() calls for the same show within 120s throttle to one upsert',
    () async {
      await history.save(_entry(position: const Duration(minutes: 1)));
      await history.save(_entry(position: const Duration(minutes: 2)));

      expect(fake.upsertCalls, 1);
      // Local (Hive) save is always immediate regardless of throttle.
      expect(history.recent().single.position, const Duration(minutes: 2));
      // The throttled remote upsert still carries the first save's value.
      expect(
        fake.rows.single['position_ms'],
        const Duration(minutes: 1).inMilliseconds,
      );
    },
  );

  test('watch progress is isolated by profile', () async {
    var activeProfileId = 'default';
    final scoped = WatchHistory(
      SupabaseService(),
      () => 'user1',
      remote: fake,
      currentProfileId: () => activeProfileId,
    );

    await scoped.save(
      _entry(showId: 'same', position: const Duration(minutes: 1)),
    );
    activeProfileId = 'kid';
    await scoped.save(
      _entry(showId: 'same', position: const Duration(minutes: 3)),
    );

    expect(scoped.all().single.position, const Duration(minutes: 3));
    expect(fake.rows.map((r) => r['profile_id']), [null, 'kid']);

    activeProfileId = 'default';
    expect(scoped.all().single.position, const Duration(minutes: 1));
  });

  test(
    'save(flush: true) forces an immediate upsert regardless of throttle',
    () async {
      await history.save(_entry(position: const Duration(minutes: 1)));
      expect(fake.upsertCalls, 1);

      await history.save(
        _entry(position: const Duration(minutes: 5)),
        flush: true,
      );

      expect(fake.upsertCalls, 2);
      expect(
        fake.rows.single['position_ms'],
        const Duration(minutes: 5).inMilliseconds,
      );
    },
  );

  test('pullFromCloud() MERGES cloud into local, keeping local-only rows '
      '(never wipes an un-synced Continue Watching item)', () async {
    // A logged-out local save never reaches the fake remote, so it's a true
    // local-only row — a merge pull must KEEP it (the old replace wiped it,
    // which lost un-synced Continue Watching when the cloud was empty).
    final loggedOut = WatchHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(_entry(showId: 'localOnly'));
    expect(history.all(), hasLength(1)); // same Hive box

    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'show_id': 'fromCloud',
      'show_title': 'Cloud Title',
      'cover': null,
      'cover_headers': null,
      'show_url': 'https://x/fromCloud',
      'category': 'sub',
      'episode_id': 'ep1',
      'episode_number': 1,
      'episode_url': 'https://x/fromCloud/ep1',
      'position_ms': 60000,
      'duration_ms': 1440000,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
      'mal_id': null,
    });

    await history.pullFromCloud();

    final ids = history.all().map((e) => e.showId).toSet();
    expect(ids, {
      'localOnly',
      'fromCloud',
    }); // both survive — merge, not replace
  });

  test(
    'pullFromCloud() initially loads only the newest 200 cloud rows',
    () async {
      for (var i = 0; i < 201; i++) {
        fake.rows.add({
          'user_key': 'user1',
          'source_id': 'src',
          'show_id': 'show$i',
          'show_title': 'Show $i',
          'cover': null,
          'cover_headers': null,
          'show_url': 'https://x/show$i',
          'category': 'sub',
          'episode_id': 'ep1',
          'episode_number': 1,
          'episode_url': 'https://x/show$i/ep1',
          'position_ms': 1000,
          'duration_ms': 10000,
          'updated_at': i,
          'mal_id': null,
        });
      }

      await history.pullFromCloud();

      expect(history.all(), hasLength(200));
      expect(history.all().first.showId, 'show200');

      await history.loadMoreFromCloud();

      expect(history.all(), hasLength(201));
      expect(history.all().last.showId, 'show0');
    },
  );

  test('failed watch-history pages keep the cursor for retry', () async {
    for (var i = 0; i < 201; i++) {
      fake.rows.add({
        'user_key': 'user1',
        'source_id': 'src',
        'show_id': 'show$i',
        'show_title': 'Show $i',
        'cover': null,
        'cover_headers': null,
        'show_url': 'https://x/show$i',
        'category': 'sub',
        'episode_id': 'ep1',
        'episode_number': 1,
        'episode_url': 'https://x/show$i/ep1',
        'position_ms': 1000,
        'duration_ms': 10000,
        'updated_at': i,
        'mal_id': null,
      });
    }
    await history.pullFromCloud();
    fake.failNextPage = true;

    await history.loadMoreFromCloud();
    expect(history.all(), hasLength(200));
    await history.loadMoreFromCloud();

    expect(history.all(), hasLength(201));
  });

  test('pullFromCloud() with an EMPTY cloud does NOT wipe local history '
      '(the boot-time data-loss regression)', () async {
    // The exact bug: a device with local-only Continue Watching pulls against an
    // empty cloud (fresh/orphaned account, or a session that went live mid-boot).
    final loggedOut = WatchHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(_entry(showId: 'a'));
    await loggedOut.save(_entry(showId: 'b'));
    expect(
      fake.rows.where((r) => r['user_key'] == 'user1'),
      isEmpty,
    ); // cloud empty

    await history.pullFromCloud();

    expect(history.all().map((e) => e.showId).toSet(), {'a', 'b'}); // untouched
  });

  test(
    'pullFromCloud() overwrites a local row only when the cloud is newer',
    () async {
      final loggedOut = WatchHistory(
        SupabaseService(),
        () => null,
        remote: fake,
      );
      await loggedOut.save(entryAt('shared', 100)); // local at t=100
      fake.rows.add({
        'user_key': 'user1', 'source_id': 'src', 'show_id': 'shared',
        'show_title': 'Cloud', 'cover': null, 'cover_headers': null,
        'show_url': 'u',
        'category': 'sub',
        'episode_id': 'e',
        'episode_number': 1,
        'episode_url': 'u', 'position_ms': 5000, 'duration_ms': 6000,
        'updated_at': 50, 'mal_id': null, // OLDER than local
      });

      await history.pullFromCloud();

      // Local (t=100) kept; the older cloud copy did not clobber it.
      expect(history.recent().single.position, const Duration(seconds: 1));
    },
  );

  test('clearAll() wipes local AND cloud, so a later pull restores nothing '
      '(the "cleared shows came back" bug)', () async {
    await history.save(_entry(showId: 'a'), flush: true);
    await history.save(_entry(showId: 'b'), flush: true);
    expect(fake.rows.where((r) => r['user_key'] == 'user1'), hasLength(2));

    await history.clearAll();

    expect(history.all(), isEmpty); // local gone
    expect(
      fake.rows.where((r) => r['user_key'] == 'user1'),
      isEmpty,
    ); // cloud gone

    // The regression: a pull after clearing must NOT bring them back.
    await history.pullFromCloud();
    expect(history.all(), isEmpty);
  });

  test(
    'clearLocal() keeps the cloud (logout path) — a pull restores it',
    () async {
      await history.save(_entry(showId: 'a'), flush: true);

      await history.clearLocal();
      expect(history.all(), isEmpty); // local dropped

      // Cloud still has it (that's the point on logout) — a pull brings it back.
      await history.pullFromCloud();
      expect(history.all().map((e) => e.showId), ['a']);
    },
  );

  test('pushAllLocalToCloud() is newest-wins: uploads absent + locally-newer, '
      'never clobbers a newer cloud row', () async {
    // Cloud already has "shared" at t=100.
    fake.rows.add({
      'user_key': 'user1',
      'source_id': 'src',
      'show_id': 'shared',
      'show_title': 'C',
      'cover': null,
      'cover_headers': null,
      'show_url': 'u',
      'category': 'sub',
      'episode_id': 'e',
      'episode_number': 1,
      'episode_url': 'u',
      'position_ms': 1000,
      'duration_ms': 2000,
      'updated_at': 100,
      'mal_id': null,
    });
    // Local: a STALE copy of "shared" (t=50) + a fresh local-only show.
    final loggedOut = WatchHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(entryAt('shared', 50));
    await loggedOut.save(entryAt('localOnly', 999));

    final r = await history.pushAllLocalToCloud();

    expect(r.failed, 0);
    expect(r.pushed, 1); // only localOnly; "shared" skipped (cloud is newer)
    final cloud = fake.rows.where((r) => r['user_key'] == 'user1');
    expect(
      cloud.firstWhere((r) => r['show_id'] == 'shared')['updated_at'],
      100,
    );
    expect(cloud.any((r) => r['show_id'] == 'localOnly'), isTrue);
  });

  test('seedCloudIfNeeded() backfills a local library once, so the destructive '
      'pull restores it instead of wiping it (the empty-cloud case)', () async {
    // Local has shows; cloud is empty (rows stranded under an old id).
    final loggedOut = WatchHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(_entry(showId: 'a'));
    await loggedOut.save(_entry(showId: 'b'));
    expect(fake.rows.where((r) => r['user_key'] == 'user1'), isEmpty);

    await history.seedCloudIfNeeded(); // push local -> cloud, once
    expect(fake.rows.where((r) => r['user_key'] == 'user1'), hasLength(2));

    // The pull that used to wipe local now just restores it.
    await history.pullFromCloud();
    expect(history.all().map((e) => e.showId).toSet(), {'a', 'b'});

    // Runs once: a second seed makes no new writes.
    final before = fake.upsertCalls;
    await history.seedCloudIfNeeded();
    expect(fake.upsertCalls, before);
  });
}
