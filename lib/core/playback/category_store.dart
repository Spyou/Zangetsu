import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';

import '../models/media_item.dart';
import '../profiles/profile_scope.dart';
import '../supabase/supabase_service.dart';

/// One user-made category ("Persona", "Gym"). [id] is stable and never shown —
/// renaming changes [name] only, so assignments survive a rename.
class ListCategory {
  const ListCategory({
    required this.id,
    required this.name,
    required this.position,
    this.kind,
  });

  final String id;
  final String name;
  final int position;

  /// Which mode this was made in ([ContentMode.name]), or null for the ones
  /// created before categories remembered. A kind means the category belongs
  /// to that mode alone; null keeps the old behaviour, where an empty category
  /// showed everywhere — those already exist on people's devices and quietly
  /// moving them into one mode would look like they had been deleted from the
  /// other two.
  ///
  /// Device-local on purpose: the cloud table has no such column, and sending
  /// one it does not know would fail the upsert and take category creation
  /// down with it.
  final String? kind;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'position': position,
    if (kind != null) 'kind': kind,
  };

  static ListCategory? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String || id.isEmpty || name.isEmpty) {
      return null;
    }
    final kind = raw['kind'];
    return ListCategory(
      id: id,
      name: name,
      position: (raw['position'] as num?)?.toInt() ?? 0,
      kind: kind is String && kind.isNotEmpty ? kind : null,
    );
  }
}

/// Random v4 UUID. Hand-rolled to avoid pulling in a package for one string.
String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int i, int j) =>
      b.sublist(i, j).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Reads and writes the two Supabase tables that back categories. Thin on
/// purpose — the store owns the logic, this owns the wire.
class CategoryRemote {
  CategoryRemote(this._service);
  final SupabaseService _service;

  Future<List<Map<String, dynamic>>> categoriesFor(
    String uid, {
    String? profileId,
  }) async {
    final table = profileId == null
        ? 'list_categories'
        : 'profile_list_categories';
    var query = _service.client.from(table).select().eq('user_key', uid);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final res = await query;
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> assignmentsFor(
    String uid, {
    String? profileId,
  }) async {
    final table = profileId == null
        ? 'mylist_categories'
        : 'profile_mylist_categories';
    var query = _service.client.from(table).select().eq('user_key', uid);
    if (profileId != null) query = query.eq('profile_id', profileId);
    final res = await query;
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<void> upsertCategory(Map<String, dynamic> row) => _service.client
      .from(
        row['profile_id'] == null
            ? 'list_categories'
            : 'profile_list_categories',
      )
      .upsert(row);

  Future<void> deleteCategory(String uid, String id, {String? profileId}) =>
      _service.client
          .from(
            profileId == null ? 'list_categories' : 'profile_list_categories',
          )
          .delete()
          .match({
            'user_key': uid,
            'id': id,
            ...?profileId == null ? null : {'profile_id': profileId},
          });

  Future<void> addAssignment(Map<String, dynamic> row) => _service.client
      .from(
        row['profile_id'] == null
            ? 'mylist_categories'
            : 'profile_mylist_categories',
      )
      .upsert(row);

  Future<void> removeAssignment(
    String uid,
    String sourceId,
    String itemId,
    String categoryId, {
    String? profileId,
  }) => _service.client
      .from(
        profileId == null ? 'mylist_categories' : 'profile_mylist_categories',
      )
      .delete()
      .match({
        'user_key': uid,
        'source_id': sourceId,
        'item_id': itemId,
        'category_id': categoryId,
        ...?profileId == null ? null : {'profile_id': profileId},
      });
}

/// The user's own categories for My List, and which titles are in them.
///
/// A SEPARATE box from [MyListStore] for the same reason [ListStatusStore] is
/// one: the list box is cleared and repopulated by a cloud pull, and a category
/// must not be collateral damage. Nothing here writes to the saved list — a
/// category is a label beside a title, never a change to it.
///
/// A title can be in several categories at once, so assignments are a set per
/// title rather than a single value. Trackers never see any of this.
class CategoryStore {
  CategoryStore({
    CategoryRemote? remote,
    String? Function()? currentUserId,
    String? Function()? currentProfileId,
  }) : _remote = remote,
       _currentUserId = currentUserId,
       _currentProfileId = currentProfileId;

  /// Null when the app runs without Supabase (tests) — everything still works,
  /// it just stays on the device.
  final CategoryRemote? _remote;
  final String? Function()? _currentUserId;
  final String? Function()? _currentProfileId;
  String get _profileId => _currentProfileId?.call() ?? kDefaultProfileId;
  String? _remoteProfileId(String id) => id == kDefaultProfileId ? null : id;

  static const String boxName = 'list_categories';
  static const String _catsKey = '__categories__';
  String _categoriesKey([String? profileId]) =>
      profileScopedKey(profileId ?? _profileId, _catsKey);
  String _metaKey([String? profileId]) =>
      profileScopedKey(profileId ?? _profileId, _syncMetaKey);

  /// Shared with [MyListStore] / [WatchHistory] — last successful cloud-pull
  /// timestamps, kept out of [boxName] so they never appear in assignment
  /// iteration.
  static const String syncMetaBox = 'library_sync_meta';
  static const String _syncMetaKey = 'categories_lastPullMs';

  /// The signed-in user, or null when logged out / not wired up.
  String? get _uid => _currentUserId?.call();

  /// Cloud writes are best-effort and never block the UI: the local box is the
  /// read source, so a failed push just means this change syncs on the next
  /// pull rather than the user seeing an error for something that worked.
  void _push(Future<void> Function(CategoryRemote r, String uid) op) {
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    () async {
      try {
        await op(r, uid);
      } catch (e) {
        debugPrint('[categories] cloud push failed: $e');
      }
    }();
  }

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
    if (!Hive.isBoxOpen(syncMetaBox)) await openBoxSafely(syncMetaBox);
  }

  Box get _box => Hive.box(boxName);

  /// Bumped on every change so My List rebuilds.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Same key shape as [ListStatusStore] so the two line up per title.
  String keyOf(MediaItem m) =>
      profileScopedKey(_profileId, hiveKey('${m.sourceId}::${m.id}'));

  // ── the categories themselves ────────────────────────────────────────────

  /// In display order. Ties fall back to name so the order is never arbitrary.
  List<ListCategory> all() => _allFor(_profileId);

  List<ListCategory> _allFor(String profileId) {
    final raw = _box.get(_categoriesKey(profileId));
    if (raw is! List) return const [];
    final out = raw.map(ListCategory.fromMap).whereType<ListCategory>().toList()
      ..sort((a, b) {
        final p = a.position.compareTo(b.position);
        return p != 0
            ? p
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return out;
  }

  Future<void> _writeAll(List<ListCategory> cats, [String? profileId]) async {
    await _box.put(_categoriesKey(profileId), [
      for (final c in cats) c.toMap(),
    ]);
    revision.value++;
  }

  /// Creates a category and returns it, or null when [name] is blank or already
  /// taken (compared case-insensitively — two categories called "gym" and "Gym"
  /// would be indistinguishable on screen).
  Future<ListCategory?> create(String name, {String? kind}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final profileId = _profileId;
    final cats = _allFor(profileId);
    if (cats.any((c) => c.name.toLowerCase() == trimmed.toLowerCase())) {
      return null;
    }
    final cat = ListCategory(
      // A real UUID, because the cloud column is one — an id shaped any other
      // way would need a mapping table to sync.
      id: _uuidV4(),
      name: trimmed,
      position: cats.isEmpty ? 0 : cats.last.position + 1,
      kind: kind,
    );
    await _writeAll([...cats, cat], profileId);
    _push(
      (r, uid) => r.upsertCategory({
        'id': cat.id,
        'user_key': uid,
        if (profileId != kDefaultProfileId) 'profile_id': profileId,
        'name': cat.name,
        'position': cat.position,
      }),
    );
    return cat;
  }

  /// Renames in place. Assignments are keyed by id, so they all survive.
  Future<bool> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final profileId = _profileId;
    final cats = _allFor(profileId);
    if (cats.any(
      (c) => c.id != id && c.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      return false;
    }
    if (!cats.any((c) => c.id == id)) return false;
    await _writeAll([
      for (final c in cats)
        if (c.id == id)
          ListCategory(id: c.id, name: trimmed, position: c.position)
        else
          c,
    ], profileId);
    _push(
      (r, uid) => r.upsertCategory({
        'id': id,
        'user_key': uid,
        if (profileId != kDefaultProfileId) 'profile_id': profileId,
        'name': trimmed,
        'position': cats.firstWhere((c) => c.id == id).position,
      }),
    );
    return true;
  }

  /// Removes the category and every assignment to it. Titles are untouched —
  /// deleting a category loses the label, never anything from the list.
  Future<void> delete(String id) async {
    final profileId = _profileId;
    await _writeAll(
      _allFor(profileId).where((c) => c.id != id).toList(),
      profileId,
    );
    for (final key in _box.keys.toList()) {
      if (!profileOwnsKey(key, profileId) || key == _categoriesKey(profileId)) {
        continue;
      }
      final ids = _idsFor(key);
      if (!ids.remove(id)) continue;
      if (ids.isEmpty) {
        await _box.delete(key);
      } else {
        await _box.put(key, ids.toList());
      }
    }
    revision.value++;
    // The cloud cascades the assignments itself (foreign key on delete).
    _push(
      (r, uid) =>
          r.deleteCategory(uid, id, profileId: _remoteProfileId(profileId)),
    );
  }

  /// Persists a new order. [orderedIds] is the full list, first to last.
  Future<void> reorder(List<String> orderedIds) async {
    final profileId = _profileId;
    final byId = {for (final c in _allFor(profileId)) c.id: c};
    final out = <ListCategory>[];
    var i = 0;
    for (final id in orderedIds) {
      final c = byId.remove(id);
      if (c != null) {
        out.add(ListCategory(id: c.id, name: c.name, position: i++));
      }
    }
    // Anything not named keeps its relative order at the end, so a stale list
    // can never silently drop a category.
    for (final c in byId.values) {
      out.add(ListCategory(id: c.id, name: c.name, position: i++));
    }
    await _writeAll(out, profileId);
    for (final c in out) {
      _push(
        (r, uid) => r.upsertCategory({
          'id': c.id,
          'user_key': uid,
          if (profileId != kDefaultProfileId) 'profile_id': profileId,
          'name': c.name,
          'position': c.position,
        }),
      );
    }
  }

  // ── assignments ─────────────────────────────────────────────────────────

  Set<String> _idsFor(String key) {
    final raw = _box.get(key);
    if (raw is! List) return <String>{};
    return raw.whereType<String>().toSet();
  }

  /// Category ids this title belongs to.
  Set<String> categoriesOf(MediaItem m) => _idsFor(keyOf(m));

  bool isIn(MediaItem m, String categoryId) =>
      _idsFor(keyOf(m)).contains(categoryId);

  Future<void> setMembership(
    MediaItem m,
    String categoryId,
    bool member,
  ) async {
    final profileId = _profileId;
    final key = keyOf(m);
    final ids = _idsFor(key);
    if (member ? !ids.add(categoryId) : !ids.remove(categoryId)) return;
    if (ids.isEmpty) {
      await _box.delete(key);
    } else {
      await _box.put(key, ids.toList());
    }
    revision.value++;
    _push(
      (r, uid) => member
          ? r.addAssignment({
              'user_key': uid,
              if (profileId != kDefaultProfileId) 'profile_id': profileId,
              'source_id': m.sourceId,
              'item_id': m.id,
              'category_id': categoryId,
            })
          : r.removeAssignment(
              uid,
              m.sourceId,
              m.id,
              categoryId,
              profileId: _remoteProfileId(profileId),
            ),
    );
  }

  /// Drops every assignment for a title — for when it leaves My List entirely.
  Future<void> clearFor(MediaItem m) async {
    if (_box.containsKey(keyOf(m))) {
      await _box.delete(keyOf(m));
      revision.value++;
    }
  }

  // ── cloud ───────────────────────────────────────────────────────────────

  /// Replaces the local copy with what the cloud holds.
  ///
  /// The cloud wins because every local change is pushed to it as it happens,
  /// so it's the newer copy by construction. Merging instead would resurrect a
  /// category deleted on another device — the classic two-way-sync trap.
  ///
  /// A pull that fails leaves the device exactly as it was: nothing is cleared
  /// until the read has succeeded.
  Future<void> pullFromCloud() async {
    final profileId = _profileId;
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    final List<Map<String, dynamic>> catRows;
    final List<Map<String, dynamic>> linkRows;
    try {
      catRows = await r.categoriesFor(
        uid,
        profileId: _remoteProfileId(profileId),
      );
      linkRows = await r.assignmentsFor(
        uid,
        profileId: _remoteProfileId(profileId),
      );
    } catch (e) {
      debugPrint('[categories] cloud pull failed: $e');
      return;
    }

    final cats = <ListCategory>[];
    for (final row in catRows) {
      final id = row['id'], name = row['name'];
      if (id is! String || name is! String) continue;
      cats.add(
        ListCategory(
          id: id,
          name: name,
          position: (row['position'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    // Rebuild assignments from scratch, keyed the same way the local box is.
    final byKey = <String, Set<String>>{};
    final knownIds = {for (final c in cats) c.id};
    for (final row in linkRows) {
      final src = row['source_id'], item = row['item_id'];
      final cat = row['category_id'];
      if (src is! String || item is! String || cat is! String) continue;
      // Ignore a link to a category that no longer exists, so a half-deleted
      // row can't create a phantom tab.
      if (!knownIds.contains(cat)) continue;
      byKey
          .putIfAbsent(
            profileScopedKey(profileId, hiveKey('$src::$item')),
            () => <String>{},
          )
          .add(cat);
    }

    // Most pulls find exactly what's already here (nothing changed on another
    // device). Bailing out means no writes and no rebuild — which is what
    // stops the tabs flickering on every launch and resume.
    if (_sameAsLocal(cats, byKey, profileId)) {
      _markPulled(profileId);
      return;
    }

    // Write the new state BEFORE removing anything. Clearing first left a
    // window on every launch where the tabs vanished and came back a moment
    // later, and a crash inside that window emptied the device until the next
    // pull. Nothing is deleted until its replacement is already in place.
    for (final e in byKey.entries) {
      await _box.put(e.key, e.value.toList());
    }
    for (final key in _box.keys.toList()) {
      if (!profileOwnsKey(key, profileId) || key == _categoriesKey(profileId)) {
        continue;
      }
      if (!byKey.containsKey(key)) await _box.delete(key);
    }
    await _writeAll(cats, profileId); // bumps revision, so My List rebuilds
    _markPulled(profileId);
  }

  /// Pull from cloud only when the last successful pull is older than [maxAge]
  /// — same throttle as [MyListStore.pullFromCloudIfStale], so the foreground
  /// poll does not re-download categories every tick.
  Future<void> pullFromCloudIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    if (_uid == null || _remote == null) return;
    final profileId = _profileId;
    int? last;
    if (Hive.isBoxOpen(syncMetaBox)) {
      last = Hive.box(syncMetaBox).get(_metaKey(profileId)) as int?;
    }
    if (last != null) {
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age >= 0 && age < maxAge.inMilliseconds) return; // still fresh
    }
    if (_profileId == profileId) await pullFromCloud();
  }

  void _markPulled(String profileId) {
    if (Hive.isBoxOpen(syncMetaBox)) {
      Hive.box(
        syncMetaBox,
      ).put(_metaKey(profileId), DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// True when the cloud copy already matches what's on the device, so a pull
  /// can skip the rebuild entirely.
  bool _sameAsLocal(
    List<ListCategory> cats,
    Map<String, Set<String>> byKey,
    String profileId,
  ) {
    final local = _allFor(profileId);
    if (local.length != cats.length) return false;
    for (var i = 0; i < local.length; i++) {
      if (local[i].id != cats[i].id || local[i].name != cats[i].name) {
        return false;
      }
    }
    for (final e in byKey.entries) {
      if (!setEquals(_idsFor(e.key), e.value)) return false;
    }
    return true;
  }

  /// How many titles are in a category, counted from the assignments so an
  /// empty category honestly reads 0.
  int countIn(String categoryId) {
    var n = 0;
    final profileId = _profileId;
    for (final key in _box.keys) {
      if (!profileOwnsKey(key, profileId) || key == _categoriesKey(profileId)) {
        continue;
      }
      if (_idsFor(key).contains(categoryId)) n++;
    }
    return n;
  }
}
