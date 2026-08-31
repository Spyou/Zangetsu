import 'package:hive/hive.dart';

/// Codec that dumps and restores the plain preference Hive boxes.
///
/// Excluded intentionally:
///   - `discord`           — may hold the RPC auth token
///   - `provider_settings` — belongs to the Sources bundle
///   - `auth_cache`        — authentication token cache
///   - `*_cache`           — transient caches, not user preferences
///   - `download_prefs`    — holds the download LOCATION, which on a custom
///                           folder is a device-specific SAF `content://` URI.
///                           Restoring it onto another phone points downloads
///                           at a folder that does not exist and cannot be
///                           written. Add only with per-key handling.
///   - `pinned_sources`, `subscriptions` — reference source ids the restoring
///                           device may not have installed
///
/// Every box here must be OPENED DURING BOOTSTRAP. [_boxFor] returns null for a
/// closed box and [build] skips it silently, so a lazily-opened box would look
/// backed up and quietly save nothing.
class SettingsBackup {
  static const List<String> boxNames = [
    'playback_prefs', // player, subtitle style, DNS, speed, etc.
    'app_prefs', // active source + app-level prefs
    'search_prefs', // search source inclusion prefs
    'title_prefs', // per-title remembered quality
    // Added 2026-08-29 — these are plain user settings that were simply never
    // added as the features landed, so a restore silently lost them.
    'reader_prefs', // manga/novel reader defaults + tap zones
    'theme_prefs', // accent colour, Material You
    'nav_prefs', // which tabs the bottom bar shows, and their order
    'search_view_prefs', // search layout (grid vs rows)
    'ui_prefs', // list sort / reveal animation
    'privacy_prefs', // incognito
    'novel_lang_prefs', // novel language filter
    'torrent_prefs', // torrent settings
    'locale_prefs', // app language override
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
