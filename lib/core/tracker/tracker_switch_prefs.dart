import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Remembers which list the My List screen was last switched to (own list vs
/// a tracker), so the tracker switcher re-opens where the viewer left it.
class TrackerSwitchPrefs {
  const TrackerSwitchPrefs._();

  static const String boxName = 'tracker_switch_prefs';
  static const String _key = 'lastTracker';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Display name of the last-picked tracker, or null for the own list.
  static String? lastTracker() {
    final saved = _boxOrNull?.get(_key);
    return saved is String ? saved : null;
  }

  static Future<void> saveLastTracker(String? displayName) async {
    final box = _boxOrNull;
    if (box == null) return;
    try {
      if (displayName == null) {
        await box.delete(_key);
      } else {
        await box.put(_key, displayName);
      }
    } catch (_) {
      // Remembering the view is optional; selecting a list must still work.
    }
  }
}
