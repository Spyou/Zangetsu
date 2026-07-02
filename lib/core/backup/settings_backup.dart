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
      if (Hive.isBoxOpen(name)) {
        final box = Hive.box(name);
        out[name] = Map<String, dynamic>.from(
          box.toMap().map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    }
    return out;
  }

  /// Overwrites each box with the entries from [data].
  /// Closed boxes and unknown box names are silently skipped.
  /// Never calls `clear()` — only `putAll`.
  Future<void> merge(Map<String, dynamic> data) async {
    for (final entry in data.entries) {
      final name = entry.key;
      final kv = entry.value;
      if (kv is Map && Hive.isBoxOpen(name)) {
        await Hive.box(name).putAll(Map<String, dynamic>.from(kv));
      }
    }
  }
}
