import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';

/// In-memory fake for [ReadingHistoryRemote], mirroring FakeHistoryRemote in
/// watch_history_supabase_test.dart, so the store's throttle/flush/merge
/// logic is testable without a live Supabase project.
class FakeReadingHistoryRemote implements ReadingHistoryRemote {
  final List<Map<String, dynamic>> rows = [];
  int upsertCalls = 0;

  @override
  Future<void> upsert(Map<String, dynamic> row) async {
    upsertCalls++;
    rows.removeWhere((r) =>
        r['user_key'] == row['user_key'] &&
        r['source_id'] == row['source_id'] &&
        r['show_id'] == row['show_id']);
    rows.add(row);
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    return rows.where((r) => r['user_key'] == userKey).toList();
  }

  @override
  Future<void> deleteRow(String userKey, String sourceId, String showId) async {
    rows.removeWhere((r) =>
        r['user_key'] == userKey &&
        r['source_id'] == sourceId &&
        r['show_id'] == showId);
  }

  @override
  Future<void> deleteAllForType(String userKey, String typeName) async {
    rows.removeWhere((r) => r['user_key'] == userKey && r['type'] == typeName);
  }
}

/// Throws on every call, standing in for the `reading_history` table not
/// existing yet on the user's Supabase project (or being offline).
class _BrokenReadingHistoryRemote implements ReadingHistoryRemote {
  @override
  Future<void> upsert(Map<String, dynamic> row) async {
    throw Exception('relation "reading_history" does not exist');
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    throw Exception('relation "reading_history" does not exist');
  }

  @override
  Future<void> deleteRow(String userKey, String sourceId, String showId) async {
    throw Exception('relation "reading_history" does not exist');
  }

  @override
  Future<void> deleteAllForType(String userKey, String typeName) async {
    throw Exception('relation "reading_history" does not exist');
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('read_history');
    Hive.init(dir.path);
    await ReadHistory.init();
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ReadEntry entry(
    String show, {
    int pos = 0,
    int total = 20,
    int ts = 0,
    ProviderType type = ProviderType.novel,
  }) => ReadEntry(
    sourceId: 'js:m', showId: show, title: show, cover: null,
    chapterId: 'ch1', chapterNumber: 1, chapterUrl: 'u',
    pos: pos, total: total, updatedMs: ts, type: type,
  );

  test('save keeps one row per title (latest chapter wins)', () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(entry('a', pos: 1, ts: 1));
    await h.save(entry('a', pos: 5, ts: 2));
    expect(h.recent(), hasLength(1));
    expect(h.recent().single.pos, 5);
  });

  test('recent() excludes finished and sorts newest-first', () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(entry('done', pos: 19, total: 20, ts: 1)); // finished
    await h.save(entry('old', pos: 2, ts: 10));
    await h.save(entry('new', pos: 2, ts: 20));
    expect(h.recent().map((e) => e.showId).toList(), ['new', 'old']);
  });

  test('recent() applies the novel permille finished rule (total == 1000)',
      () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(entry('almostDone', pos: 950, total: 1000, ts: 1));
    await h.save(entry('reading', pos: 500, total: 1000, ts: 2));
    expect(h.recent().map((e) => e.showId).toList(), ['reading']);
  });

  test('recent(type:) returns only that kind — the box mixes manga and novel',
      () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(entry('m1', ts: 3, type: ProviderType.manga));
    await h.save(entry('n1', ts: 2, type: ProviderType.novel));
    await h.save(entry('m2', ts: 1, type: ProviderType.manga));
    expect(h.recent(type: ProviderType.manga).map((e) => e.showId).toList(),
        ['m1', 'm2']);
    expect(h.recent(type: ProviderType.novel).map((e) => e.showId).toList(),
        ['n1']);
    expect(h.recent().length, 3); // no type → both (backward compatible)
  });

  test('two save() calls for the same show within the throttle window '
      'push one upsert; the local read is always immediate', () async {
    final fake = FakeReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.save(entry('a', pos: 1, ts: 1));
    await h.save(entry('a', pos: 5, ts: 2));

    expect(fake.upsertCalls, 1);
    expect(h.recent().single.pos, 5); // local write is never throttled
    expect(fake.rows.single['pos'], 1); // throttled remote still has the first
  });

  test('save(flush: true) forces an immediate upsert regardless of throttle',
      () async {
    final fake = FakeReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.save(entry('a', pos: 1, ts: 1));
    expect(fake.upsertCalls, 1);

    await h.save(entry('a', pos: 5, ts: 2), flush: true);

    expect(fake.upsertCalls, 2);
    expect(fake.rows.single['pos'], 5);
  });

  test('pullFromCloud() merges cloud into local, keeping local-only rows '
      '(never wipes an un-synced Continue Reading item)', () async {
    final fake = FakeReadingHistoryRemote();
    final loggedOut = ReadHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(entry('localOnly', pos: 3, ts: 5));

    fake.rows.add({
      'user_key': 'user1', 'source_id': 'js:m', 'show_id': 'fromCloud',
      'title': 'Cloud Title', 'cover': null, 'chapter_id': 'ch1',
      'chapter_number': 1, 'chapter_url': 'u', 'pos': 2, 'total': 20,
      'updated_ms': 9,
    });

    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.pullFromCloud();

    final ids = h.recent().map((e) => e.showId).toSet();
    expect(ids, {'localOnly', 'fromCloud'}); // both survive — merge, not replace
  });

  test('pullFromCloud() does NOT overwrite a local row when the cloud copy '
      'is OLDER (newest-wins, local-newer direction)', () async {
    final fake = FakeReadingHistoryRemote();
    final loggedOut = ReadHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(entry('shared', pos: 8, ts: 100)); // local at t=100

    fake.rows.add({
      'user_key': 'user1', 'source_id': 'js:m', 'show_id': 'shared',
      'title': 'Cloud', 'cover': null, 'chapter_id': 'chCloud',
      'chapter_number': 9, 'chapter_url': 'uCloud', 'pos': 2, 'total': 20,
      'updated_ms': 50, // OLDER than local
    });

    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.pullFromCloud();

    final row = h.recent().single;
    expect(row.pos, 8); // local content kept
    expect(row.chapterId, 'ch1'); // local content kept, not the cloud's 'chCloud'
    expect(row.updatedMs, 100);
  });

  test('pullFromCloud() DOES overwrite a local row when the cloud copy is '
      'NEWER (newest-wins, cloud-newer direction)', () async {
    final fake = FakeReadingHistoryRemote();
    final loggedOut = ReadHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(entry('shared', pos: 2, ts: 10)); // local at t=10

    fake.rows.add({
      'user_key': 'user1', 'source_id': 'js:m', 'show_id': 'shared',
      'title': 'Cloud', 'cover': null, 'chapter_id': 'chCloud',
      'chapter_number': 9, 'chapter_url': 'uCloud', 'pos': 15, 'total': 20,
      'updated_ms': 99, // NEWER than local
    });

    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.pullFromCloud();

    final row = h.recent().single;
    expect(row.pos, 15); // cloud content won
    expect(row.chapterId, 'chCloud'); // cloud content won, not the local's 'ch1'
    expect(row.updatedMs, 99);
  });

  test('clearLocal() drops local rows and the lastPull marker but leaves '
      'the cloud untouched (logout path) — a pull restores it', () async {
    final fake = FakeReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.save(entry('a', pos: 1, ts: 1), flush: true);
    expect(h.recent(), hasLength(1));

    await h.clearLocal();

    expect(h.recent(), isEmpty); // local dropped
    expect(fake.rows.where((r) => r['user_key'] == 'user1'), hasLength(1)); // cloud survives

    await h.pullFromCloud(); // cloud still has it — a pull brings it back
    expect(h.recent().single.showId, 'a');
  });

  test('seedCloudIfNeeded() backfills local rows to an empty cloud once, '
      'so a following pull restores instead of wiping', () async {
    final fake = FakeReadingHistoryRemote();
    final loggedOut = ReadHistory(SupabaseService(), () => null, remote: fake);
    await loggedOut.save(entry('a', pos: 1, ts: 1));
    await loggedOut.save(entry('b', pos: 1, ts: 1));

    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.seedCloudIfNeeded();
    expect(fake.rows.where((r) => r['user_key'] == 'user1'), hasLength(2));

    final before = fake.upsertCalls;
    await h.seedCloudIfNeeded(); // second call is a no-op
    expect(fake.upsertCalls, before);
  });

  test('a missing reading_history table (or offline) degrades to '
      'local-only silently — save/recent/pullFromCloud/seedCloudIfNeeded '
      'never throw', () async {
    final broken = _BrokenReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: broken);

    await h.save(entry('a', pos: 1, ts: 1), flush: true); // forces the upsert
    expect(h.recent().single.showId, 'a'); // local write still succeeded

    await h.pullFromCloud(); // must not throw despite listFor() throwing
    await h.seedCloudIfNeeded(); // must not throw despite upsert() throwing
    expect(h.recent().single.showId, 'a'); // local state untouched
  });

  // ── pullFromCloudIfStale (Task 12 Part D) ───────────────────────────────
  // Mirrors WatchHistory.pullFromCloudIfStale's staleness-marker behaviour —
  // without it, boot/resume have nothing to call and Continue Reading only
  // ever restores on sign-in.

  Map<String, dynamic> cloudRow(String showId, {int updatedMs = 100}) => {
    'user_key': 'user1', 'source_id': 'js:m', 'show_id': showId,
    'title': 'Cloud $showId', 'cover': null, 'chapter_id': 'chCloud',
    'chapter_number': 1, 'chapter_url': 'u', 'pos': 1, 'total': 20,
    'updated_ms': updatedMs,
  };

  test('pullFromCloudIfStale() pulls when there is no prior pull marker',
      () async {
    final fake = FakeReadingHistoryRemote()..rows.add(cloudRow('fromCloud'));
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);

    await h.pullFromCloudIfStale();

    expect(h.recent().map((e) => e.showId), contains('fromCloud'));
  });

  test('pullFromCloudIfStale() skips the pull when the marker is fresher '
      'than maxAge', () async {
    final fake = FakeReadingHistoryRemote()..rows.add(cloudRow('fromCloud'));
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.pullFromCloud(); // sets the "just pulled" marker
    fake.rows.add(cloudRow('addedAfterMarker')); // arrives after that pull

    await h.pullFromCloudIfStale(maxAge: const Duration(hours: 12));

    // Still fresh — the second row was never fetched.
    expect(
      h.recent().map((e) => e.showId),
      isNot(contains('addedAfterMarker')),
    );
  });

  test('pullFromCloudIfStale() pulls when the marker is older than maxAge',
      () async {
    final fake = FakeReadingHistoryRemote()..rows.add(cloudRow('fromCloud'));
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.pullFromCloud();
    // Back-date the marker past maxAge so the next call treats it as stale.
    Hive.box(ReadHistory.syncMetaBox).put(
      'reading_history_lastPullMs',
      DateTime.now().millisecondsSinceEpoch - const Duration(days: 1).inMilliseconds,
    );
    fake.rows.add(cloudRow('addedLater', updatedMs: 200));

    await h.pullFromCloudIfStale(maxAge: const Duration(hours: 12));

    expect(h.recent().map((e) => e.showId), contains('addedLater'));
  });

  test('pullFromCloudIfStale() does nothing when signed out', () async {
    final fake = FakeReadingHistoryRemote()..rows.add(cloudRow('fromCloud'));
    final h = ReadHistory(SupabaseService(), () => null, remote: fake);

    await h.pullFromCloudIfStale();

    expect(h.recent(), isEmpty);
  });

  // ── ReadEntry.type (final whole-branch review, Finding 2) ───────────────
  // The discriminator _resumeReading routes on. A round trip must keep an
  // explicit type; a row with no 'type' key at all (every row ever written
  // before this field existed) must default to novel — see
  // readEntryTypeFromName's doc comment for why novel, not manga, is the
  // safe default.

  test('readEntryTypeFromName: manga round-trips, everything else '
      '(including null — a pre-existing row) defaults to novel', () {
    expect(readEntryTypeFromName('manga'), ProviderType.manga);
    expect(readEntryTypeFromName('novel'), ProviderType.novel);
    expect(readEntryTypeFromName(null), ProviderType.novel);
    expect(readEntryTypeFromName('anime'), ProviderType.novel);
    expect(readEntryTypeFromName('garbage'), ProviderType.novel);
  });

  test('toJson/fromJson round-trips a manga entry\'s type', () {
    final e = entry('m', type: ProviderType.manga);
    final back = ReadEntry.fromJson(e.toJson());
    expect(back.type, ProviderType.manga);
  });

  test('fromJson defaults to novel when the stored map has no type key '
      'at all (a row saved before this field existed)', () {
    final legacy = entry('legacy').toJson()..remove('type');
    expect(ReadEntry.fromJson(legacy).type, ProviderType.novel);
  });

  test('save() then reading back from the box preserves a manga entry\'s '
      'type (Hive round trip, not just toJson/fromJson in memory)',
      () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(entry('m', type: ProviderType.manga));
    expect(h.recent().single.type, ProviderType.manga);
  });

  // ── History screen: all() / remove() / clearType() ──────────────────────

  test('all() returns every row (finished included) newest-first', () async {
    final h = ReadHistory(SupabaseService(), () => null);
    await h.save(
      entry('finishedManga', pos: 19, total: 20, ts: 1, type: ProviderType.manga),
    );
    await h.save(entry('novelA', pos: 2, ts: 5));
    final all = h.all();
    // newest-first, and unlike recent() the finished row is NOT dropped.
    expect(all.map((e) => e.showId).toList(), ['novelA', 'finishedManga']);
  });

  test('get() returns the saved entry for a title, or null when there is '
      'none — the Read button\'s cross-device resume fallback', () async {
    final h = ReadHistory(SupabaseService(), () => null);
    expect(h.get('js:m', 'a'), isNull);

    await h.save(entry('a', pos: 4, ts: 1));
    final got = h.get('js:m', 'a');
    expect(got?.showId, 'a');
    expect(got?.pos, 4);
    expect(h.get('js:m', 'other'), isNull); // different show, no entry
  });

  test('remove() deletes the row locally and from the cloud', () async {
    final fake = FakeReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.save(entry('a', pos: 1, ts: 1), flush: true);
    expect(fake.rows, hasLength(1));

    await h.remove('js:m', 'a');

    expect(h.all(), isEmpty); // local gone
    expect(fake.rows, isEmpty); // cloud gone, so it can't sync back
  });

  test('clearType(manga) wipes only manga rows — local AND cloud — leaving '
      'novel history untouched', () async {
    final fake = FakeReadingHistoryRemote();
    final h = ReadHistory(SupabaseService(), () => 'user1', remote: fake);
    await h.save(entry('m1', ts: 1, type: ProviderType.manga), flush: true);
    await h.save(entry('n1', ts: 2, type: ProviderType.novel), flush: true);

    await h.clearType(ProviderType.manga);

    expect(h.all().map((e) => e.showId).toList(), ['n1']); // local: novel kept
    expect(fake.rows.map((r) => r['show_id']).toList(), ['n1']); // cloud too
  });
}
