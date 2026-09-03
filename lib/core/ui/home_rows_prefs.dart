import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Saved home-screen row arrangements, per layout.
///
/// One layout = one way the home screen can be composed: the metadata
/// provider (AniList / MAL / Simkl / TMDB) combined with the app mode, or a
/// non-metadata source. Each layout key maps to ONE ordered list of row ids
/// holding every row that existed when it was saved, hidden rows prefixed
/// with `!` — the exact shape [HomeRowsComposer] sanitizes and merges, so
/// "never customized" and "customized" run through the same code path.
///
/// This class is deliberately dumb storage: it never interprets an id. The
/// meaning of `!`, the defaults, and the sanitize rules all live in the
/// composer, which is the single home of that logic.
class HomeRowsPrefs {
  const HomeRowsPrefs._();

  static const String boxName = 'home_rows_prefs';

  /// Bumped on every change so listeners (main.dart) can reload Home without
  /// resetting its scroll — same shape as `ZModePrefs.revision`.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The saved arrangement for [layoutKey], or null when never customized —
  /// the caller then starts from the default layout. Entries are raw stored
  /// strings (a hidden row's id still carries its `!` prefix).
  static List<String>? savedFor(String layoutKey) =>
      (_boxOrNull?.get(layoutKey) as List?)?.cast<String>();

  /// Persist the full arrangement for [layoutKey] (order + `!` marks).
  static Future<void> save(String layoutKey, List<String> entries) async {
    final box = _boxOrNull;
    if (box == null) return;
    await box.put(layoutKey, entries);
    revision.value++;
  }

  /// Back to the shipped arrangement for one layout.
  static Future<void> resetFor(String layoutKey) async {
    final box = _boxOrNull;
    if (box == null) return;
    await box.delete(layoutKey);
    revision.value++;
  }
}
