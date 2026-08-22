import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Persists the user's manual "this show = that tracker entry" corrections
/// (the match-fixer), keyed by `sourceId|showUrl`. The value maps each
/// tracker's `displayName` to the chosen tracker-native id, so a wrong
/// auto-match (typically the wrong season) can be pinned once and reused on
/// every later open. Empty/absent = fall back to automatic malId/title
/// resolution, i.e. exactly today's behaviour.
class TrackerBindingStore {
  static const String boxName = 'tracker_bindings';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  static String keyOf(String sourceId, String showUrl) => '$sourceId|$showUrl';

  /// The pinned `{trackerName: id}` map for a show, or empty when none set.
  Map<String, String> get(String key) {
    final raw = _box.get(key);
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  /// Pin [trackerName] → [id] for a show, merged with any existing pins.
  Future<void> set(String key, String trackerName, String id) async {
    final next = Map<String, String>.from(get(key));
    next[trackerName] = id;
    await _box.put(key, next);
  }

  /// Drop only [trackerName]'s pin for a show, leaving the other trackers'
  /// pins in place. Used when one tracker's entry is removed — keeping the pin
  /// would re-bind the next fetch to an entry that no longer exists.
  Future<void> remove(String key, String trackerName) async {
    final next = Map<String, String>.from(get(key));
    if (next.remove(trackerName) == null) return;
    next.isEmpty ? await _box.delete(key) : await _box.put(key, next);
  }

  Future<void> clear(String key) => _box.delete(key);
}
