import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestClient;
import 'package:watch_app/core/hive/safe_box.dart';

import '../supabase/cloud_postgrest.dart';
import '../supabase/supabase_service.dart';

/// How a series group picks its grid cover.
enum SeriesCoverMode { auto, entry, custom }

SeriesCoverMode _coverModeFromString(Object? raw) {
  switch (raw) {
    case 'entry':
      return SeriesCoverMode.entry;
    case 'custom':
      return SeriesCoverMode.custom;
    default:
      return SeriesCoverMode.auto;
  }
}

/// A user-made group of My List titles ("Fate" seasons 1-5 as one card).
/// Membership is exclusive: a title key lives in at most one group — see
/// [SeriesGroupStore.addMember].
class SeriesGroup {
  const SeriesGroup({
    required this.id,
    required this.title,
    required this.position,
    this.memberKeys = const [],
    this.coverMode = SeriesCoverMode.auto,
    this.coverMemberKey,
  });

  final String id;
  final String title;
  final int position;

  /// Title keys (`sourceId::id`) in hand-set order.
  final List<String> memberKeys;

  final SeriesCoverMode coverMode;

  /// Set only when [coverMode] is [SeriesCoverMode.entry].
  final String? coverMemberKey;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'position': position,
    'member_keys': memberKeys,
    'cover_mode': coverMode.name,
    'cover_member_key': coverMemberKey,
  };

  static SeriesGroup? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || title is! String || id.isEmpty || title.isEmpty) {
      return null;
    }
    final members = raw['member_keys'];
    return SeriesGroup(
      id: id,
      title: title,
      position: (raw['position'] as num?)?.toInt() ?? 0,
      memberKeys: members is List
          ? members.whereType<String>().toList()
          : const [],
      coverMode: _coverModeFromString(raw['cover_mode']),
      coverMemberKey: raw['cover_member_key'] as String?,
    );
  }
}

/// Random v4 UUID. Hand-rolled to avoid pulling in a package for one string
/// (same technique as other local-id generators in this codebase).
String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int i, int j) =>
      b.sublist(i, j).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Reads and writes the cloud table that backs series groups. Thin on
/// purpose — the store owns the logic, this owns the wire.
class SeriesGroupRemote {
  SeriesGroupRemote(
    SupabaseService service, {
    PostgrestClient? vpsClient,
    String? Function()? accessToken,
  }) : _cloud = CloudPostgrest(
         service,
         vpsClient: vpsClient,
         accessToken: accessToken,
       );

  final CloudPostgrest _cloud;

  Future<List<Map<String, dynamic>>> groupsFor(String uid) async {
    final res = await _cloud.from('series_groups').select().eq('user_key', uid);
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<void> upsertGroup(Map<String, dynamic> row) =>
      _cloud.from('series_groups').upsert(row);

  Future<void> deleteGroup(String uid, String id) =>
      _cloud.from('series_groups').delete().match({'user_key': uid, 'id': id});
}

/// The user's series groups for My List. The local box is the read source and
/// every write bumps [revision]; cloud sync is best-effort on top. Mirrors
/// every write persists locally first, cloud sync is best-effort on top.
class SeriesGroupStore {
  SeriesGroupStore({
    SeriesGroupRemote? remote,
    String? Function()? currentUserId,
  }) : _remote = remote,
       _currentUserId = currentUserId;

  final SeriesGroupRemote? _remote;
  final String? Function()? _currentUserId;

  String? get _uid => _currentUserId?.call();

  void _push(Future<void> Function(SeriesGroupRemote r, String uid) op) {
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    () async {
      try {
        await op(r, uid);
      } catch (e) {
        debugPrint('[series_groups] cloud push failed: $e');
      }
    }();
  }

  void _pushGroup(SeriesGroup g) =>
      _push((r, uid) => r.upsertGroup(_rowFor(uid, g)));

  static Map<String, dynamic> _rowFor(String uid, SeriesGroup g) => {
    'id': g.id,
    'user_key': uid,
    'title': g.title,
    'position': g.position,
    'member_keys': g.memberKeys,
    'cover_mode': g.coverMode.name,
    'cover_member_key': g.coverMemberKey,
  };

  static const String boxName = 'my_list_series_groups';
  static const String _groupsKey = '__series_groups__';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<SeriesGroup> all() {
    final raw = _box.get(_groupsKey);
    if (raw is! List) return const [];
    final out = raw.map(SeriesGroup.fromMap).whereType<SeriesGroup>().toList()
      ..sort((a, b) {
        final p = a.position.compareTo(b.position);
        return p != 0
            ? p
            : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    return out;
  }

  Future<void> _writeAll(List<SeriesGroup> groups) async {
    await _box.put(_groupsKey, [for (final g in groups) g.toMap()]);
    revision.value++;
  }

  SeriesGroup? _byId(List<SeriesGroup> groups, String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// The group containing [key], or null when it's not grouped.
  SeriesGroup? groupOf(String key) {
    for (final g in all()) {
      if (g.memberKeys.contains(key)) return g;
    }
    return null;
  }

  Future<SeriesGroup?> create(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final groups = all();
    final group = SeriesGroup(
      id: _uuidV4(),
      title: trimmed,
      position: groups.isEmpty ? 0 : groups.last.position + 1,
    );
    await _writeAll([...groups, group]);
    _pushGroup(group);
    return group;
  }

  Future<bool> rename(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return false;
    final groups = all();
    final existing = _byId(groups, id);
    if (existing == null) return false;
    final renamed = SeriesGroup(
      id: existing.id,
      title: trimmed,
      position: existing.position,
      memberKeys: existing.memberKeys,
      coverMode: existing.coverMode,
      coverMemberKey: existing.coverMemberKey,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == id) renamed else g,
    ]);
    _pushGroup(renamed);
    return true;
  }

  /// Removes the group. Titles are untouched — deleting a group loses the
  /// grouping, never anything from My List.
  Future<void> delete(String id) async {
    final groups = all();
    if (_byId(groups, id) == null) return;
    await _writeAll(groups.where((g) => g.id != id).toList());
    _push((r, uid) => r.deleteGroup(uid, id));
  }

  /// Adds [key] to [groupId], first removing it from whichever other group
  /// holds it (membership is exclusive). Dup-into-same-group is a no-op.
  Future<void> addMember(String groupId, String key) async {
    var groups = all();
    final target = _byId(groups, groupId);
    if (target == null) return;
    if (target.memberKeys.contains(key)) return;

    final stripped = <SeriesGroup>[];
    groups = [
      for (final g in groups)
        if (g.id != groupId && g.memberKeys.contains(key))
          _withoutMember(g, key, into: stripped)
        else
          g,
    ];

    final updatedTarget = _byId(groups, groupId)!;
    final withMember = SeriesGroup(
      id: updatedTarget.id,
      title: updatedTarget.title,
      position: updatedTarget.position,
      memberKeys: [...updatedTarget.memberKeys, key],
      coverMode: updatedTarget.coverMode,
      coverMemberKey: updatedTarget.coverMemberKey,
    );
    final result = [
      for (final g in groups)
        if (g.id == groupId) withMember else g,
    ];
    await _writeAll(result);
    _pushGroup(withMember);
    for (final g in stripped) {
      _pushGroup(g);
    }
  }

  SeriesGroup _withoutMember(
    SeriesGroup g,
    String key, {
    required List<SeriesGroup> into,
  }) {
    final updated = SeriesGroup(
      id: g.id,
      title: g.title,
      position: g.position,
      memberKeys: g.memberKeys.where((m) => m != key).toList(),
      coverMode: g.coverMode,
      coverMemberKey: g.coverMemberKey == key ? null : g.coverMemberKey,
    );
    into.add(updated);
    return updated;
  }

  Future<void> removeMember(String groupId, String key) async {
    final groups = all();
    final group = _byId(groups, groupId);
    if (group == null || !group.memberKeys.contains(key)) return;
    final updated = SeriesGroup(
      id: group.id,
      title: group.title,
      position: group.position,
      memberKeys: group.memberKeys.where((m) => m != key).toList(),
      coverMode: group.coverMode,
      coverMemberKey: group.coverMemberKey == key ? null : group.coverMemberKey,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == groupId) updated else g,
    ]);
    _pushGroup(updated);
  }

  Future<void> moveMember(String groupId, String key, int toIndex) async {
    final groups = all();
    final group = _byId(groups, groupId);
    if (group == null || !group.memberKeys.contains(key)) return;
    final members = group.memberKeys.where((m) => m != key).toList();
    members.insert(toIndex.clamp(0, members.length), key);
    final updated = SeriesGroup(
      id: group.id,
      title: group.title,
      position: group.position,
      memberKeys: members,
      coverMode: group.coverMode,
      coverMemberKey: group.coverMemberKey,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == groupId) updated else g,
    ]);
    _pushGroup(updated);
  }

  Future<void> setCoverAuto(String groupId) async {
    final groups = all();
    final group = _byId(groups, groupId);
    if (group == null) return;
    final updated = SeriesGroup(
      id: group.id,
      title: group.title,
      position: group.position,
      memberKeys: group.memberKeys,
      coverMode: SeriesCoverMode.auto,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == groupId) updated else g,
    ]);
    _pushGroup(updated);
  }

  Future<void> setCoverEntry(String groupId, String key) async {
    final groups = all();
    final group = _byId(groups, groupId);
    if (group == null || !group.memberKeys.contains(key)) return;
    final updated = SeriesGroup(
      id: group.id,
      title: group.title,
      position: group.position,
      memberKeys: group.memberKeys,
      coverMode: SeriesCoverMode.entry,
      coverMemberKey: key,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == groupId) updated else g,
    ]);
    _pushGroup(updated);
  }

  /// Drops [key] from whichever group holds it. A group left at 0 members is
  /// deleted outright; one left at 1+ members stays as-is (the user grouped
  /// it on purpose).
  Future<void> purgeTitle(String key) async {
    final groups = all();
    final holder = groups.where((g) => g.memberKeys.contains(key));
    if (holder.isEmpty) return;
    final group = holder.first;
    final remaining = group.memberKeys.where((m) => m != key).toList();
    if (remaining.isEmpty) {
      await delete(group.id);
      return;
    }
    final updated = SeriesGroup(
      id: group.id,
      title: group.title,
      position: group.position,
      memberKeys: remaining,
      coverMode: group.coverMode,
      coverMemberKey: group.coverMemberKey == key ? null : group.coverMemberKey,
    );
    await _writeAll([
      for (final g in groups)
        if (g.id == group.id) updated else g,
    ]);
    _pushGroup(updated);
  }

  // ── cloud ───────────────────────────────────────────────────────────────

  static const String syncMetaBox = 'library_sync_meta';
  static const String _lastPullKey = 'series_groups_last_pull';

  Future<void> pushAll() async {
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    for (final g in all()) {
      try {
        await r.upsertGroup(_rowFor(uid, g));
      } catch (e) {
        debugPrint('[series_groups] cloud push failed: $e');
      }
    }
  }

  Future<void> pullFromCloud() async {
    final r = _remote, uid = _uid;
    if (r == null || uid == null) return;
    final List<Map<String, dynamic>> rows;
    try {
      rows = await r.groupsFor(uid);
    } catch (e) {
      debugPrint('[series_groups] cloud pull failed: $e');
      return;
    }
    final groups = <SeriesGroup>[];
    for (final row in rows) {
      final g = SeriesGroup.fromMap(row);
      if (g != null) groups.add(g);
    }
    await _writeAll(groups);
    if (Hive.isBoxOpen(syncMetaBox)) {
      await Hive.box(
        syncMetaBox,
      ).put(_lastPullKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<void> pullFromCloudIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    if (_remote == null || _uid == null) return;
    if (Hive.isBoxOpen(syncMetaBox)) {
      final last = Hive.box(syncMetaBox).get(_lastPullKey) as int?;
      if (last != null) {
        final age = DateTime.now().millisecondsSinceEpoch - last;
        if (age >= 0 && age < maxAge.inMilliseconds) return;
      }
    }
    await pullFromCloud();
  }
}
