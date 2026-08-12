import 'package:hive/hive.dart';

/// Backs up the user's library — My List, watch history, and manga/novel
/// reading progress — and merges it back in on restore. Never deletes:
/// My List and the reading boxes merge by union (existing entries win),
/// watch history keeps whichever side was updated more recently.
class LibraryBackup {
  static const _myListBox = 'my_list';
  // Was 'history' — no box by that name is ever opened anywhere in the app,
  // so this silently backed up nothing. The real Continue Watching box is
  // 'watch_history' (see WatchHistory.boxName).
  static const _historyBox = 'watch_history';
  static const _readHistoryBox = 'read_history';
  static const _readPositionsBox = 'read_positions';
  static const _listStatusBox = 'list_status';

  Map<String, dynamic> build() => {
        'myList': _dump(_myListBox),
        'history': _dump(_historyBox),
        'readHistory': _dumpKeyed(_readHistoryBox, asMap: true),
        'readPositions': _dumpKeyed(_readPositionsBox, asMap: true),
        'listStatus': _dumpKeyed(_listStatusBox, asMap: false),
      };

  List<Map<String, dynamic>> _dump(String box) => Hive.isBoxOpen(box)
      ? Hive.box<Map>(box)
          .values
          .map((m) => Map<String, dynamic>.from(m))
          .toList()
      : const [];

  /// Dumps [box] as a `{hiveKey: value}` map instead of a values list — for
  /// boxes whose stored VALUE doesn't carry its own key back (read_positions'
  /// value is bare `{pos, total}`; list_status' value is a bare status-name
  /// string), unlike [_dump]'s boxes where the key is rebuilt from fields
  /// inside the value on merge. [asMap] must match how the box was actually
  /// opened elsewhere (Box<Map> vs the untyped Box list_status uses) — Hive
  /// throws if you reopen a box under a different type parameter.
  Map<String, dynamic> _dumpKeyed(String box, {required bool asMap}) {
    if (!Hive.isBoxOpen(box)) return const {};
    if (asMap) {
      final b = Hive.box<Map>(box);
      return {
        for (final k in b.keys)
          k.toString(): Map<String, dynamic>.from(b.get(k) ?? const {}),
      };
    }
    final b = Hive.box(box);
    return {for (final k in b.keys) k.toString(): b.get(k)};
  }

  Future<void> merge(Map<String, dynamic> data) async {
    if (Hive.isBoxOpen(_myListBox)) {
      final box = Hive.box<Map>(_myListBox);
      for (final raw in (data['myList'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final key = '${m['sourceId']}::${m['id']}';
        if (!box.containsKey(key)) await box.put(key, m); // union, never overwrite
      }
    }
    if (Hive.isBoxOpen(_historyBox)) {
      final box = Hive.box<Map>(_historyBox);
      for (final raw in (data['history'] as List? ?? const [])) {
        final h = Map<String, dynamic>.from(raw as Map);
        final key = '${h['sourceId']}::${h['showId']}';
        final cur = box.get(key);
        final curTs = cur == null ? -1 : (cur['updatedAt'] as num? ?? -1).toInt();
        final newTs = (h['updatedAt'] as num? ?? 0).toInt();
        if (newTs > curTs) await box.put(key, h); // keep-newer, never delete
      }
    }
    await _mergeKeyed(_readHistoryBox, data['readHistory'], asMap: true);
    await _mergeKeyed(_readPositionsBox, data['readPositions'], asMap: true);
    await _mergeKeyed(_listStatusBox, data['listStatus'], asMap: false);
  }

  /// Union-merges a `{hiveKey: value}` map (as dumped by [_dumpKeyed]) into
  /// [box]: adds only keys not already present, never overwrites the current
  /// session's data. No-op when the box is closed or [raw] is missing/not a
  /// Map — covers both an old backup that lacks the key and a malformed one.
  Future<void> _mergeKeyed(String box, Object? raw, {required bool asMap}) async {
    if (!Hive.isBoxOpen(box) || raw is! Map) return;
    if (asMap) {
      final b = Hive.box<Map>(box);
      for (final e in raw.entries) {
        final key = e.key.toString();
        if (b.containsKey(key)) continue;
        final v = e.value;
        if (v is Map) await b.put(key, Map<String, dynamic>.from(v));
      }
      return;
    }
    final b = Hive.box(box);
    for (final e in raw.entries) {
      final key = e.key.toString();
      if (!b.containsKey(key)) await b.put(key, e.value);
    }
  }
}
