import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../../core/hive/safe_box.dart';

/// Phone remote look-and-feel choices. Defaults apply until [init] has read
/// the box, and stay in place when Hive was never set up (widget tests).
class RemotePrefs extends ChangeNotifier {
  RemotePrefs._();

  /// App-wide singleton; remote widgets listen to it to rebuild on changes.
  static final RemotePrefs instance = RemotePrefs._();

  /// Name of the Hive box that persists these preferences.
  static const String boxName = 'remote_prefs';

  /// Box key holding the [showLabels] bool.
  static const String _labelsKey = 'showLabels';

  /// In-memory value of [showLabels]; labels are shown by default.
  bool _showLabels = true;

  /// Whether remote pills and chips show their names next to the icons.
  bool get showLabels => _showLabels;

  /// Storage is touched only once [init] ran (the remote screen calls it), so
  /// widgets built in tests without Hive keep the in-memory defaults.
  static bool _storage = false;

  /// Returns the prefs box, or null when storage is off or it fails to open.
  static Future<Box?> _open() async {
    if (!_storage) return null;
    try {
      return Hive.isBoxOpen(boxName)
          ? Hive.box(boxName)
          : await openBoxSafely(boxName);
    } catch (e) {
      debugPrint('[RemotePrefs] could not open $boxName ($e)');
      return null;
    }
  }

  /// Loads stored choices; safe to call repeatedly and before Hive exists.
  static Future<void> init() async {
    _storage = true;
    final box = await _open();
    final stored = box?.get(_labelsKey);
    if (stored is bool && stored != instance._showLabels) {
      instance._showLabels = stored;
      instance.notifyListeners();
    }
  }

  /// Updates [showLabels], notifies listeners right away, then saves it to
  /// the box; a failed save is only logged and the in-memory value is kept.
  Future<void> setShowLabels(bool value) async {
    if (value == _showLabels) return;
    _showLabels = value;
    notifyListeners();
    try {
      await (await _open())?.put(_labelsKey, value);
    } catch (e) {
      debugPrint('[RemotePrefs] could not save $_labelsKey ($e)');
    }
  }

  /// Puts the defaults back between tests.
  @visibleForTesting
  void resetForTest() {
    _showLabels = true;
    notifyListeners();
  }
}
