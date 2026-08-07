import 'dart:convert';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:hive/hive.dart';

import '../privacy/incognito_mode.dart';
import '../supabase/supabase_service.dart';

class HistoryEntry {
  HistoryEntry({
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    this.cover,
    this.coverHeaders,
    this.thumbnail,
    required this.showUrl,
    required this.category,
    required this.episodeId,
    required this.episodeNumber,
    required this.episodeUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.malId,
  });
  final String sourceId,
      showId,
      showTitle,
      showUrl,
      category,
      episodeId,
      episodeUrl;
  final String? cover;
  final Map<String, String>? coverHeaders;

  /// Landscape episode thumbnail (16:9) for the Continue Watching card. Local
  /// only (not cloud-synced) — a resumed entry from another device falls back
  /// to [cover]. Null for older entries and sources without episode thumbnails.
  final String? thumbnail;
  final double? episodeNumber;

  /// MyAnimeList id (anime), carried so a resume from Continue Watching can
  /// still auto-scrobble to AniList.
  final int? malId;
  final Duration position, duration;
  final int updatedAt;
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

/// Thin transport seam over the `history` Supabase table, injectable so
/// [WatchHistory]'s throttle/flush logic is unit-testable without a live
/// Supabase project.
class HistoryRemote {
  HistoryRemote(this._service);

  final SupabaseService _service;

  Future<void> upsert(Map<String, dynamic> row) async {
    await _service.client
        .from('history')
        .upsert(row, onConflict: 'user_key,source_id,show_id');
  }

  Future<void> deleteRow(String userKey, String sourceId, String showId) async {
    await _service.client.from('history').delete().match({
      'user_key': userKey,
      'source_id': sourceId,
      'show_id': showId,
    });
  }

  /// Delete EVERY history row for [userKey] — used by "Clear history" so it
  /// can't sync back on the next pull.
  Future<void> deleteAllFor(String userKey) async {
    await _service.client.from('history').delete().eq('user_key', userKey);
  }

  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    final res =
        await _service.client.from('history').select().eq('user_key', userKey);
    return (res as List).cast<Map<String, dynamic>>();
  }
}

/// Continue Watching, backed by Hive for instant local reads and synced to
/// Supabase when signed in. Cloud writes are throttled per show (the player
/// persists every ~5s) so we don't hammer the backend.
class WatchHistory {
  WatchHistory(SupabaseService service, this._currentUserId, {HistoryRemote? remote})
      : _remote = remote ?? HistoryRemote(service);

  final HistoryRemote _remote;
  final String? Function() _currentUserId;

  static const String boxName = 'watch_history';
  // Cloud progress-sync throttle. The player calls [save] every ~1s during
  // playback, but each of those was a cloud write every 15s per show — ~96
  // writes for one 24-min episode, which blows through free-tier database
  // write quotas fast. Local saves stay instant (resume is unaffected); the
  // CLOUD push is throttled to 2 min, and forced on pause/stop/episode
  // change/close (see [save]'s `flush`) so the resume point stays accurate.
  static const int _cloudThrottleMs = 120000;

  /// Shared box holding the last successful cloud-pull timestamp (see
  /// [MyListStore.syncMetaBox]) so app-launch pulls can be throttled.
  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'history_lastPullMs';

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
  /// the cloud push is throttled unless [flush] is true, which forces it on the
  /// moments that matter for an accurate cross-device resume — pause, stop,
  /// episode change, and player close.
  Future<void> save(HistoryEntry e, {bool flush = false}) async {
    if (IncognitoMode.on) return; // incognito: don't record what's watched
    final key = _key(e.sourceId, e.showId);
    await _box.put(key, {
      'sourceId': e.sourceId,
      'showId': e.showId,
      'showTitle': e.showTitle,
      'cover': e.cover,
      'coverHeaders': e.coverHeaders,
      'thumbnail': e.thumbnail,
      'showUrl': e.showUrl,
      'category': e.category,
      'episodeId': e.episodeId,
      'episodeNumber': e.episodeNumber,
      'episodeUrl': e.episodeUrl,
      'positionMs': e.position.inMilliseconds,
      'durationMs': e.duration.inMilliseconds,
      'updatedAt': e.updatedAt,
      'malId': e.malId,
    });
    if (flush) {
      await _pushToCloud(key, e, force: true);
    } else {
      _pushToCloud(key, e);
    }
  }

  /// Throttled, best-effort cloud upsert. [force] bypasses the throttle for
  /// the flush moments (see [save]).
  Map<String, dynamic> _rowFor(String uid, HistoryEntry e) => {
    'user_key': uid,
    'source_id': e.sourceId,
    'show_id': e.showId,
    'show_title': e.showTitle,
    'cover': e.cover,
    'cover_headers': e.coverHeaders,
    'show_url': e.showUrl,
    'category': e.category,
    'episode_id': e.episodeId,
    'episode_number': e.episodeNumber,
    'episode_url': e.episodeUrl,
    'position_ms': e.position.inMilliseconds,
    'duration_ms': e.duration.inMilliseconds,
    'updated_at': e.updatedAt,
    'mal_id': e.malId?.toString(),
  };

  Future<void> _pushToCloud(String key, HistoryEntry e, {bool force = false}) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastCloudPush[key] ?? 0;
    if (!force && now - last < _cloudThrottleMs) return;
    _lastCloudPush[key] = now;
    try {
      await _remote.upsert(_rowFor(uid, e));
    } catch (_) {/* best-effort */}
  }

  HistoryEntry _fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return HistoryEntry(
      sourceId: m['sourceId'] as String,
      showId: m['showId'] as String,
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      thumbnail: m['thumbnail'] as String?,
      showUrl: m['showUrl'] as String? ?? '',
      category: m['category'] as String? ?? 'sub',
      episodeId: m['episodeId'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeUrl: m['episodeUrl'] as String? ?? '',
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      malId: (m['malId'] as num?)?.toInt(),
    );
  }

  /// Newest-first, excluding finished episodes (the Continue Watching feed).
  List<HistoryEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }

  /// Every watched show, newest-first, including finished ones — the full
  /// History screen (Continue Watching only surfaces the unfinished subset).
  List<HistoryEntry> all() {
    return _box.values.map(_fromMap).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static const String _seedFlagPrefix = 'history_seeded_';

  /// Uploads local history to the cloud under the CURRENT account, newest-wins:
  /// a row is pushed only when the cloud lacks it or the local copy is newer, so
  /// this can never regress progress that another device saved more recently.
  /// Additive — deletes nothing. Used to seed a fresh device or backfill a
  /// library orphaned by the Appwrite→Supabase move (rows kept their old id, so
  /// a new login couldn't read them). Returns (pushed, failed): `failed` counts
  /// upserts that errored (or a cloud read that failed), so the caller can tell
  /// whether the push was complete.
  Future<({int pushed, int failed})> pushAllLocalToCloud() async {
    final uid = _currentUserId();
    if (uid == null) return (pushed: 0, failed: 0);
    // What the cloud already has, and how fresh — so we don't clobber newer.
    final cloudTimes = <String, int>{};
    var readOk = true;
    try {
      for (final m in await _remote.listFor(uid)) {
        cloudTimes['${m['source_id']}::${m['show_id']}'] =
            (m['updated_at'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      readOk = false; // couldn't read cloud — treat as incomplete below
    }
    var pushed = 0, failed = 0;
    for (final e in all()) {
      final key = _key(e.sourceId, e.showId);
      final cloudT = cloudTimes[key];
      if (cloudT != null && cloudT >= e.updatedAt) continue; // cloud same/newer
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

  /// One-time-per-account backfill: push the local history up BEFORE the first
  /// (destructive) [pullFromCloud] can run, so a sparse/orphaned cloud can't
  /// wipe a device's local Continue Watching. Guarded by a per-account flag in
  /// [syncMetaBox]; the flag is only set once a push completes with no failures,
  /// so an offline attempt retries next launch. No-op after it succeeds once.
  Future<void> seedCloudIfNeeded() async {
    final uid = _currentUserId();
    if (uid == null || !Hive.isBoxOpen(syncMetaBox)) return;
    final box = Hive.box(syncMetaBox);
    final flag = '$_seedFlagPrefix$uid';
    if (box.get(flag) == true) return;
    final r = await pushAllLocalToCloud();
    if (r.failed == 0) await box.put(flag, true);
  }

  /// Merge the signed-in user's cloud history into the local cache, newest-wins.
  /// NON-destructive by design: a local-only row (not yet pushed to the cloud) is
  /// kept, and a cloud row only overwrites a local one when it's strictly newer.
  /// This is deliberately a MERGE, not a replace — an empty/sparse cloud (a fresh
  /// device, a not-yet-seeded library, a session that goes live mid-boot) must
  /// NEVER be able to wipe a device's Continue Watching. Deletions propagate
  /// through [remove]/[clearAll] deleting the cloud row directly, not through a
  /// pull observing an absence.
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final rows = await _remote.listFor(uid);
      for (final m in rows) {
        final key = '${m['source_id']}::${m['show_id']}';
        final cloudUpdated = (m['updated_at'] as num?)?.toInt() ?? 0;
        final localUpdated = (_box.get(key)?['updatedAt'] as num?)?.toInt() ?? -1;
        if (cloudUpdated <= localUpdated) continue; // local is same/newer — keep it
        final headers = m['cover_headers'];
        await _box.put(key, {
          'sourceId': m['source_id'],
          'showId': m['show_id'],
          'showTitle': m['show_title'],
          'cover': m['cover'],
          'coverHeaders': headers is String
              ? jsonDecode(headers)
              : headers is Map
                  ? headers
                  : null,
          'showUrl': m['show_url'],
          'category': m['category'],
          'episodeId': m['episode_id'],
          'episodeNumber': m['episode_number'],
          'episodeUrl': m['episode_url'],
          'positionMs': m['position_ms'],
          'durationMs': m['duration_ms'],
          'updatedAt': m['updated_at'],
          'malId': int.tryParse('${m['mal_id']}'),
        });
      }
      _markPulled();
    } catch (_) {/* keep local */}
  }

  /// Remove a single show from Continue Watching, locally and (when signed in)
  /// from the cloud so it doesn't sync back. Best-effort on the cloud side.
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

  /// Pull from cloud only when the last successful pull is older than [maxAge]
  /// — see [MyListStore.pullFromCloudIfStale]. Keeps app launches from
  /// re-downloading Continue Watching that's already cached locally.
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

  /// Drop the local cache only. Used on LOGOUT — the cloud copy is the user's
  /// data and MUST survive, so this must never touch the cloud.
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
    }
  }

  /// User-initiated "Clear history": wipe Continue Watching EVERYWHERE — local
  /// AND the cloud — so a later pull can't restore it. (This is the difference
  /// from [clearLocal], which deliberately keeps the cloud copy on logout.)
  /// Deletes the cloud rows first so even a racing pull sees nothing.
  Future<void> clearAll() async {
    final uid = _currentUserId();
    if (uid != null) {
      try {
        await _remote.deleteAllFor(uid);
      } catch (_) {/* best-effort — local still clears */}
    }
    _lastCloudPush.clear();
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
    }
  }
}
