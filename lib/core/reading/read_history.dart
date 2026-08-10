import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/provider_info.dart';
import '../privacy/incognito_mode.dart';
import '../supabase/supabase_service.dart';

/// Parse a persisted [ReadEntry.type] name. Only 'manga'/'novel' are
/// meaningful here; anything else — including a row saved before this field
/// existed — falls back to [ProviderType.novel]. That's a deliberate,
/// backward-compatible default: every entry ever written before this field
/// existed was ALWAYS opened via NovelReaderScreen (that was true even after
/// MangaReaderScreen shipped — [ReadEntry] had no discriminator for
/// `_resumeReading` to route on), so defaulting a fieldless legacy row to
/// `novel` reproduces exactly the routing it already got. A legacy manga row
/// keeps today's (pre-existing) mis-routing instead of gaining a NEW failure
/// mode; only entries saved from this point on carry a real type and route
/// correctly.
ProviderType readEntryTypeFromName(String? name) =>
    name == ProviderType.manga.name ? ProviderType.manga : ProviderType.novel;

class ReadEntry {
  ReadEntry({
    required this.sourceId,
    required this.showId,
    required this.title,
    this.cover,
    required this.chapterId,
    this.chapterNumber,
    required this.chapterUrl,
    required this.pos,
    required this.total,
    required this.updatedMs,
    required this.type,
  });

  final String sourceId, showId, title, chapterId, chapterUrl;
  final String? cover;
  final double? chapterNumber;
  final int pos, total, updatedMs;

  /// manga or novel — which reader [showId]'s chapters open in. See
  /// [readEntryTypeFromName] for the missing/legacy-row default.
  final ProviderType type;

  /// Same finished rule as [ReadStore]: total == 1000 is the novel
  /// scroll-permille convention (>=950 counts as done); otherwise last
  /// page/chapter (manga).
  bool get finished => total > 0 && (total == 1000 ? pos >= 950 : pos >= total - 1);

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'showId': showId,
    'title': title,
    'cover': cover,
    'chapterId': chapterId,
    'chapterNumber': chapterNumber,
    'chapterUrl': chapterUrl,
    'pos': pos,
    'total': total,
    'updatedMs': updatedMs,
    'type': type.name,
  };

  factory ReadEntry.fromJson(Map<String, dynamic> m) => ReadEntry(
    sourceId: m['sourceId'] as String,
    showId: m['showId'] as String,
    title: m['title'] as String? ?? '',
    cover: m['cover'] as String?,
    chapterId: m['chapterId'] as String? ?? '',
    chapterNumber: (m['chapterNumber'] as num?)?.toDouble(),
    chapterUrl: m['chapterUrl'] as String? ?? '',
    pos: (m['pos'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num?)?.toInt() ?? 0,
    updatedMs: (m['updatedMs'] as num?)?.toInt() ?? 0,
    type: readEntryTypeFromName(m['type'] as String?),
  );
}

/// Thin transport seam over the `reading_history` Supabase table, injectable
/// so [ReadHistory]'s throttle/flush logic is unit-testable without a live
/// Supabase project. Mirrors [HistoryRemote] in watch_history.dart.
class ReadingHistoryRemote {
  ReadingHistoryRemote(this._service);

  final SupabaseService _service;

  Future<void> upsert(Map<String, dynamic> row) async {
    await _service.client
        .from('reading_history')
        .upsert(row, onConflict: 'user_key,source_id,show_id');
  }

  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    final res = await _service.client
        .from('reading_history')
        .select()
        .eq('user_key', userKey);
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<void> deleteRow(String userKey, String sourceId, String showId) async {
    await _service.client.from('reading_history').delete().match({
      'user_key': userKey,
      'source_id': sourceId,
      'show_id': showId,
    });
  }

  /// Delete every reading-history row for [userKey] of one kind
  /// (`'manga'`/`'novel'`) — used by the per-tab "Clear history" so it can't
  /// sync back, and so clearing manga never touches novel (they share a table).
  Future<void> deleteAllForType(String userKey, String typeName) async {
    await _service.client.from('reading_history').delete().match({
      'user_key': userKey,
      'type': typeName,
    });
  }
}

/// Continue Reading, backed by Hive for instant local reads and synced to
/// Supabase when signed in. The manga/novel sibling of [WatchHistory] — same
/// box/table/throttle/merge shape, ReadEntry fields instead of HistoryEntry.
class ReadHistory {
  ReadHistory(SupabaseService service, this._currentUserId, {ReadingHistoryRemote? remote})
      : _remote = remote ?? ReadingHistoryRemote(service);

  final ReadingHistoryRemote _remote;
  final String? Function() _currentUserId;

  static const String boxName = 'read_history';
  // Same rationale as WatchHistory's throttle: local saves stay instant, the
  // cloud push is throttled to 2 min and forced on flush (chapter change /
  // reader close) so cross-device resume stays accurate without hammering
  // free-tier write quotas.
  static const int _cloudThrottleMs = 120000;

  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'reading_history_lastPullMs';
  static const String _seedFlagPrefix = 'reading_history_seeded_';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await openBoxSafely(syncMetaBox);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId) => '$sourceId::$showId';
  final Map<String, int> _lastCloudPush = {};

  /// Persist progress. The local write is ALWAYS immediate (instant resume);
  /// the cloud push is throttled unless [flush] is true.
  Future<void> save(ReadEntry e, {bool flush = false}) async {
    if (IncognitoMode.on) return; // incognito: don't record what's read
    final key = _key(e.sourceId, e.showId);
    await _box.put(key, e.toJson());
    if (flush) {
      await _pushToCloud(key, e, force: true);
    } else {
      _pushToCloud(key, e);
    }
  }

  Map<String, dynamic> _rowFor(String uid, ReadEntry e) => {
    'user_key': uid,
    'source_id': e.sourceId,
    'show_id': e.showId,
    'title': e.title,
    'cover': e.cover,
    'chapter_id': e.chapterId,
    'chapter_number': e.chapterNumber,
    'chapter_url': e.chapterUrl,
    'pos': e.pos,
    'total': e.total,
    'updated_ms': e.updatedMs,
    'type': e.type.name,
  };

  Future<void> _pushToCloud(String key, ReadEntry e, {bool force = false}) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastCloudPush[key] ?? 0;
    if (!force && now - last < _cloudThrottleMs) return;
    _lastCloudPush[key] = now;
    try {
      await _remote.upsert(_rowFor(uid, e));
    } catch (_) {/* best-effort — missing table / offline degrades silently */}
  }

  ReadEntry _fromMap(Map raw) => ReadEntry.fromJson(Map<String, dynamic>.from(raw));

  /// Newest-first, excluding finished chapters (the Continue Reading feed).
  List<ReadEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
    return all.take(limit).toList();
  }

  /// Every read title, newest-first, including finished ones — backs both the
  /// full reading-History screen and [pushAllLocalToCloud]'s library backup,
  /// not just the unfinished subset [recent] surfaces. The box mixes manga and
  /// novel; callers filter on [ReadEntry.type].
  List<ReadEntry> all() {
    return _box.values.map(_fromMap).toList()
      ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
  }

  /// Notifies the Home "Continue Reading" row on any local change.
  ValueListenable<Box> listenable() => _box.listenable();

  /// Uploads local reading history to the cloud under the current account,
  /// newest-wins — see [WatchHistory.pushAllLocalToCloud] for the full
  /// rationale. Additive, never deletes.
  Future<({int pushed, int failed})> pushAllLocalToCloud() async {
    final uid = _currentUserId();
    if (uid == null) return (pushed: 0, failed: 0);
    final cloudTimes = <String, int>{};
    var readOk = true;
    try {
      for (final m in await _remote.listFor(uid)) {
        cloudTimes['${m['source_id']}::${m['show_id']}'] =
            (m['updated_ms'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      readOk = false;
    }
    var pushed = 0, failed = 0;
    for (final e in all()) {
      final key = _key(e.sourceId, e.showId);
      final cloudT = cloudTimes[key];
      if (cloudT != null && cloudT >= e.updatedMs) continue;
      try {
        await _remote.upsert(_rowFor(uid, e));
        pushed++;
      } catch (_) {
        failed++;
      }
    }
    if (!readOk) failed++;
    return (pushed: pushed, failed: failed);
  }

  /// One-time-per-account backfill, run before the first (destructive) merge
  /// pull — see [WatchHistory.seedCloudIfNeeded].
  Future<void> seedCloudIfNeeded() async {
    final uid = _currentUserId();
    if (uid == null || !Hive.isBoxOpen(syncMetaBox)) return;
    final box = Hive.box(syncMetaBox);
    final flag = '$_seedFlagPrefix$uid';
    if (box.get(flag) == true) return;
    final r = await pushAllLocalToCloud();
    if (r.failed == 0) await box.put(flag, true);
  }

  /// Merge the signed-in user's cloud reading history into the local cache,
  /// newest-wins, non-destructive — see [WatchHistory.pullFromCloud] for the
  /// full rationale (an empty/sparse cloud must never wipe local progress).
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final rows = await _remote.listFor(uid);
      for (final m in rows) {
        final key = '${m['source_id']}::${m['show_id']}';
        final cloudUpdated = (m['updated_ms'] as num?)?.toInt() ?? 0;
        final localUpdated = (_box.get(key)?['updatedMs'] as num?)?.toInt() ?? -1;
        if (cloudUpdated <= localUpdated) continue; // local is same/newer — keep it
        await _box.put(key, {
          'sourceId': m['source_id'],
          'showId': m['show_id'],
          'title': m['title'],
          'cover': m['cover'],
          'chapterId': m['chapter_id'],
          'chapterNumber': m['chapter_number'],
          'chapterUrl': m['chapter_url'],
          'pos': m['pos'],
          'total': m['total'],
          'updatedMs': m['updated_ms'],
          'type': m['type'],
        });
      }
      _markPulled();
    } catch (_) {/* keep local — missing table / offline degrades silently */}
  }

  /// Pull from cloud only when the last successful pull is older than
  /// [maxAge] — see [WatchHistory.pullFromCloudIfStale]. Keeps app launches
  /// from re-downloading Continue Reading that's already cached locally.
  Future<void> pullFromCloudIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    if (_currentUserId() == null) return;
    int? last;
    if (Hive.isBoxOpen(syncMetaBox)) {
      last = Hive.box(syncMetaBox).get(_syncMetaKey) as int?;
    }
    if (last != null) {
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age >= 0 && age < maxAge.inMilliseconds) return; // still fresh
    }
    await pullFromCloud();
  }

  void _markPulled() {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(syncMetaBox)
          .put(_syncMetaKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Remove a single title from reading history, locally and (when signed in)
  /// from the cloud so it doesn't sync back — see [WatchHistory.remove].
  Future<void> remove(String sourceId, String showId) async {
    final key = _key(sourceId, showId);
    await _box.delete(key);
    _lastCloudPush.remove(key);
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      await _remote.deleteRow(uid, sourceId, showId);
    } catch (_) {/* best-effort */}
  }

  /// User-initiated "Clear history" for ONE kind (manga or novel): wipe those
  /// rows everywhere — local AND cloud — so a later pull can't restore them,
  /// while leaving the other kind untouched (both live in this one box/table).
  /// Deletes the cloud rows first so even a racing pull sees nothing.
  Future<void> clearType(ProviderType type) async {
    final uid = _currentUserId();
    if (uid != null) {
      try {
        await _remote.deleteAllForType(uid, type.name);
      } catch (_) {/* best-effort — local still clears */}
    }
    final keys = _box.keys.where((k) {
      final raw = _box.get(k);
      return raw != null && readEntryTypeFromName(raw['type'] as String?) == type;
    }).toList();
    for (final k in keys) {
      await _box.delete(k);
      _lastCloudPush.remove(k);
    }
  }

  /// Drop the local cache only — see [WatchHistory.clearLocal]. The cloud
  /// copy is the user's data and MUST survive, so this must never touch the
  /// cloud.
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
    }
  }
}
