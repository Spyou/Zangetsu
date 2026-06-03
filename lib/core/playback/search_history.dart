import 'package:hive/hive.dart';

/// Recent search terms, newest-first, stored locally. Lightweight and
/// device-only (no cloud sync needed for search history).
class SearchHistory {
  static const String boxName = 'search_history';
  static const String _key = 'queries';
  static const int _max = 12;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  List<String> recent() {
    final raw = _box.get(_key);
    if (raw is List) {
      return raw.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = recent();
    // De-dupe case-insensitively, move the new term to the front.
    list.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    list.insert(0, q);
    if (list.length > _max) list.removeRange(_max, list.length);
    await _box.put(_key, list);
  }

  Future<void> remove(String query) async {
    final list = recent()
      ..removeWhere((e) => e.toLowerCase() == query.trim().toLowerCase());
    await _box.put(_key, list);
  }

  Future<void> clear() async => _box.delete(_key);
}
