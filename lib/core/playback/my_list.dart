import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../logging/app_logger.dart';
import '../models/media_item.dart';
import '../supabase/supabase_service.dart';

/// Thin transport seam over the `mylist` Supabase table, injectable so
/// [MyListStore]'s pending-queue/pull-merge logic is unit-testable without a
/// live Supabase project.
class MyListRemote {
  MyListRemote(this._service);

  final SupabaseService _service;

  Future<void> upsert(Map<String, dynamic> row) async {
    await _service.client.from('mylist').upsert(row);
  }

  Future<void> deleteRow(String userKey, String sourceId, String itemId) async {
    await _service.client.from('mylist').delete().match({
      'user_key': userKey,
      'source_id': sourceId,
      'item_id': itemId,
    });
  }

  Future<List<Map<String, dynamic>>> listFor(String userKey) async {
    final res =
        await _service.client.from('mylist').select().eq('user_key', userKey);
    return (res as List).cast<Map<String, dynamic>>();
  }
}

/// My List, backed by Hive for instant local reads and synced to Supabase when
/// the user is signed in. The local box is the read source (so the UI stays
/// synchronous + offline-friendly); writes go through to Supabase best-effort.
class MyListStore {
  MyListStore(SupabaseService service, this._currentUserId, {MyListRemote? remote})
      : _remote = remote ?? MyListRemote(service);

  final MyListRemote _remote;

  /// Returns the signed-in user id, or null when logged out. Injected so the
  /// store doesn't depend on the auth feature directly.
  final String? Function() _currentUserId;

  /// Bumped whenever the contents change (toggle / cloud pull / clear) so
  /// listeners like MyListCubit can refresh — needed because a cloud pull
  /// lands asynchronously after login.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const String boxName = 'my_list';

  /// Shared box holding the last successful cloud-pull timestamp per store, so
  /// app-launch pulls can be throttled — the full list is already in the local
  /// cache and our own writes push to cloud immediately. Kept OUT of [boxName]
  /// so it never appears in [all]'s value iteration.
  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'mylist_lastPullMs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await Hive.openBox(syncMetaBox);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m) => '${m.sourceId}::${m.id}';

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  List<MediaItem> all() => _box.values
      .map((raw) => MediaItem.fromJson(Map<String, dynamic>.from(raw)))
      .toList();

  /// Ensure [m] is in the list (no-op if already present). Used by the status
  /// sheet, where picking any status implies membership.
  Future<void> add(MediaItem m) async {
    if (_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  /// Remove [m] from the list (no-op if absent).
  Future<void> remove(MediaItem m) async {
    if (!_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  Future<void> toggle(MediaItem m) async {
    final k = _key(m);
    final adding = !_box.containsKey(k);
    if (adding) {
      await _box.put(k, m.toJson());
    } else {
      await _box.delete(k);
    }
    revision.value++;
    final uid = _currentUserId();
    if (uid == null) return; // gated by the UI, but guard anyway
    try {
      if (adding) {
        await _remote.upsert(_cloudRow(uid, m));
      } else {
        await _remote.deleteRow(uid, m.sourceId, m.id);
      }
      _clearPending(k); // synced — nothing to retry
    } catch (e) {
      // Cloud write failed (offline, or the backend is unreachable). The
      // local box already reflects the change; remember an un-synced ADD so
      // [retryPending] pushes it up once writes are available again. A
      // removed item no longer needs syncing.
      AppLogger.instance.log('mylist cloud ${adding ? "add" : "remove"} failed: $e',
          level: 'E');
      if (adding) _markPending(k);
    }
  }

  Map<String, dynamic> _cloudRow(String uid, MediaItem m) => {
    'user_key': uid,
    'item_id': m.id,
    'source_id': m.sourceId,
    'title': m.title,
    'cover': m.cover,
    'cover_headers': m.coverHeaders,
    'url': m.url,
    'type': m.type.name,
    'added_at': DateTime.now().millisecondsSinceEpoch,
  };

  // ── pending-sync retry queue ───────────────────────────────────────────────
  // Keys of local adds whose cloud write failed (offline / quota). Persisted in
  // [syncMetaBox] so they survive restarts and self-heal via [retryPending].
  static const String _pendingKey = 'mylist_pending';

  Set<String> pendingKeys() {
    if (!Hive.isBoxOpen(syncMetaBox)) return <String>{};
    final raw = Hive.box(syncMetaBox).get(_pendingKey);
    return raw is List ? raw.map((e) => '$e').toSet() : <String>{};
  }

  void _markPending(String k) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final s = pendingKeys()..add(k);
    Hive.box(syncMetaBox).put(_pendingKey, s.toList());
  }

  void _clearPending(String k) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final s = pendingKeys();
    if (s.remove(k)) Hive.box(syncMetaBox).put(_pendingKey, s.toList());
  }

  /// Push up any local adds that never reached the cloud (a past write outage),
  /// so they self-heal once writes are available. Only touches items that
  /// actually failed — items that synced normally are never in the queue, so in
  /// steady state this makes ZERO writes.
  Future<void> retryPending() async {
    final uid = _currentUserId();
    if (uid == null) return;
    final pending = pendingKeys();
    if (pending.isEmpty) return;
    for (final k in pending) {
      final raw = _box.get(k);
      if (raw == null) {
        _clearPending(k); // removed locally since — nothing to sync
        continue;
      }
      final m = MediaItem.fromJson(Map<String, dynamic>.from(raw));
      try {
        await _remote.upsert(_cloudRow(uid, m));
        _clearPending(k);
      } catch (_) {/* keep pending, retry next launch */}
    }
  }

  /// Replace the local cache with the signed-in user's cloud list. Called on
  /// login. No-op when logged out.
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final rows = await _remote.listFor(uid);
      // Preserve local adds still awaiting a cloud write, so replacing the box
      // with the cloud list can't wipe an item that failed to sync.
      final pending = pendingKeys();
      final preserved = <String, Map>{
        for (final k in pending)
          if (_box.get(k) != null) k: Map.from(_box.get(k)!),
      };
      await _box.clear();
      final cloudKeys = <String>{};
      for (final row in rows) {
        final headers = row['cover_headers'];
        final item = MediaItem.fromJson({
          'id': row['item_id'],
          'title': row['title'],
          'cover': row['cover'],
          'coverHeaders': headers is String
              ? jsonDecode(headers)
              : headers is Map
                  ? headers
                  : null,
          'url': row['url'],
          'type': row['type'],
          'sourceId': row['source_id'],
        });
        final key = '${item.sourceId}::${item.id}';
        await _box.put(key, item.toJson());
        cloudKeys.add(key);
      }
      // A pending item that DID reach the cloud is no longer pending; the rest
      // are re-added locally so they survive the pull and stay queued.
      for (final k in pending) {
        if (cloudKeys.contains(k)) {
          _clearPending(k);
        } else if (preserved.containsKey(k)) {
          await _box.put(k, preserved[k]!);
        }
      }
      revision.value++;
      _markPulled();
    } catch (_) {/* keep whatever is local */}
  }

  /// Pull from cloud only when the last successful pull is older than [maxAge].
  /// Used on app launch (restoring a session) so the whole list isn't
  /// re-downloaded on every cold start — it's already in the local Hive cache,
  /// and our own writes push to cloud immediately. Login + pull-to-refresh call
  /// [pullFromCloud] directly to force a fresh sync.
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

  /// Wipe the local cache (on logout).
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
      await Hive.box(syncMetaBox).delete(_pendingKey);
    }
    revision.value++;
  }
}
