import 'package:hive/hive.dart';

/// Persistent, app-wide playback preferences (default quality, sub/dub
/// category, autoplay, speed, seek step, keep-screen-on, auto-resume). Backed
/// by a tiny untyped Hive box read anywhere via `sl<PlaybackPrefs>()`. Values
/// are read with defaults so a fresh install behaves sensibly; numbers are
/// coerced defensively since Hive may round-trip them as `int`/`double`/`num`.
class PlaybackPrefs {
  static const String boxName = 'playback_prefs';

  /// Opens the prefs box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  /// Preferred stream quality: 'auto'|'highest'|'1080p'|'720p'|'480p'.
  String get defaultQuality =>
      _box.get('defaultQuality', defaultValue: 'auto') as String;
  Future<void> setDefaultQuality(String value) =>
      _box.put('defaultQuality', value);

  /// Preferred audio category: 'sub'|'dub'.
  String get defaultCategory =>
      _box.get('defaultCategory', defaultValue: 'sub') as String;
  Future<void> setDefaultCategory(String value) =>
      _box.put('defaultCategory', value);

  /// Whether to automatically start the next episode when one finishes.
  bool get autoplayNext =>
      _box.get('autoplayNext', defaultValue: true) as bool;
  Future<void> setAutoplayNext(bool value) => _box.put('autoplayNext', value);

  /// Default playback speed multiplier.
  double get defaultSpeed =>
      (_box.get('defaultSpeed', defaultValue: 1.0) as num).toDouble();
  Future<void> setDefaultSpeed(double value) => _box.put('defaultSpeed', value);

  /// How many seconds a single seek (forward/back) jumps.
  int get seekSeconds =>
      (_box.get('seekSeconds', defaultValue: 10) as num).toInt();
  Future<void> setSeekSeconds(int value) => _box.put('seekSeconds', value);

  /// Whether to keep the screen awake while playing.
  bool get keepScreenOn =>
      _box.get('keepScreenOn', defaultValue: true) as bool;
  Future<void> setKeepScreenOn(bool value) => _box.put('keepScreenOn', value);

  /// Whether to resume a title from its saved position automatically.
  bool get autoResume => _box.get('autoResume', defaultValue: true) as bool;
  Future<void> setAutoResume(bool value) => _box.put('autoResume', value);

  /// Whether vertical swipe gestures in the player adjust brightness (left half)
  /// and volume (right half), MX/Netflix-style.
  bool get gestureControls =>
      _box.get('gestureControls', defaultValue: true) as bool;
  Future<void> setGestureControls(bool value) =>
      _box.put('gestureControls', value);

  /// Whether long-pressing the video plays at 2× while held.
  bool get holdSpeed => _box.get('holdSpeed', defaultValue: true) as bool;
  Future<void> setHoldSpeed(bool value) => _box.put('holdSpeed', value);

  /// Whether to show a "Skip intro" button early in each episode.
  bool get skipIntro => _box.get('skipIntro', defaultValue: true) as bool;
  Future<void> setSkipIntro(bool value) => _box.put('skipIntro', value);

  /// Seconds a "Skip intro" tap jumps forward (typical anime OP ≈ 85s).
  int get skipIntroSeconds =>
      (_box.get('skipIntroSeconds', defaultValue: 85) as num).toInt();
  Future<void> setSkipIntroSeconds(int value) =>
      _box.put('skipIntroSeconds', value);

  // ── Subtitle styling (applied via mpv) ─────────────────────────────────────
  /// Subtitle size multiplier: 0.8 (small) / 1.0 / 1.3 (large).
  double get subtitleScale =>
      (_box.get('subtitleScale', defaultValue: 1.0) as num).toDouble();
  Future<void> setSubtitleScale(double value) =>
      _box.put('subtitleScale', value);

  /// Subtitle text colour: 'white' | 'yellow'.
  String get subtitleColor =>
      _box.get('subtitleColor', defaultValue: 'white') as String;
  Future<void> setSubtitleColor(String value) =>
      _box.put('subtitleColor', value);

  /// Whether to draw a translucent box behind subtitles.
  bool get subtitleBackground =>
      _box.get('subtitleBackground', defaultValue: false) as bool;
  Future<void> setSubtitleBackground(bool value) =>
      _box.put('subtitleBackground', value);
}
