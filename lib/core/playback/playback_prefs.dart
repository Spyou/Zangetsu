import 'package:hive/hive.dart';

/// Subtitle font families bundled in the app (registered in pubspec's
/// `flutter: fonts:`). Used by the player's Subtitle-style font picker; the
/// stored value is the mpv `sub-font` family name. The leading empty entry is
/// "Default" (let mpv pick / use the embedded ASS font).
const List<String> kBundledSubtitleFonts = [
  '',
  'Inter',
  'Poppins',
  'Roboto',
  'Open Sans',
  'Lato',
  'Montserrat',
  'Nunito',
  'Rubik',
  'Noto Sans',
  'Source Sans 3',
];

/// (key, label) for the in-player info overlay, in display order. The overlay
/// shows the fields the user ticks (Settings → Playback → Player info overlay)
/// and auto-appears with the player controls. "Stats for nerds"-style.
const List<(String, String)> kPlayerInfoFields = [
  ('resolution', 'Resolution'),
  ('source', 'Source'),
  ('quality', 'Quality'),
  ('vcodec', 'Video codec'),
  ('acodec', 'Audio codec'),
  ('fps', 'Frame rate'),
  ('vbitrate', 'Video bitrate'),
  ('buffer', 'Buffer'),
  ('dropped', 'Dropped frames'),
  ('decoder', 'Decoder'),
  ('speed', 'Speed'),
  ('atrack', 'Audio track'),
  ('strack', 'Subtitle track'),
  ('af', 'Audio boost'),
];

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

  /// Whether the detail-screen hero trailer autoplays once it resolves
  /// (Netflix-style). On by default; off opens it paused with a play button.
  bool get autoplayTrailer =>
      _box.get('autoplayTrailer', defaultValue: true) as bool;
  Future<void> setAutoplayTrailer(bool value) =>
      _box.put('autoplayTrailer', value);

  /// Default playback speed multiplier.
  double get defaultSpeed =>
      (_box.get('defaultSpeed', defaultValue: 1.0) as num).toDouble();
  Future<void> setDefaultSpeed(double value) => _box.put('defaultSpeed', value);

  /// How many seconds a single seek (forward/back) jumps.
  int get seekSeconds =>
      (_box.get('seekSeconds', defaultValue: 10) as num).toInt();
  Future<void> setSeekSeconds(int value) => _box.put('seekSeconds', value);

  /// How many seconds a double-tap-to-seek jumps (±5/10/15/30s). Aliases the
  /// same stored key as [seekSeconds] so the player and the "Double-tap skip"
  /// setting share one source of truth; exposed under this name for clarity at
  /// the double-tap call sites.
  int get doubleTapSeconds => seekSeconds;
  Future<void> setDoubleTapSeconds(int value) => setSeekSeconds(value);

  /// Whether to keep the screen awake while playing.
  bool get keepScreenOn =>
      _box.get('keepScreenOn', defaultValue: true) as bool;
  Future<void> setKeepScreenOn(bool value) => _box.put('keepScreenOn', value);

  /// Auto-enter Picture-in-Picture when leaving the app mid-playback (Android).
  /// The manual PiP button works regardless of this setting.
  bool get autoPip => _box.get('autoPip', defaultValue: true) as bool;
  Future<void> setAutoPip(bool value) => _box.put('autoPip', value);

  /// Route TV playback to the fully-native player (TvPlayerActivity, real-window
  /// SurfaceView) instead of the Flutter platform-view player. Default ON on TV:
  /// the platform-view surface black-screens on some TVs, and the native window
  /// renders directly. Turning it OFF falls back to the old Flutter player.
  /// Phone is unaffected (it never reads this).
  bool get nativeTvPlayer =>
      _box.get('nativeTvPlayer', defaultValue: true) as bool;
  Future<void> setNativeTvPlayer(bool value) =>
      _box.put('nativeTvPlayer', value);

  /// Enable FFmpeg software audio decoding in the native TV player, so TVs that
  /// lack hardware Dolby (AC3/E-AC3) or DTS play those tracks instead of going
  /// silent. Off by default — CloudStream disables it on TV by default too
  /// ("because of crashes"), so it's strictly opt-in. Hardware decoders stay
  /// preferred (EXTENSION_RENDERER_MODE_ON); FFmpeg only fills the gap.
  bool get tvSoftwareDecoding =>
      _box.get('tvSoftwareDecoding', defaultValue: false) as bool;
  Future<void> setTvSoftwareDecoding(bool value) =>
      _box.put('tvSoftwareDecoding', value);

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

  /// In-app volume level (0–200%), applied via mpv's own volume — independent of
  /// the Android system volume. 100 = original loudness; >100 boosts (with
  /// volume-max raised to 200, CloudStream-style).
  int get volumeBoost =>
      (_box.get('volumeBoost', defaultValue: 100) as num).toInt().clamp(0, 200);
  Future<void> setVolumeBoost(int value) =>
      _box.put('volumeBoost', value.clamp(0, 200));

  /// Whether to apply dynamic audio normalization (mpv 'dynaudnorm' filter) so
  /// quiet/loud passages are levelled out.
  bool get audioNormalize =>
      _box.get('audioNormalize', defaultValue: false) as bool;
  Future<void> setAudioNormalize(bool value) =>
      _box.put('audioNormalize', value);

  /// Video decoder mode. Default 'hw' = hardware (mpv `hwdec=mediacodec-copy`),
  /// exactly today's behaviour. 'hw+' is the faster direct-output hardware path
  /// (some filter limits); 'sw' is software decoding — slower / more battery but
  /// plays codecs the hardware chokes on (fixes stutter / green / black video on
  /// tricky streams); 'auto' lets mpv pick a safe decoder.
  String get videoDecoder =>
      _box.get('videoDecoder', defaultValue: 'hw') as String;
  Future<void> setVideoDecoder(String value) =>
      _box.put('videoDecoder', value);

  /// The mpv `hwdec` property value for the current [videoDecoder] choice.
  String get hwdecValue {
    switch (videoDecoder) {
      case 'hw+':
        return 'mediacodec';
      case 'sw':
        return 'no';
      case 'auto':
        return 'auto-safe';
      case 'hw':
      default:
        return 'mediacodec-copy';
    }
  }

  // ── Anime4K enhancement (GLSL upscaling) ───────────────────────────────────
  // Real-time neural upscaling for low-res anime. STYLE = the filter: 'off'
  // (default), 'a' Sharpen, 'b' De-blur, 'c' Denoise. TIER = GPU cost: 'mid'
  // (light) / 'high' (heavy). Applied via `glsl-shaders`; routed through the
  // gpu-next renderer + deband/HQ-scaling render tuning when style != 'off'.
  String get videoShaderStyle =>
      _box.get('videoShaderStyle', defaultValue: 'off') as String;
  Future<void> setVideoShaderStyle(String value) =>
      _box.put('videoShaderStyle', value);

  String get videoShaderTier =>
      _box.get('videoShaderTier', defaultValue: 'mid') as String;
  Future<void> setVideoShaderTier(String value) =>
      _box.put('videoShaderTier', value);

  // ── Video buffering (mpv cache) ────────────────────────────────────────────
  // Presets, NOT raw values, so a user can't set a footgun. 'default' returns
  // exactly today's hardcoded numbers, so a fresh install / untouched setting is
  // byte-identical. 'low' shrinks the buffers for low-RAM / Android-TV to avoid
  // OOM; 'high' enlarges them for smoother playback on strong devices.
  static const List<String> bufferPresets = ['low', 'default', 'high'];

  /// Forward+back demuxer buffer SIZE preset: 'low' | 'default' | 'high'.
  String get videoBufferSize =>
      _box.get('videoBufferSize', defaultValue: 'default') as String;
  Future<void> setVideoBufferSize(String value) =>
      _box.put('videoBufferSize', value);

  /// Buffer LENGTH (seconds of readahead) preset: 'low' | 'default' | 'high'.
  String get videoBufferLength =>
      _box.get('videoBufferLength', defaultValue: 'default') as String;
  Future<void> setVideoBufferLength(String value) =>
      _box.put('videoBufferLength', value);

  /// mpv `demuxer-max-bytes` for the current size preset (default = 128MiB).
  String get bufferMaxBytes => bufferMaxBytesFor(videoBufferSize);

  /// mpv `demuxer-max-back-bytes`, scaled with the size preset (default = 48MiB).
  String get bufferMaxBackBytes => bufferMaxBackBytesFor(videoBufferSize);

  /// Seconds for mpv `cache-secs` + `demuxer-readahead-secs` (default = 60).
  int get bufferSecs => bufferSecsFor(videoBufferLength);

  // Pure preset→mpv-value maps (static so they're unit-testable without Hive).
  // The 'default' branch MUST return the app's legacy hardcoded values so an
  // untouched setting keeps playback byte-identical.
  static String bufferMaxBytesFor(String preset) {
    switch (preset) {
      case 'low':
        return '32MiB';
      case 'high':
        return '512MiB';
      default:
        return '128MiB';
    }
  }

  static String bufferMaxBackBytesFor(String preset) {
    switch (preset) {
      case 'low':
        return '16MiB';
      case 'high':
        return '128MiB';
      default:
        return '48MiB';
    }
  }

  static int bufferSecsFor(String preset) {
    switch (preset) {
      case 'low':
        return 15;
      case 'high':
        return 120;
      default:
        return 60;
    }
  }

  /// Home hero banner animation: 'cinematic' (cross-fade + Ken-Burns) or
  /// 'parallax' (parallax slide). A/B while we settle on the final one.
  String get heroStyle =>
      _box.get('heroStyle', defaultValue: 'cinematic') as String;
  Future<void> setHeroStyle(String value) => _box.put('heroStyle', value);

  /// Whether to show live scrub-preview thumbnails for ONLINE streams. Offline
  /// downloads always preview (it's instant and free); online generates frames
  /// live, which costs a little extra data, so it's user-toggleable.
  bool get seekPreviewOnline =>
      _box.get('seekPreviewOnline', defaultValue: true) as bool;
  Future<void> setSeekPreviewOnline(bool value) =>
      _box.put('seekPreviewOnline', value);

  /// Which fields the in-player info overlay shows (keys from
  /// [kPlayerInfoFields]). Empty = overlay off. Auto-shown with the controls.
  List<String> get playerInfoFields =>
      (_box.get('playerInfoFields', defaultValue: const <String>[]) as List)
          .cast<String>();
  Future<void> setPlayerInfoFields(List<String> value) =>
      _box.put('playerInfoFields', value);

  /// Show the current quality as plain text on the top-bar right (reDantotsu-
  /// style), fading with the controls — separate from the ⓘ info panel. The
  /// legacy Hive key name is kept. Default off.
  bool get alwaysShowQuality =>
      _box.get('alwaysShowQuality', defaultValue: false) as bool;
  Future<void> setAlwaysShowQuality(bool value) =>
      _box.put('alwaysShowQuality', value);

  /// Whether to show the accurate AniSkip "Skip opening/ending" button (anime,
  /// when real OP/ED timings are detected).
  bool get skipIntro => _box.get('skipIntro', defaultValue: true) as bool;
  Future<void> setSkipIntro(bool value) => _box.put('skipIntro', value);

  /// MegaSkip — a manual "jump forward N seconds" button shown in the player
  /// (Aniyomi-style), independent of the accurate AniSkip OP/ED skip above.
  /// [megaSkip] toggles the button; [megaSkipSeconds] is the jump size, clamped
  /// 5–180s (default 85 ≈ a typical anime opening).
  bool get megaSkip => _box.get('megaSkip', defaultValue: true) as bool;
  Future<void> setMegaSkip(bool value) => _box.put('megaSkip', value);

  static const int megaSkipMin = 5;
  static const int megaSkipMax = 180;
  int get megaSkipSeconds {
    final v = (_box.get('megaSkipSeconds', defaultValue: 85) as num).toInt();
    return v.clamp(megaSkipMin, megaSkipMax);
  }

  Future<void> setMegaSkipSeconds(int value) =>
      _box.put('megaSkipSeconds', value.clamp(megaSkipMin, megaSkipMax));

  /// Default player. Empty string = the built-in player; otherwise the package
  /// id of an external player (e.g. 'org.videolan.vlc') to hand streams to.
  /// [externalPlayerLabel] is the human name shown in settings.
  String get externalPlayerPackage =>
      _box.get('externalPlayerPackage', defaultValue: '') as String;
  String get externalPlayerLabel =>
      _box.get('externalPlayerLabel', defaultValue: '') as String;
  Future<void> setExternalPlayer(String package, String label) async {
    await _box.put('externalPlayerPackage', package);
    await _box.put('externalPlayerLabel', label);
  }

  /// Whether sources flagged NSFW in their repo manifest are shown and usable.
  /// Off by default; turning it on is gated behind a confirmation in Privacy
  /// settings. When off, NSFW sources are hidden from the source list + switcher.
  bool get nsfwSources => _box.get('nsfwSources', defaultValue: false) as bool;
  Future<void> setNsfwSources(bool value) => _box.put('nsfwSources', value);

  /// Whether Aniyomi sources flagged as NSFW (18+) are shown in the source
  /// list and switcher. Off by default; turning it on requires confirmation.
  /// When off, NSFW-flagged Aniyomi providers are hidden at display time;
  /// they remain registered in AniyomiManager and are never unloaded.
  bool get showNsfwAniyomi =>
      _box.get('showNsfwAniyomi', defaultValue: false) as bool;
  Future<void> setShowNsfwAniyomi(bool value) =>
      _box.put('showNsfwAniyomi', value);

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

  /// Subtitle font family — one of [kBundledSubtitleFonts]. Empty = mpv default
  /// (don't override the font). Maps to mpv's `sub-font`.
  String get subtitleFont => _box.get('subtitleFont', defaultValue: '') as String;
  Future<void> setSubtitleFont(String value) => _box.put('subtitleFont', value);

  /// Subtitle text colour as an 8-digit hex (`#RRGGBBAA`), default opaque white.
  /// When non-empty this takes precedence over the legacy [subtitleColor] token.
  String get subtitleColorHex =>
      _box.get('subtitleColorHex', defaultValue: '#FFFFFFFF') as String;
  Future<void> setSubtitleColorHex(String value) =>
      _box.put('subtitleColorHex', value);

  /// Opacity (0–1) of the black box drawn behind subtitles. 0 = no box. When
  /// >0 this takes precedence over the legacy [subtitleBackground] toggle.
  double get subtitleBgOpacity =>
      (_box.get('subtitleBgOpacity', defaultValue: 0.0) as num)
          .toDouble()
          .clamp(0.0, 1.0);
  Future<void> setSubtitleBgOpacity(double value) =>
      _box.put('subtitleBgOpacity', value.clamp(0.0, 1.0));

  /// OpenSubtitles REST API key (https://www.opensubtitles.com/consumers).
  /// Empty by default — the user pastes a free key in Settings to enable online
  /// subtitle search/download. Stored verbatim (trimmed at use sites).
  String get subtitleApiKey =>
      _box.get('subtitleApiKey', defaultValue: '') as String;
  Future<void> setSubtitleApiKey(String value) =>
      _box.put('subtitleApiKey', value);

  /// Vertical subtitle position (0 = top, 100 = bottom), maps to mpv `sub-pos`.
  /// Default 95 keeps subtitles near the bottom edge.
  int get subtitlePosition =>
      (_box.get('subtitlePosition', defaultValue: 95) as num).toInt().clamp(
        0,
        100,
      );
  Future<void> setSubtitlePosition(int value) =>
      _box.put('subtitlePosition', value.clamp(0, 100));

  /// The single global subtitle preference: '' (Auto — no forcing), 'off'
  /// (subtitles off on every video), or an ISO-639-1 language code (auto-select
  /// the source's subtitle in that language). Stored under the legacy
  /// `preferredSubtitleLang` key so an existing language choice migrates as-is.
  String get subtitlePreference =>
      _box.get('preferredSubtitleLang', defaultValue: '') as String;
  Future<void> setSubtitlePreference(String value) =>
      _box.put('preferredSubtitleLang', value);

  /// Target language (ISO-639-1) for subtitle translation — the in-player
  /// picker's default and the auto-translate target. '' = none set yet.
  String get translateSubtitleTo =>
      _box.get('translateSubtitleTo', defaultValue: '') as String;
  Future<void> setTranslateSubtitleTo(String value) =>
      _box.put('translateSubtitleTo', value);

  /// Auto-translate the subtitle into [translateSubtitleTo] on play, when the
  /// source has no subtitle already in that language. Off by default.
  bool get autoTranslateSubtitles =>
      _box.get('autoTranslateSubtitles', defaultValue: false) as bool;
  Future<void> setAutoTranslateSubtitles(bool value) =>
      _box.put('autoTranslateSubtitles', value);

  /// The preference as a *language* code only: '' for Auto or Off, else the
  /// iso1. Callers that want a language (online-search default, Settings label)
  /// use this so the 'off' sentinel never leaks in as a language.
  String get preferredSubtitleLanguage {
    final p = subtitlePreference;
    return p == 'off' ? '' : p;
  }
  Future<void> setPreferredSubtitleLanguage(String value) =>
      setSubtitlePreference(value);

  /// Whether to automatically download subtitles from OpenSubtitles when the
  /// loaded source carries no subtitle in the preferred language. Defaults to
  /// true — the player will attempt a silent download before falling back to
  /// no subtitles. Requires [subtitleApiKey] to be set.
  bool get autoDownloadSubtitles =>
      _box.get('autoDownloadSubtitles', defaultValue: true) as bool;
  Future<void> setAutoDownloadSubtitles(bool value) =>
      _box.put('autoDownloadSubtitles', value);
}
