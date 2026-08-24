import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../models/media_item.dart';
import '../supabase/supabase_service.dart';

/// One user-made category ("Persona", "Gym"). [id] is stable and never shown —
/// renaming changes [name] only, so assignments survive a rename.
class ListCategory {
  const ListCategory({
    required this.id,
    required this.name,
    required this.position,
  });

  final String id;
  final String name;
  final int position;

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'position': position};

  static ListCategory? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String || id.isEmpty || name.isEmpty) {
      return null;
    }
    return ListCategory(
      id: id,
      name: name,
      position: (raw['position'] as num?)?.toInt() ?? 0,
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

  Future<List<Map<String, dynamic>>> categoriesFor(String uid) async {
    final res = await _service.client
        .from('list_categories')
        .select()
        .eq('user_key', uid);
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> assignmentsFor(String uid) async {
    final res = await _service.client
        .from('mylist_categories')
        .select()
        .eq('user_key', uid);
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<void> upsertCategory(Map<String, dynamic> row) =>
      _service.client.from('list_categories').upsert(row);

  Future<void> deleteCategory(String uid, String id) => _service.client
      .from('list_categories')
      .delete()
      .match({'user_key': uid, 'id': id});

  Future<void> addAssignment(Map<String, dynamic> row) =>
      _service.client.from('mylist_categories').upsert(row);

  Future<void> removeAssignment(
    String uid,
    String sourceId,
    String itemId,
    String categoryId,
  ) =>
      _service.client.from('mylist_categories').delete().match({
        'user_key': uid,
        'source_id': sourceId,
        'item_id': itemId,
        'category_id': categoryId,
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
  CategoryStore({CategoryRemote? remote, String? Function()? currentUserId})
      : _remote = remote,
        _currentUserId = currentUserId;

  /// Null when the app runs without Supabase (tests) — everything still works,
  /// it just stays on the device.
  final CategoryRemote? _remote;
  final String? Function()? _currentUserId;

  static const String boxName = 'list_categories';
  static const String _catsKey = '__categories__';

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
  }

  Box get _box => Hive.box(boxName);

  /// Bumped on every change so My List rebuilds.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Same key shape as [ListStatusStore] so the two line up per title.
  String keyOf(MediaItem m) => '${m.sourceId}::${m.id}';

  // ── the categories themselves ────────────────────────────────────────────

  /// In display order. Ties fall back to name so the order is never arbitrary.
  List<ListCategory> all() {
    final raw = _box.get(_catsKey);
    if (raw is! List) return const [];
    final out = raw.map(ListCategory.fromMap).whereType<ListCategory>().toList()
      ..sort((a, b) {
        final p = a.position.compareTo(b.position);
        return p != 0 ? p : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return out;
  }

  Future<void> _writeAll(List<ListCategory> cats) async {
    await _box.put(_catsKey, [for (final c in cats) c.toMap()]);
    revision.value++;
  }

  /// Creates a category and returns it, or null when [name] is blank or already
  /// taken (compared case-insensitively — two categories called "gym" and "Gym"
  /// would be indistinguishable on screen).
  Future<ListCategory?> create(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final cats = all();
    if (cats.any((c) => c.name.toLowerCase() == trimmed.toLowerCase())) {
      return null;
    }
    final cat = ListCategory(
      // A real UUID, because the cloud column is one — an id shaped any other
      // way would need a mapping table to sync.
      id: _uuidV4(),
      name: trimmed,
      position: cats.isEmpty ? 0 : cats.last.position + 1,
    );
    await _writeAll([...cats, cat]);
    _push((r, uid) => r.upsertCategory({
          'id': cat.id,
          'user_key': uid,
          'name': cat.name,
          'position': cat.position,
        }));
    return cat;
  }

  /// Renames in place. Assignments are keyed by id, so they all survive.
  Future<bool> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final cats = all();
    if (cats.any((c) =>
        c.id != id && c.name.toLowerCase() == trimmed.toLowerCase())) {
      return false;
    }
    if (!cats.any((c) => c.id == id)) return false;
    await _writeAll([
      for (final c in cats)
        if (c.id == id)
          ListCategory(id: c.id, name: trimmed, position: c.position)
        else
          c,
    ]);
    _push((r, uid) => r.upsertCategory({
          'id': id,
          'user_key': uid,
          'name': trimmed,
          'position': cats.firstWhere((c) => c.id == id).position,
        }));
    return true;
  }

  /// Removes the category and every assignment to it. Titles are untouched —
  /// deleting a category loses the label, never anything from the list.
  Future<void> delete(String id) async {
    await _writeAll(all().where((c) => c.id != id).toList());
    for (final key in _box.keys.toList()) {
      if (key == _catsKey || key is! String) continue;
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
    _push((r, uid) => r.deleteCategory(uid, id));
  }

  /// Persists a new order. [orderedIds] is the full list, first to last.
  Future<void> reorder(List<String> orderedIds) async {
    final byId = {for (final c in all()) c.id: c};
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
    await _writeAll(out);
    for (final c in out) {
      _push((r, uid) => r.upsertCategory({
            'id': c.id,
            'user_key': uid,
            'name': c.name,
            'position': c.position,
          }));
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

  Future<void> setMembership(MediaItem m, String categoryId, bool member) async {
    final key = keyOf(m);
    final ids = _idsFor(key);
    if (member ? !ids.add(categoryId) : !ids.remove(categoryId)) return;
    if (ids.isEmpty) {
      await _box.delete(key);
    } else {
      await _box.put(key, ids.toList());
    }
    revision.value++;
    _push((r, uid) => member
        ? r.addAssignment({
            'user_key': uid,
            'source_id': m.sourceId,
            'item_id': m.id,
            'category_id': categoryId,
          })
        : r.removeAssignment(uid, m.sourceId, m.id, categoryId));
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
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    final List<Map<String, dynamic>> catRows;
    final List<Map<String, dynamic>> linkRows;
    try {
      catRows = await r.categoriesFor(uid);
      linkRows = await r.assignmentsFor(uid);
    } catch (e) {
      debugPrint('[categories] cloud pull failed: $e');
      return;
    }

    final cats = <ListCategory>[];
    for (final row in catRows) {
      final id = row['id'], name = row['name'];
      if (id is! String || name is! String) continue;
      cats.add(ListCategory(
        id: id,
        name: name,
        position: (row['position'] as num?)?.toInt() ?? 0,
      ));
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
      byKey.putIfAbsent('$src::$item', () => <String>{}).add(cat);
    }

    // Most pulls find exactly what's already here (nothing changed on another
    // device). Bailing out means no writes and no rebuild — which is what
    // stops the tabs flickering on every launch and resume.
    if (_sameAsLocal(cats, byKey)) return;

    // Write the new state BEFORE removing anything. Clearing first left a
    // window on every launch where the tabs vanished and came back a moment
    // later, and a crash inside that window emptied the device until the next
    // pull. Nothing is deleted until its replacement is already in place.
    for (final e in byKey.entries) {
      await _box.put(e.key, e.value.toList());
    }
    for (final key in _box.keys.toList()) {
      if (key == _catsKey || key is! String) continue;
      if (!byKey.containsKey(key)) await _box.delete(key);
    }
    await _writeAll(cats); // bumps revision, so My List rebuilds
  }

  /// True when the cloud copy already matches what's on the device, so a pull
  /// can skip the rebuild entirely.
  bool _sameAsLocal(List<ListCategory> cats, Map<String, Set<String>> byKey) {
    final local = all();
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
    for (final key in _box.keys) {
      if (key == _catsKey || key is! String) continue;
      if (_idsFor(key).contains(categoryId)) n++;
    }
    return n;
  }
}
