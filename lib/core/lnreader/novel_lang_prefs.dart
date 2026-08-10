import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

/// Which novel-source languages to show in the LNReader catalog.
///
/// [enabled] returns `null` when the user hasn't configured it yet — the
/// catalog screen then falls back to a device-aware default (English + the
/// phone's language). Once the user opens the Languages sheet and changes
/// anything, the chosen set is stored here; an EMPTY set is respected (distinct
/// from the unconfigured `null`) and the catalog shows a "pick a language"
/// empty state. A [ChangeNotifier] so the sheet + list rebuild live as toggles
/// flip. Backed by a tiny Hive box — same shape as [SearchSourcePrefs].
class NovelLangPrefs extends ChangeNotifier {
  static const String boxName = 'novel_lang_prefs';
  static const String _key = 'enabledLangs';

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  /// The enabled language codes, or `null` when the user hasn't configured it
  /// yet (the screen supplies its own default in that case). Also null when the
  /// box isn't open (e.g. a test that never called [init]) — treated as
  /// unconfigured rather than crashing.
  Set<String>? get enabled {
    if (!Hive.isBoxOpen(boxName)) return null;
    final raw = Hive.box(boxName).get(_key);
    if (raw is List) return {for (final e in raw) '$e'};
    return null;
  }

  /// Replace the enabled set (persists + notifies). An empty set is valid and
  /// means "none" — not the same as the unconfigured `null` above.
  Future<void> setEnabled(Set<String> langs) async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_key, langs.toList());
    notifyListeners();
  }
}
