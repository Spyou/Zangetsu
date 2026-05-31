import 'package:hive/hive.dart';
import '../models/media_item.dart';

class MyListStore {
  static const String boxName = 'my_list';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m) => '${m.sourceId}::${m.id}';

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  Future<void> toggle(MediaItem m) async {
    final k = _key(m);
    if (_box.containsKey(k)) {
      await _box.delete(k);
    } else {
      await _box.put(k, m.toJson());
    }
  }

  List<MediaItem> all() => _box.values
      .map((raw) => MediaItem.fromJson(Map<String, dynamic>.from(raw)))
      .toList();
}
