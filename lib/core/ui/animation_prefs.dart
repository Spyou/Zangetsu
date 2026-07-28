import 'package:hive/hive.dart';

/// One toggle: whether list/grid items animate in (the Dantotsu-style cascade).
/// Kept as an in-memory bool so [RevealItem] can read it per-item for free; the
/// Hive box is only touched at init and when the user flips the switch.
class AnimationPrefs {
  static const String boxName = 'ui_prefs';
  static const String _key = 'listAnimations';

  /// Live value read by every reveal. Defaults on; loaded from Hive at startup.
  static bool listAnimations = true;

  static Future<void> init() async {
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await Hive.openBox(boxName);
    listAnimations = box.get(_key, defaultValue: true) as bool;
  }

  static Future<void> setListAnimations(bool value) async {
    listAnimations = value;
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await Hive.openBox(boxName);
    await box.put(_key, value);
  }
}
