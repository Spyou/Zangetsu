import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import 'debrid_provider.dart';

/// Non-secret debrid prefs (mode + which service is active). Tokens live in
/// [DebridTokenStore], not here.
class DebridPrefs {
  static const String boxName = 'debrid_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  DebridMode get mode => DebridMode.fromName(_box.get('mode') as String?);

  Future<void> setMode(DebridMode value) => _box.put('mode', value.name);

  /// Last service the user picked. Null = "first connected".
  DebridService? get activeService {
    final raw = _box.get('activeService') as String?;
    return switch (raw) {
      'realDebrid' => DebridService.realDebrid,
      'torbox' => DebridService.torbox,
      _ => null,
    };
  }

  Future<void> setActiveService(DebridService? value) async {
    if (value == null) {
      await _box.delete('activeService');
    } else {
      await _box.put('activeService', value.name);
    }
  }
}
