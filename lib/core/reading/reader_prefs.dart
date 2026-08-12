import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Persistent reader settings — the manga/novel analogue of PlaybackPrefs.
/// Backed by a tiny untyped Hive box read anywhere via `sl<ReaderPrefs>()`.
/// Values are read with defaults so a fresh install behaves sensibly; numbers
/// are coerced defensively since Hive may round-trip them as `int`/`double`/
/// `num`.
class ReaderPrefs {
  static const String boxName = 'reader_prefs';

  /// Opens the prefs box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  // ── Novel ───────────────────────────────────────────────────────────────
  /// Reader text size in logical pixels.
  double get fontSize =>
      (_box.get('fontSize', defaultValue: 16.0) as num).toDouble();
  Future<void> setFontSize(double value) => _box.put('fontSize', value);

  /// Line-height multiplier for reader body text.
  double get lineHeight =>
      (_box.get('lineHeight', defaultValue: 1.6) as num).toDouble();
  Future<void> setLineHeight(double value) => _box.put('lineHeight', value);

  /// Reader background/text theme: 'dark' | 'black' | 'sepia'.
  String get theme => _box.get('theme', defaultValue: 'dark') as String;
  Future<void> setTheme(String value) => _box.put('theme', value);

  /// Horizontal side margin (logical pixels) around reader text.
  double get marginWidth =>
      (_box.get('marginWidth', defaultValue: 20.0) as num).toDouble();
  Future<void> setMarginWidth(double value) => _box.put('marginWidth', value);

  // ── Manga ───────────────────────────────────────────────────────────────
  /// Page reading direction: 'ltr' | 'rtl' | 'vertical'.
  String get direction => _box.get('direction', defaultValue: 'ltr') as String;
  Future<void> setDirection(String value) => _box.put('direction', value);

  /// Reader background colour: 'black' | 'dark'.
  String get background =>
      _box.get('background', defaultValue: 'black') as String;
  Future<void> setBackground(String value) => _box.put('background', value);

  /// Whether to keep the screen awake while reading.
  bool get keepScreenOn =>
      _box.get('keepScreenOn', defaultValue: true) as bool;
  Future<void> setKeepScreenOn(bool value) => _box.put('keepScreenOn', value);

  /// How many pages ahead the reader precaches after landing on a page.
  /// Default (3) matches the reader's original hardcoded window, so a fresh
  /// install and an upgrade both preload exactly as much as before.
  int get preloadCount =>
      (_box.get('preloadCount', defaultValue: 3) as num).toInt().clamp(1, 8);
  Future<void> setPreloadCount(int value) =>
      _box.put('preloadCount', value.clamp(1, 8));
}
