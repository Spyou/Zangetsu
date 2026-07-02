import 'package:hive/hive.dart';

/// Codec that dumps and restores the plain preference Hive boxes.
///
/// Excluded intentionally:
///   - `discord`           — may hold the RPC auth token
///   - `provider_settings` — belongs to the Sources bundle
///   - `auth_cache`        — authentication token cache
///   - `*_cache`           — transient caches, not user preferences
///   - `search_view_prefs` — verified absent in the confirmed box list
class SettingsBackup {
  static const List<String> boxNames = [
    'playback_prefs', // player, subtitle style, DNS, speed, etc.
    'app_prefs', // active source + app-level prefs
    'search_prefs', // search source inclusion prefs
    'title_prefs', // per-title remembered quality
  ];

  /// Returns a map of `{boxName: {key: value, ...}}` for every open box.
  /// Closed boxes are silently skipped.
  Map<String, dynamic> build() {
    final out = <String, dynamic>{};
    for (final name in boxNames) {
      final box = _boxFor(name);
      if (box == null) continue;
      out[name] = Map<String, dynamic>.from(
        (box.toMap() as Map).map((k, v) => MapEntry(k.toString(), v)),
      );
    }
    return out;
  }

  /// Overwrites each box with the entries from [data].
  /// Closed boxes and unknown box names are silently skipped.
  /// Never calls `clear()` — only `putAll`.
  Future<void> merge(Map<String, dynamic> data) async {
    for (final entry in data.entries) {
      final kv = entry.value;
      if (kv is! Map) continue;
      final box = _boxFor(entry.key);
      if (box == null) continue;
      // Per-key put (not putAll): a Box<Map> rejects a Map<String,dynamic> whose
      // static value type isn't Map, whereas put() checks each value at runtime.
      for (final e in kv.entries) {
        await box.put(e.key, e.value);
      }
    }
  }

  /// The already-open box for [name] regardless of the type it was opened with:
  /// some prefs boxes are `Box<Map>` (e.g. `title_prefs`), others are
  /// `Box<dynamic>`, and a mismatched `Hive.box<E>(name)` throws. Null when the
  /// box isn't open (or is an unexpected type).
  dynamic _boxFor(String name) {
    if (!Hive.isBoxOpen(name)) return null;
    try {
      return Hive.box<Map>(name);
    } catch (_) {/* not a Box<Map> */}
    try {
      return Hive.box(name);
    } catch (_) {/* not a Box<dynamic> either */}
    return null;
  }
}
