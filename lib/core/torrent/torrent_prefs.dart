import 'package:hive/hive.dart';

/// Persists torrent behavior prefs. `allowMobileData` defaults to false =
/// torrents only run on Wi-Fi (protects mobile data).
class TorrentPrefs {
  static const String boxName = 'torrent_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  bool get allowMobileData =>
      _box.get('allowMobileData', defaultValue: false) as bool;

  Future<void> setAllowMobileData(bool value) =>
      _box.put('allowMobileData', value);
}
