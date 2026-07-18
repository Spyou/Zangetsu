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
  Future<void> deleteRow(String userKey, String sourceId, String showId) async {
    rows.removeWhere((r) =>
        r['user_key'] == userKey &&
        r['source_id'] == sourceId &&
        r['show_id'] == showId);
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    return rows.where((r) => r['user_key'] == userKey).toList();
  }
}

HistoryEntry _entry({
  String sourceId = 'src',
  String showId = 'show1',
  Duration position = const Duration(minutes: 1),
}) =>
    HistoryEntry(
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

  test('two save() calls for the same show within 120s throttle to one upsert',
      () async {
    await history.save(_entry(position: const Duration(minutes: 1)));
    await history.save(_entry(position: const Duration(minutes: 2)));

    expect(fake.upsertCalls, 1);
    // Local (Hive) save is always immediate regardless of throttle.
    expect(history.recent().single.position, const Duration(minutes: 2));
    // The throttled remote upsert still carries the first save's value.
    expect(fake.rows.single['position_ms'], const Duration(minutes: 1).inMilliseconds);
  });

  test('save(flush: true) forces an immediate upsert regardless of throttle',
      () async {
    await history.save(_entry(position: const Duration(minutes: 1)));
    expect(fake.upsertCalls, 1);

    await history.save(_entry(position: const Duration(minutes: 5)), flush: true);

    expect(fake.upsertCalls, 2);
    expect(fake.rows.single['position_ms'], const Duration(minutes: 5).inMilliseconds);
  });

  test('pullFromCloud() replaces local with remote rows', () async {
    // A logged-out local save never reaches the fake remote, so it's a true
    // local-only row that pullFromCloud must discard on replace.
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
    expect(ids, {'fromCloud'});
  });
}
