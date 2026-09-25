import 'dart:async';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../di/injector.dart';
import '../tracker/tracker_item_url.dart';
import '../zmode/metadata_repository.dart';
import '../zmode/zmode_ids.dart';
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
    final res = await _service.client
        .from('mylist')
        .select()
        .eq('user_key', userKey);
    return (res as List).cast<Map<String, dynamic>>();
  }
}

/// My List, backed by Hive for instant local reads and synced to Supabase when
/// the user is signed in. The local box is the read source (so the UI stays
/// synchronous + offline-friendly); writes go through to Supabase best-effort.
class MyListStore {
  MyListStore(
    SupabaseService service,
    this._currentUserId, {
    MyListRemote? remote,
    String? Function(MediaItem)? statusOf,
    void Function(String key, String? statusName)? onStatusPulled,
  }) : _remote = remote ?? MyListRemote(service),
       _statusOf = statusOf,
       _onStatusPulled = onStatusPulled;

  final MyListRemote _remote;

  /// Returns the signed-in user id, or null when logged out. Injected so the
  /// store doesn't depend on the auth feature directly.
  final String? Function() _currentUserId;

  /// Reads an item's current local watch-status name (or null). Injected so
  /// the store can carry the status on its cloud row without importing the
  /// (deliberately local) status store. See [ListStatusStore].
  final String? Function(MediaItem)? _statusOf;

  /// Hydrates the local status store from a pulled cloud row's status. Injected
  /// for the same decoupling reason as [_statusOf].
  final void Function(String key, String? statusName)? _onStatusPulled;

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
      await openBoxSafely<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await openBoxSafely(syncMetaBox);
    }
    // An unreadable list box reopens EMPTY, but the pull throttle lives in
    // [syncMetaBox] and survives — so the next launch would see a fresh
    // timestamp, skip the pull, and leave the list empty for up to 12 hours
    // even though the cloud still has every item. Drop the timestamp so the
    // next [pullFromCloudIfStale] actually pulls.
    if (quarantinedBoxes.contains(boxName) && Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m) => hiveKey('${m.sourceId}::${m.id}');

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  List<MediaItem> all() =>
      _box.values.map(_itemFromHive).whereType<MediaItem>().toList();

  static const String _seedFlagPrefix = 'mylist_seeded_';

  /// Uploads local list items to the cloud under the CURRENT account,
  /// absent-only: an item is pushed only when the cloud doesn't already have it,
  /// so an existing cloud row (and its watch status) is never overwritten.
  /// Additive — deletes nothing. Seeds a fresh device / backfills a list
  /// orphaned by the Appwrite→Supabase move. Returns (pushed, failed): `failed`
  /// counts upserts that errored (or a cloud read that failed) so the caller can
  /// tell whether the push was complete.
  Future<({int pushed, int failed})> pushAllLocalToCloud() async {
    final uid = _currentUserId();
    if (uid == null) return (pushed: 0, failed: 0);
    final cloudKeys = <String>{};
    var readOk = true;
    try {
      for (final r in await _remote.listFor(uid)) {
        cloudKeys.add(hiveKey('${r['source_id']}::${r['item_id']}'));
      }
    } catch (_) {
      readOk = false;
    }
    var pushed = 0, failed = 0;
    for (final m in all()) {
      if (cloudKeys.contains(_key(m)))
        continue; // already in cloud — don't clobber
      try {
        await _remote.upsert(_cloudRow(uid, m));
        pushed++;
      } catch (_) {
        failed++;
      }
    }
    if (!readOk) failed++;
    return (pushed: pushed, failed: failed);
  }

  /// One-time-per-account backfill: push the local list up BEFORE the first
  /// (destructive) [pullFromCloud] can run, so a sparse/orphaned cloud can't
  /// wipe a device's local My List. Guarded by a per-account flag in
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

  /// Deserialise a stored [MediaItem]. Hive returns nested maps (here,
  /// `coverHeaders`) as `Map<dynamic, dynamic>` on a cold read from disk, but
  /// [MediaItem]'s generated `fromJson` casts `coverHeaders` to
  /// `Map<String, dynamic>` — which throws on that runtime type. That crash
  /// only surfaced AFTER an app restart (in-session, Hive returns the original
  /// in-memory object with types intact), and rendered My List as a blank grey
  /// error box. Normalise the nested map to string keys/values first so the
  /// read can never throw. `coverHeaders` is the only nested field on
  /// [MediaItem]; every other field is a scalar.
  ///
  /// Returns null for a record this build can't read, rather than throwing.
  /// Records outlive the schema that wrote them: a list saved by a build with
  /// extra `ProviderType` values (e.g. `manga`) decodes to an ArgumentError
  /// here, and because [all] maps over the whole box, one such row used to take
  /// down the entire screen and both directions of cloud sync with it. Skipping
  /// costs that one row; throwing costs the list.
  ///
  /// Deliberately NOT deleted — if a later build understands the value again,
  /// the row decodes and syncs as normal. Dropping it would be silent data loss.
  static MediaItem? _itemFromHive(Map raw) {
    try {
      final m = Map<String, dynamic>.from(raw);
      final h = m['coverHeaders'];
      if (h is Map) {
        m['coverHeaders'] = h.map((k, v) => MapEntry('$k', '$v'));
      }
      return MediaItem.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  /// Ensure [m] is in the list (no-op if already present). Used by the status
  /// sheet, where picking any status implies membership.
  Future<void> add(MediaItem m) async {
    if (_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  /// Records which catalogue a metadata title came from, once, on the way in.
  ///
  /// Done here rather than at the four call sites that add to the list, so no
  /// path can forget. A saved title then keeps its origin: change the Settings
  /// provider later and the list still opens each entry where it came from.
  /// Source titles are left alone — [MediaItem.sourceId] already names theirs.
  MediaItem _stamped(MediaItem m) {
    // The date goes on everything, including source titles: "recently added"
    // has to mean something for those too.
    var out = m.savedAtMs != null
        ? m
        : m.copyWith(savedAtMs: DateTime.now().millisecondsSinceEpoch);
    if (out.savedFrom != null || out.sourceId != ZmodeIds.sourceId) return out;
    final c = ZmodeIds.parseShow(out.url);
    if (c == null) return out;
    final name = sl.isRegistered<MetadataRepository>()
        ? sl<MetadataRepository>().nameForKind(c.kind)
        : null;
    return name == null ? out : out.copyWith(savedFrom: name);
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
      await _box.put(k, _stamped(m).toJson());
    } else {
      await _box.delete(k);
    }
    revision.value++;
    final uid = _currentUserId();
    if (uid == null) {
      AppLogger.instance.log(
        'mylist cloud ${adding ? "add" : "remove"} skipped: no session',
        level: 'W',
      );
      if (adding) {
        _markPending(k);
      } else {
        _markPendingDelete(m.sourceId, m.id);
      }
      return;
    }
    try {
      if (adding) {
        await _remote.upsert(_cloudRow(uid, m));
        _clearPendingDelete(m.sourceId, m.id);
      } else {
        await _remote.deleteRow(uid, m.sourceId, m.id);
        _clearPendingDelete(m.sourceId, m.id);
      }
      _clearPending(k); // synced — nothing to retry
    } catch (e) {
      // Cloud write failed (offline, or the backend is unreachable). The
      // local box already reflects the change; remember the unsynced write
      // so [retryPending] pushes it up once writes are available again.
      AppLogger.instance.log(
        'mylist cloud ${adding ? "add" : "remove"} failed: $e',
        level: 'E',
      );
      if (adding) {
        _markPending(k);
      } else {
        _markPendingDelete(m.sourceId, m.id);
      }
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
    // Watch status (Watching/Completed/…) rides on the same row so it survives
    // reinstalls + syncs across devices. Null when the item has no status. Every
    // upsert carries the CURRENT local status so a re-sync never wipes it.
    'status': _statusOf?.call(m),
    'added_at': DateTime.now().millisecondsSinceEpoch,
  };

  /// Best-effort push of [m]'s current local watch status to its cloud row.
  /// Called after the user changes a status (the row already exists locally, so
  /// this just re-upserts it carrying the new status). Silent on failure — the
  /// next full sync re-sends it.
  Future<void> pushStatus(MediaItem m) async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      await _remote.upsert(_cloudRow(uid, m));
    } catch (_) {
      /* best-effort */
    }
  }

  // ── pending-sync retry queue ───────────────────────────────────────────────
  // Keys of local adds whose cloud write failed (offline / quota). Persisted in
  // [syncMetaBox] so they survive restarts and self-heal via [retryPending].
  static const String _pendingKey = 'mylist_pending';
  static const String _pendingDeleteKey = 'mylist_pending_delete';

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

  /// `sourceId::itemId` pairs whose cloud DELETE failed. A later pull must
  /// not resurrect them, and [retryPending] re-sends the delete.
  Set<String> pendingDeleteKeys() {
    if (!Hive.isBoxOpen(syncMetaBox)) return <String>{};
    final raw = Hive.box(syncMetaBox).get(_pendingDeleteKey);
    return raw is List ? raw.map((e) => '$e').toSet() : <String>{};
  }

  String _deleteKey(String sourceId, String itemId) => '$sourceId::$itemId';

  void _markPendingDelete(String sourceId, String itemId) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final s = pendingDeleteKeys()..add(_deleteKey(sourceId, itemId));
    Hive.box(syncMetaBox).put(_pendingDeleteKey, s.toList());
  }

  void _clearPendingDelete(String sourceId, String itemId) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final s = pendingDeleteKeys();
    if (s.remove(_deleteKey(sourceId, itemId))) {
      Hive.box(syncMetaBox).put(_pendingDeleteKey, s.toList());
    }
  }

  /// Push up any local adds that never reached the cloud (a past write outage),
  /// so they self-heal once writes are available. Only touches items that
  /// actually failed — items that synced normally are never in the queue, so in
  /// steady state this makes ZERO writes.
  Future<void> retryPending() async {
    final uid = _currentUserId();
    if (uid == null) return;
    final pending = pendingKeys();
    final pendingDeletes = pendingDeleteKeys();
    if (pending.isEmpty && pendingDeletes.isEmpty) return;
    for (final raw in pendingDeletes) {
      final split = raw.indexOf('::');
      if (split <= 0) {
        _clearPendingDelete(raw, '');
        continue;
      }
      final sourceId = raw.substring(0, split);
      final itemId = raw.substring(split + 2);
      try {
        await _remote.deleteRow(uid, sourceId, itemId);
        _clearPendingDelete(sourceId, itemId);
      } catch (_) {
        /* keep pending, retry next launch */
      }
    }
    for (final k in pending) {
      final raw = _box.get(k);
      if (raw == null) {
        _clearPending(k); // removed locally since — nothing to sync
        continue;
      }
      final m = _itemFromHive(raw);
      // Unreadable on this build — can't build a cloud row for it. Left pending
      // rather than cleared, so it still syncs if a later build can decode it.
      if (m == null) continue;
      try {
        await _remote.upsert(_cloudRow(uid, m));
        _clearPending(k);
      } catch (_) {
        /* keep pending, retry next launch */
      }
    }
  }

  /// Merge the signed-in user's cloud list into the local cache.
  ///
  /// Cloud rows are added/refreshed and their watch status hydrated. After the
  /// one-time [seedCloudIfNeeded] backfill, the cloud is treated as the
  /// membership source of truth: a title deleted on another device is dropped
  /// here. Unsynced local adds (the pending queue) and a pull that happens
  /// *before* seed still keep local-only rows, so an empty/orphaned cloud
  /// cannot wipe a device that has never successfully pushed.
  Future<void> pullFromCloud() async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      final rows = await _remote.listFor(uid);
      final doomed = pendingDeleteKeys();
      for (final row in rows) {
        final headers = row['cover_headers'];
        // A row this build can't decode (e.g. a `manga` type saved by a build
        // that had it) must skip, not abort — throwing here stopped the pull
        // dead and every later row went unmerged.
        MediaItem item;
        try {
          item = MediaItem.fromJson({
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
        } catch (_) {
          continue;
        }
        // A local remove whose cloud DELETE failed must not come back.
        if (doomed.contains('${item.sourceId}::${item.id}')) continue;
        // Cloud rows don't store mal/tmdb ids; put them back from the zm url
        // so a later tracker write (remove/scrobble) has something to send.
        final ids = trackerIdsFromItem(item);
        item = item.copyWith(
          malId: ids.malId,
          anilistId: ids.anilistId,
          tmdbId: ids.tmdbId,
        );
        final key = hiveKey('${item.sourceId}::${item.id}');
        await _box.put(key, item.toJson());
        _clearPending(key); // it's in the cloud now — no longer needs retrying
        // Watch status: hydrate the local mirror from the cloud when the cloud
        // knows one; otherwise back-fill the cloud from a local status set
        // before status-sync existed. Never CLEAR a local status just because
        // the cloud hasn't heard about it yet (cloudStatus == null).
        final cloudStatus = row['status'] as String?;
        if (cloudStatus != null) {
          _onStatusPulled?.call(key, cloudStatus);
        } else if (_statusOf?.call(item) != null) {
          unawaited(pushStatus(item));
        }
      }
      if (_seededFor(uid)) {
        final cloudKeys = <String>{
          for (final row in rows)
            hiveKey('${row['source_id']}::${row['item_id']}'),
        };
        final pending = pendingKeys();
        for (final raw in _box.keys.toList()) {
          final key = '$raw';
          if (cloudKeys.contains(key) || pending.contains(key)) continue;
          await _box.delete(key);
          _onStatusPulled?.call(key, null);
        }
      }
      revision.value++;
      _markPulled();
    } catch (_) {
      /* keep whatever is local */
    }
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

  bool _seededFor(String uid) {
    if (!Hive.isBoxOpen(syncMetaBox)) return false;
    return Hive.box(syncMetaBox).get('$_seedFlagPrefix$uid') == true;
  }

  void _markPulled() {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(
        syncMetaBox,
      ).put(_syncMetaKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Wipe the local cache (on logout).
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(syncMetaBox).delete(_syncMetaKey);
      await Hive.box(syncMetaBox).delete(_pendingKey);
      await Hive.box(syncMetaBox).delete(_pendingDeleteKey);
    }
    revision.value++;
  }
}
