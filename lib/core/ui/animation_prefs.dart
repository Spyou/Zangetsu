import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// One toggle: whether list/grid items animate in (the cascade reveal).
/// Kept as an in-memory bool so [RevealItem] can read it per-item for free; the
/// Hive box is only touched at init and when the user flips the switch.
class AnimationPrefs {
  static const String boxName = 'ui_prefs';
  static const String _key = 'listAnimations';

  /// Live value read by every reveal. On by default (a subtle fade + slide);
  /// users can turn it off in Settings → Appearance → Motion.
  static bool listAnimations = true;

  static Future<void> init() async {
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    listAnimations = box.get(_key, defaultValue: true) as bool;
  }

  static Future<void> setListAnimations(bool value) async {
    listAnimations = value;
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    await box.put(_key, value);
  }
}
