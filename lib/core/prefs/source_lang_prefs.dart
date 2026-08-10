import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Which source languages to show in an install catalog. One instance per
/// content type (manga/anime), each backed by its own tiny Hive box.
///
/// Shape mirrors `NovelLangPrefs`: [enabled] is `null` until the user
/// configures it (the screen falls back to a device-aware default then); an
/// empty set is respected (distinct from `null`). A [ChangeNotifier] so the
/// picker + repo lists rebuild live as toggles flip. Box-guarded — returns
/// `null` / no-ops when the box isn't open, so a widget test can register it
/// without spinning up Hive.
///
/// (Novels keep their own `NovelLangPrefs` — its `lang` values are native
/// names, not the ISO codes these two use — so this stays a separate class.)
class LangPrefs extends ChangeNotifier {
  LangPrefs(this.boxName);

  final String boxName;
  static const String _key = 'enabledLangs';

  static Future<void> initBox(String boxName) async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  /// Opens the backing box. Call once during bootstrap before the picker reads.
  Future<void> init() => initBox(boxName);

  /// The enabled base language codes, or `null` when unconfigured (or the box
  /// isn't open) — the screen supplies its own default in that case.
  Set<String>? get enabled {
    if (!Hive.isBoxOpen(boxName)) return null;
    final raw = Hive.box(boxName).get(_key);
    if (raw is List) return {for (final e in raw) '$e'};
    return null;
  }

  /// Replace the enabled set (persists + notifies). An empty set is valid and
  /// means "none" — not the same as the unconfigured `null`.
  Future<void> setEnabled(Set<String> langs) async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_key, langs.toList());
    notifyListeners();
  }
}

/// Language filter for the Mihon (manga) source catalog.
class MangaLangPrefs extends LangPrefs {
  MangaLangPrefs() : super('manga_lang_prefs');
}

/// Language filter for the Aniyomi (anime) source catalog — shared by the
/// phone and TV screens.
class AnimeLangPrefs extends LangPrefs {
  AnimeLangPrefs() : super('aniyomi_lang_prefs');
}
