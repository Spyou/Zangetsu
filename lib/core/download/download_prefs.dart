import 'package:hive/hive.dart';

/// Whether a stored download path is a SAF content:// URI (vs a plain file
/// path). Used to route delete through UriUtils instead of dart:io File.
bool isUriPath(String path) => path.startsWith('content://');

/// Persists the user's chosen download folder (a SAF tree URI) for MP4
/// downloads. Null = the default Downloads/Zangetsu location.
class DownloadPrefs {
  static const String boxName = 'download_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  /// The picked SAF directory tree URI, or null for the default location.
  String? get locationUri => _box.get('locationUri') as String?;

  /// A short human name for the picked folder (for the settings subtitle).
  String? get locationLabel => _box.get('locationLabel') as String?;

  Future<void> setLocation(String? uri, String? label) async {
    if (uri == null) {
      await _box.delete('locationUri');
      await _box.delete('locationLabel');
    } else {
      await _box.put('locationUri', uri);
      await _box.put('locationLabel', label);
    }
  }
}
