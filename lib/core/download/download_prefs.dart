import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Whether a stored download path is a SAF content:// URI (vs a plain file
/// path). Used to route delete through UriUtils instead of dart:io File.
bool isUriPath(String path) => path.startsWith('content://');

/// What to tell the user their downloads are going to. Private storage has a
/// name of its own; without this the UI would name a folder the files never
/// reach.
String downloadDestinationLabel({
  required bool keepPrivate,
  required String? locationLabel,
  required String publicFallback,
}) =>
    keepPrivate ? 'Private (app storage)' : (locationLabel ?? publicFallback);

/// Persists the user's chosen download folder (a SAF tree URI) for MP4
/// downloads. Null = the default Downloads/Zangetsu location.
class DownloadPrefs {
  static const String boxName = 'download_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
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

  /// Keep finished video downloads in app-private storage instead of copying
  /// them to the public Downloads folder. Applies to NEW downloads only —
  /// files already downloaded stay where they are.
  ///
  /// Off by default: files in the private directory are invisible to every
  /// file manager and are deleted when the app is uninstalled.
  bool get keepPrivate =>
      _box.get('keepPrivate', defaultValue: false) as bool;

  Future<void> setKeepPrivate(bool value) => _box.put('keepPrivate', value);

  // ── Parallel downloads (CloudStream-style) ────────────────────────────────
  // Only the HLS path was serial (one episode at a time); MP4 already runs
  // concurrently via background_downloader. These govern the HLS worker pool.
  static const int parallelMin = 1;
  static const int parallelMax = 10;
  static const int connectionsMin = 1;
  static const int connectionsMax = 8;

  /// How many different episodes download at the same time. Default 3.
  int get parallelDownloads =>
      (_box.get('parallel') as int? ?? 3).clamp(parallelMin, parallelMax);

  Future<void> setParallelDownloads(int n) =>
      _box.put('parallel', n.clamp(parallelMin, parallelMax));

  /// How many segment connections a single HLS download uses. Default 4.
  int get connectionsPerDownload =>
      (_box.get('connections') as int? ?? 4).clamp(connectionsMin, connectionsMax);

  Future<void> setConnectionsPerDownload(int n) =>
      _box.put('connections', n.clamp(connectionsMin, connectionsMax));
}
