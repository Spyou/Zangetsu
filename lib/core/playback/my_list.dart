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
import '../profiles/profile_scope.dart';

/// Thin transport seam over the `mylist` Supabase table, injectable so
/// [MyListStore]'s pending-queue/pull-merge logic is unit-testable without a
/// live Supabase project.
class MyListRemote {
  MyListRemote(this._service);

  final SupabaseService _service;
  static const int _pageSize = 500;
  static const String _listColumns =
      'sync_id,sync_version,source_id,item_id,title,cover,cover_headers,url,type,status,added_at';

  Future<void> upsert(Map<String, dynamic> row) async {
    final profileId = row['profile_id'] as String?;
    final table = profileId == null ? 'mylist' : 'profile_mylist';
    await _service.client.from(table).upsert(row);
  }

  Future<void> deleteRow(
    String userKey,
    String sourceId,
    String itemId, {
    String? profileId,
  }) async {
    final table = profileId == null ? 'mylist' : 'profile_mylist';
    final filters = <String, Object>{
      'user_key': userKey,
      'source_id': sourceId,
      'item_id': itemId,
    };
    if (profileId != null) filters['profile_id'] = profileId;
    await _service.client.from(table).delete().match(filters);
  }

  Future<List<Map<String, dynamic>>> listFor(
    String userKey, {
    String? profileId,
  }) async {
    final table = profileId == null ? 'mylist' : 'profile_mylist';
    var query = _service.client
        .from(table)
        .select('sync_id')
        .eq('user_key', userKey);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final head = await query.order('sync_id', ascending: false).limit(1);
    final throughSyncId = (head as List).isEmpty
        ? 0
        : ((head.first['sync_id'] as num?)?.toInt() ?? 0);
    return _listPages(
      userKey,
      profileId: profileId,
      throughSyncId: throughSyncId,
    );
  }

  Future<int> currentVersion(String userKey, {String? profileId}) async {
    final row = await _service.client
        .from('mylist_sync_clock')
        .select('version')
        .eq('user_key', userKey)
        .eq('profile_scope', profileId ?? '')
        .maybeSingle();
    return (row?['version'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> changesFor(
    String userKey, {
    String? profileId,
    required int afterVersion,
    required int throughVersion,
  }) async {
    if (throughVersion <= afterVersion) return const [];
    final table = profileId == null ? 'mylist' : 'profile_mylist';
    final changedRows = await _versionedRows(
      table,
      userKey,
      profileId: profileId,
      afterVersion: afterVersion,
      throughVersion: throughVersion,
    );
    final removedRows = await _tombstones(
      userKey,
      profileId: profileId,
      afterVersion: afterVersion,
      throughVersion: throughVersion,
    );
    return [
      for (final row in changedRows)
        {'sync_version': row['sync_version'], 'deleted': false, 'row': row},
      for (final row in removedRows) {...row, 'deleted': true},
    ]..sort(
      (a, b) => (a['sync_version'] as num).compareTo(b['sync_version'] as num),
    );
  }

  Future<Set<String>> deletedKeysFor(
    String userKey, {
    String? profileId,
  }) async {
    final version = await currentVersion(userKey, profileId: profileId);
    return {
      for (final row in await _tombstones(
        userKey,
        profileId: profileId,
        afterVersion: 0,
        throughVersion: version,
      ))
        '${row['source_id']}::${row['item_id']}',
    };
  }

  Future<List<Map<String, dynamic>>> _listPages(
    String userKey, {
    String? profileId,
    required int throughSyncId,
  }) async {
    final table = profileId == null ? 'mylist' : 'profile_mylist';
    final rows = <Map<String, dynamic>>[];
    var afterSyncId = 0;
    while (true) {
      var query = _service.client
          .from(table)
          .select(_listColumns)
          .eq('user_key', userKey);
      if (profileId != null) query = query.eq('profile_id', profileId);
      final page =
          (await query
                      .gt('sync_id', afterSyncId)
                      .lte('sync_id', throughSyncId)
                      .order('sync_id')
                      .limit(_pageSize)
                  as List)
              .cast<Map<String, dynamic>>();
      if (page.isEmpty) break;
      rows.addAll(page);
      afterSyncId = (page.last['sync_id'] as num).toInt();
      if (page.length < _pageSize) break;
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _versionedRows(
    String table,
    String userKey, {
    String? profileId,
    required int afterVersion,
    required int throughVersion,
  }) async {
    final rows = <Map<String, dynamic>>[];
    var after = afterVersion;
    while (true) {
      var query = _service.client
          .from(table)
          .select(_listColumns)
          .eq('user_key', userKey);
      if (profileId != null) query = query.eq('profile_id', profileId);
      final page =
          (await query
                      .gt('sync_version', after)
                      .lte('sync_version', throughVersion)
                      .order('sync_version')
                      .limit(_pageSize)
                  as List)
              .cast<Map<String, dynamic>>();
      if (page.isEmpty) break;
      rows.addAll(page);
      after = (page.last['sync_version'] as num).toInt();
      if (page.length < _pageSize) break;
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _tombstones(
    String userKey, {
    String? profileId,
    required int afterVersion,
    required int throughVersion,
  }) async {
    final rows = <Map<String, dynamic>>[];
    var after = afterVersion;
    while (true) {
      final page =
          (await _service.client
                      .from('mylist_sync_tombstones')
                      .select('source_id,item_id,sync_version')
                      .eq('user_key', userKey)
                      .eq('profile_scope', profileId ?? '')
                      .gt('sync_version', after)
                      .lte('sync_version', throughVersion)
                      .order('sync_version')
                      .limit(_pageSize)
                  as List)
              .cast<Map<String, dynamic>>();
      if (page.isEmpty) break;
      rows.addAll(page);
      after = (page.last['sync_version'] as num).toInt();
      if (page.length < _pageSize) break;
    }
    return rows;
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
    String? Function()? currentProfileId,
  }) : _remote = remote ?? MyListRemote(service),
       _statusOf = statusOf,
       _onStatusPulled = onStatusPulled,
       _currentProfileId = currentProfileId;

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
  final String? Function()? _currentProfileId;
  String get _profileId => _currentProfileId?.call() ?? kDefaultProfileId;
  String? _remoteProfileId(String id) => id == kDefaultProfileId ? null : id;

  /// Bumped whenever the contents change (toggle / cloud pull / clear) so
  /// listeners like MyListCubit can refresh — needed because a cloud pull
  /// lands asynchronously after login.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const String boxName = 'my_list';

  /// Shared box holding pull timestamps and server cursors per account/profile, so
  /// app-launch pulls can be throttled — the full list is already in the local
  /// cache and our own writes push to cloud immediately. Kept OUT of [boxName]
  /// so it never appears in [all]'s value iteration.
  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'mylist_lastPullMs';
  static const String _syncCursorPrefix = 'mylist_sync_cursor';

  static bool _isMyListSyncMetaKey(String key) =>
      key.contains(_syncMetaKey) || key.contains(_syncCursorPrefix);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await openBoxSafely(syncMetaBox);
    }
    // An unreadable list box reopens EMPTY, but the pull throttle lives in
    // [syncMetaBox] and survives — so the next launch would see a fresh
    // timestamp, skip the pull, and leave the list empty until the next stale pull
    // even though the cloud still has every item. Drop the timestamp so the
    // next [pullFromCloudIfStale] actually pulls.
    if (quarantinedBoxes.contains(boxName) && Hive.isBoxOpen(syncMetaBox)) {
      final meta = Hive.box(syncMetaBox);
      for (final key in meta.keys.toList()) {
        final value = '$key';
        if (_isMyListSyncMetaKey(value)) {
          await meta.delete(key);
        }
      }
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m, [String? profileId]) => profileScopedKey(
    profileId ?? _profileId,
    hiveKey('${m.sourceId}::${m.id}'),
  );

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  List<MediaItem> all() => _allFor(_profileId);

  List<MediaItem> _allFor(String id) {
    return [
      for (final key in _box.keys)
        if (profileOwnsKey(key, id)) _box.get(key),
    ].whereType<Map>().map(_itemFromHive).whereType<MediaItem>().toList();
  }

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
    final profileId = _profileId;
    final cloudKeys = <String>{};
    final deletedKeys = <String>{};
    var readOk = true;
    try {
      for (final r in await _remote.listFor(
        uid,
        profileId: _remoteProfileId(profileId),
      )) {
        cloudKeys.add(_keyFromIds(r['source_id'], r['item_id'], profileId));
      }
      deletedKeys.addAll(
        await _remote.deletedKeysFor(
          uid,
          profileId: _remoteProfileId(profileId),
        ),
      );
    } catch (_) {
      readOk = false;
    }
    if (!readOk) return (pushed: 0, failed: 1);
    var pushed = 0, failed = 0;
    for (final m in _allFor(profileId)) {
      final key = _key(m, profileId);
      if (cloudKeys.contains(key)) continue; // already in cloud — don't clobber
      if (deletedKeys.contains(_deleteKey(m.sourceId, m.id)) &&
          !pendingKeys(profileId).contains(key)) {
        continue; // don't resurrect a cloud delete from a stale local cache
      }
      try {
        await _remote.upsert(_cloudRow(uid, m, profileId));
        pushed++;
      } catch (_) {
        failed++;
      }
    }
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
    final profileId = _profileId;
    final flag = profileScopedKey(profileId, '$_seedFlagPrefix$uid');
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
    final profileId = _profileId;
    final k = _key(m, profileId);
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
        _markPending(k, profileId);
      } else {
        _markPendingDelete(m.sourceId, m.id, profileId);
      }
      return;
    }
    try {
      if (adding) {
        await _remote.upsert(_cloudRow(uid, m, profileId));
        _clearPendingDelete(m.sourceId, m.id, profileId);
      } else {
        await _remote.deleteRow(
          uid,
          m.sourceId,
          m.id,
          profileId: _remoteProfileId(profileId),
        );
        _clearPendingDelete(m.sourceId, m.id, profileId);
      }
      _clearPending(k, profileId); // synced — nothing to retry
    } catch (e) {
      // Cloud write failed (offline, or the backend is unreachable). The
      // local box already reflects the change; remember the unsynced write
      // so [retryPending] pushes it up once writes are available again.
      AppLogger.instance.log(
        'mylist cloud ${adding ? "add" : "remove"} failed: $e',
        level: 'E',
      );
      if (adding) {
        _markPending(k, profileId);
      } else {
        _markPendingDelete(m.sourceId, m.id, profileId);
      }
    }
  }

  Map<String, dynamic> _cloudRow(String uid, MediaItem m, String profileId) => {
    'user_key': uid,
    if (profileId != kDefaultProfileId) 'profile_id': profileId,
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
    final profileId = _profileId;
    try {
      await _remote.upsert(_cloudRow(uid, m, profileId));
    } catch (_) {
      /* best-effort */
    }
  }

  // ── pending-sync retry queue ───────────────────────────────────────────────
  // Keys of local adds whose cloud write failed (offline / quota). Persisted in
  // [syncMetaBox] so they survive restarts and self-heal via [retryPending].
  static const String _pendingKey = 'mylist_pending';
  static const String _pendingDeleteKey = 'mylist_pending_delete';

  String _metaKey(String key, [String? profileId]) =>
      profileScopedKey(profileId ?? _profileId, key);

  String _userSyncMetaKey(String key, String userId, String profileId) =>
      profileScopedKey(profileId, '$key:${hiveKey(userId)}');

  String _cursorKey(String userId, String profileId) =>
      _userSyncMetaKey(_syncCursorPrefix, userId, profileId);

  Set<String> pendingKeys([String? profileId]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return <String>{};
    final raw = Hive.box(syncMetaBox).get(_metaKey(_pendingKey, profileId));
    return raw is List ? raw.map((e) => '$e').toSet() : <String>{};
  }

  void _markPending(String k, [String? profileId]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final key = _metaKey(_pendingKey, profileId);
    final s = pendingKeys(profileId)..add(k);
    Hive.box(syncMetaBox).put(key, s.toList());
  }

  void _clearPending(String k, [String? profileId]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final key = _metaKey(_pendingKey, profileId);
    final s = pendingKeys(profileId);
    if (s.remove(k)) Hive.box(syncMetaBox).put(key, s.toList());
  }

  /// `sourceId::itemId` pairs whose cloud DELETE failed. A later pull must
  /// not resurrect them, and [retryPending] re-sends the delete.
  Set<String> pendingDeleteKeys([String? profileId]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return <String>{};
    final raw = Hive.box(
      syncMetaBox,
    ).get(_metaKey(_pendingDeleteKey, profileId));
    return raw is List ? raw.map((e) => '$e').toSet() : <String>{};
  }

  String _deleteKey(String sourceId, String itemId) => '$sourceId::$itemId';

  void _markPendingDelete(String sourceId, String itemId, [String? profileId]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final key = _metaKey(_pendingDeleteKey, profileId);
    final s = pendingDeleteKeys(profileId)..add(_deleteKey(sourceId, itemId));
    Hive.box(syncMetaBox).put(key, s.toList());
  }

  void _clearPendingDelete(
    String sourceId,
    String itemId, [
    String? profileId,
  ]) {
    if (!Hive.isBoxOpen(syncMetaBox)) return;
    final key = _metaKey(_pendingDeleteKey, profileId);
    final s = pendingDeleteKeys(profileId);
    if (s.remove(_deleteKey(sourceId, itemId))) {
      Hive.box(syncMetaBox).put(key, s.toList());
    }
  }

  /// Push up any local adds that never reached the cloud (a past write outage),
  /// so they self-heal once writes are available. Only touches items that
  /// actually failed — items that synced normally are never in the queue, so in
  /// steady state this makes ZERO writes.
  Future<void> retryPending() async {
    final uid = _currentUserId();
    if (uid == null) return;
    final profileId = _profileId;
    final pending = pendingKeys(profileId);
    final pendingDeletes = pendingDeleteKeys(profileId);
    if (pending.isEmpty && pendingDeletes.isEmpty) return;
    for (final raw in pendingDeletes) {
      final split = raw.indexOf('::');
      if (split <= 0) {
        _clearPendingDelete(raw, '', profileId);
        continue;
      }
      final sourceId = raw.substring(0, split);
      final itemId = raw.substring(split + 2);
      try {
        await _remote.deleteRow(
          uid,
          sourceId,
          itemId,
          profileId: _remoteProfileId(profileId),
        );
        _clearPendingDelete(sourceId, itemId, profileId);
      } catch (_) {
        /* keep pending, retry next launch */
      }
    }
    for (final k in pending) {
      final raw = _box.get(k);
      if (raw == null) {
        _clearPending(k, profileId); // removed locally since — nothing to sync
        continue;
      }
      final m = _itemFromHive(raw);
      // Unreadable on this build — can't build a cloud row for it. Left pending
      // rather than cleared, so it still syncs if a later build can decode it.
      if (m == null) continue;
      try {
        await _remote.upsert(_cloudRow(uid, m, profileId));
        _clearPending(k, profileId);
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
  Future<void> pullFromCloud({String? forProfileId}) async {
    final uid = _currentUserId();
    if (uid == null) return;
    final profileId = forProfileId ?? _profileId;
    final remoteProfileId = _remoteProfileId(profileId);
    try {
      final meta = Hive.box(syncMetaBox);
      final cursorKey = _cursorKey(uid, profileId);
      final cursor = meta.get(cursorKey) as int?;
      final currentVersion = await _remote.currentVersion(
        uid,
        profileId: remoteProfileId,
      );

      if (cursor != null && cursor <= currentVersion) {
        if (cursor < currentVersion) {
          final changes = await _remote.changesFor(
            uid,
            profileId: remoteProfileId,
            afterVersion: cursor,
            throughVersion: currentVersion,
          );
          await _applyIncrementalChanges(changes, profileId);
          await meta.put(cursorKey, currentVersion);
          revision.value++;
        }
        _markPulled(profileId, uid);
        return;
      }

      // First sync for this account/profile (or a reset server clock): read a
      // complete, paged snapshot, then replay writes made while it was loading.
      final rows = await _remote.listFor(uid, profileId: remoteProfileId);
      final throughVersion = await _remote.currentVersion(
        uid,
        profileId: remoteProfileId,
      );
      final changes = await _remote.changesFor(
        uid,
        profileId: remoteProfileId,
        afterVersion: currentVersion,
        throughVersion: throughVersion,
      );
      final snapshot = _mergeSnapshotAndChanges(rows, changes);
      await _applyFullSnapshot(snapshot, profileId, uid);
      await meta.put(cursorKey, throughVersion);
      revision.value++;
      _markPulled(profileId, uid);
    } catch (_) {
      /* keep whatever is local */
    }
  }

  Map<String, Map<String, dynamic>> _mergeSnapshotAndChanges(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> changes,
  ) {
    final activeRows = <String, Map<String, dynamic>>{};
    final versions = <String, int>{};
    for (final row in rows) {
      final key = _deleteKey('${row['source_id']}', '${row['item_id']}');
      activeRows[key] = row;
      versions[key] = (row['sync_version'] as num?)?.toInt() ?? 0;
    }
    for (final change in changes) {
      final row = change['row'] as Map<String, dynamic>?;
      final sourceId = row?['source_id'] ?? change['source_id'];
      final itemId = row?['item_id'] ?? change['item_id'];
      final key = _deleteKey('$sourceId', '$itemId');
      final version = (change['sync_version'] as num).toInt();
      if (version <= (versions[key] ?? -1)) continue;
      versions[key] = version;
      if (change['deleted'] == true) {
        activeRows.remove(key);
      } else if (row != null) {
        activeRows[key] = row;
      }
    }
    return activeRows;
  }

  Future<void> _applyFullSnapshot(
    Map<String, Map<String, dynamic>> rows,
    String profileId,
    String uid,
  ) async {
    final pendingDeletes = pendingDeleteKeys(profileId);
    final cloudKeys = <String>{};
    for (final row in rows.values) {
      cloudKeys.add(_keyFromIds(row['source_id'], row['item_id'], profileId));
      await _applyCloudRow(row, profileId, pendingDeletes);
    }
    if (!_seededFor(uid, profileId)) return;
    final pending = pendingKeys(profileId);
    for (final raw in _box.keys.toList()) {
      final key = '$raw';
      if (!profileOwnsKey(key, profileId) ||
          cloudKeys.contains(key) ||
          pending.contains(key)) {
        continue;
      }
      await _box.delete(key);
      _onStatusPulled?.call(key, null);
    }
  }

  Future<void> _applyIncrementalChanges(
    List<Map<String, dynamic>> changes,
    String profileId,
  ) async {
    final pendingDeletes = pendingDeleteKeys(profileId);
    final pendingAdds = pendingKeys(profileId);
    for (final change in changes) {
      final row = change['row'] as Map<String, dynamic>?;
      final sourceId = '${row?['source_id'] ?? change['source_id']}';
      final itemId = '${row?['item_id'] ?? change['item_id']}';
      if (change['deleted'] == true) {
        final key = _keyFromIds(sourceId, itemId, profileId);
        if (!pendingAdds.contains(key)) {
          await _box.delete(key);
          _onStatusPulled?.call(key, null);
        }
      } else if (row != null) {
        await _applyCloudRow(row, profileId, pendingDeletes);
      }
    }
  }

  Future<void> _applyCloudRow(
    Map<String, dynamic> row,
    String profileId,
    Set<String> pendingDeletes,
  ) async {
    final sourceId = '${row['source_id']}';
    final itemId = '${row['item_id']}';
    if (pendingDeletes.contains(_deleteKey(sourceId, itemId))) return;
    final headers = row['cover_headers'];
    Object? coverHeaders;
    try {
      coverHeaders = headers is String
          ? jsonDecode(headers)
          : headers is Map
          ? headers
          : null;
    } catch (_) {
      coverHeaders = null;
    }
    final rawItem = <String, dynamic>{
      'id': row['item_id'],
      'title': row['title'],
      'cover': row['cover'],
      'coverHeaders': coverHeaders,
      'url': row['url'],
      'type': row['type'],
      'sourceId': row['source_id'],
    };
    MediaItem item;
    try {
      item = MediaItem.fromJson(rawItem);
    } catch (_) {
      // Keep future/unknown types on disk so a later build can decode them.
      await _box.put(
        _keyFromIds(row['source_id'], row['item_id'], profileId),
        rawItem,
      );
      return;
    }
    final ids = trackerIdsFromItem(item);
    item = item.copyWith(
      malId: ids.malId,
      anilistId: ids.anilistId,
      tmdbId: ids.tmdbId,
    );
    final key = _key(item, profileId);
    await _box.put(key, item.toJson());
    _clearPending(key, profileId);
    final cloudStatus = row['status'] as String?;
    if (cloudStatus != null) {
      _onStatusPulled?.call(key, cloudStatus);
    } else if (_statusOf?.call(item) != null) {
      unawaited(_pushStatusForProfile(item, profileId));
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
    final uid = _currentUserId();
    if (uid == null) return;
    final profileId = _profileId;
    int? last;
    if (Hive.isBoxOpen(syncMetaBox)) {
      last =
          Hive.box(
                syncMetaBox,
              ).get(_userSyncMetaKey(_syncMetaKey, uid, profileId))
              as int?;
    }
    if (last != null) {
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age >= 0 && age < maxAge.inMilliseconds) return; // still fresh
    }
    await pullFromCloud(forProfileId: profileId);
  }

  String _keyFromIds(Object? sourceId, Object? itemId, String profileId) =>
      profileScopedKey(profileId, hiveKey('$sourceId::$itemId'));

  Future<void> _pushStatusForProfile(MediaItem item, String profileId) async {
    final uid = _currentUserId();
    if (uid == null) return;
    try {
      await _remote.upsert(_cloudRow(uid, item, profileId));
    } catch (_) {
      /* best-effort */
    }
  }

  bool _seededFor(String uid, String profileId) {
    if (!Hive.isBoxOpen(syncMetaBox)) return false;
    return Hive.box(
          syncMetaBox,
        ).get(profileScopedKey(profileId, '$_seedFlagPrefix$uid')) ==
        true;
  }

  void _markPulled(String profileId, String uid) {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(syncMetaBox).put(
        _userSyncMetaKey(_syncMetaKey, uid, profileId),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  /// Wipe the local cache (on logout).
  Future<void> clearLocal() async {
    await _box.clear();
    if (Hive.isBoxOpen(syncMetaBox)) {
      final meta = Hive.box(syncMetaBox);
      for (final key in meta.keys.toList()) {
        final value = '$key';
        if (_isMyListSyncMetaKey(value)) {
          await meta.delete(key);
        }
      }
      await meta.delete(_pendingKey);
      await meta.delete(_pendingDeleteKey);
    }
    revision.value++;
  }
}
