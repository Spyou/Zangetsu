import 'package:hive/hive.dart';

/// Backs up the user's library (My List + watch history) and merges it back:
/// My List by union, history by keep-newer. Never deletes.
class LibraryBackup {
  static const _myListBox = 'my_list';
  static const _historyBox = 'history';

  Map<String, dynamic> build() => {
        'myList': _dump(_myListBox),
        'history': _dump(_historyBox),
      };

  List<Map<String, dynamic>> _dump(String box) => Hive.isBoxOpen(box)
      ? Hive.box<Map>(box)
          .values
          .map((m) => Map<String, dynamic>.from(m))
          .toList()
      : const [];

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
  }
}
