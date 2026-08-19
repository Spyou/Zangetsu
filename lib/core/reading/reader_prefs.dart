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
  /// Page reading direction: 'ltr' | 'rtl' | 'vertical'. Kept working
  /// untouched — [readingMode] below is the new, wider enum and migrates
  /// from this key; the reader itself still reads `direction` directly.
  String get direction => _box.get('direction', defaultValue: 'ltr') as String;
  Future<void> setDirection(String value) => _box.put('direction', value);

  /// Reader background colour: 'black' | 'dark'. Kept working untouched —
  /// [mangaBackground] below is the new, wider enum and migrates from this
  /// key; the reader itself still reads `background` directly.
  String get background =>
      _box.get('background', defaultValue: 'black') as String;
  Future<void> setBackground(String value) => _box.put('background', value);

  /// Whether to keep the screen awake while reading. Shared by both readers
  /// via `ReaderComfortMixin`.
  bool get keepScreenOn =>
      _box.get('keepScreenOn', defaultValue: true) as bool;
  Future<void> setKeepScreenOn(bool value) => _box.put('keepScreenOn', value);

  /// How many pages ahead the reader warms into the disk cache after landing
  /// on a page. Six rather than the three we started with: preloading only
  /// fetches bytes now, so the extra runway costs disk and network instead of
  /// the memory it used to.
  int get preloadCount =>
      (_box.get('preloadCount', defaultValue: 6) as num).toInt().clamp(1, 8);
  Future<void> setPreloadCount(int value) =>
      _box.put('preloadCount', value.clamp(1, 8));

  /// Reading mode: 'ltr' | 'rtl' | 'vertical_paged' | 'webtoon'. Migrate-on-
  /// read from the legacy `direction` key (ltr→ltr, rtl→rtl,
  /// vertical→webtoon) until this key is explicitly written, so a fresh
  /// install and an existing install both start out reading exactly as
  /// `direction` says today.
  String get readingMode {
    final v = _box.get('readingMode') as String?;
    if (v != null) return v;
    return switch (direction) {
      'rtl' => 'rtl',
      'vertical' => 'webtoon',
      _ => 'ltr',
    };
  }

  Future<void> setReadingMode(String value) =>
      _box.put('readingMode', value);

  /// Page fit: 'contain' | 'width' | 'height' | 'original' | 'smart'.
  /// Default 'contain' renders identically to the reader's current hardcoded
  /// `BoxFit.contain`/`BoxFit.fitWidth`.
  String get fitMode => _box.get('fitMode', defaultValue: 'contain') as String;
  Future<void> setFitMode(String value) => _box.put('fitMode', value);

  /// Manga background: 'black' | 'white' | 'gray' | 'system'. Migrate-on-read
  /// from the legacy `background` key (black→black, dark→system, since
  /// 'dark' already renders the app's own theme background) until this key
  /// is explicitly written.
  String get mangaBackground {
    final v = _box.get('mangaBackground') as String?;
    if (v != null) return v;
    return background == 'black' ? 'black' : 'system';
  }

  Future<void> setMangaBackground(String value) =>
      _box.put('mangaBackground', value);

  /// Pair facing pages into a landscape double-page spread.
  bool get doublePageLandscape =>
      _box.get('doublePageLandscape', defaultValue: false) as bool;
  Future<void> setDoublePageLandscape(bool value) =>
      _box.put('doublePageLandscape', value);

  /// Trim near-uniform edge margins from a page.
  bool get cropBorders => _box.get('cropBorders', defaultValue: false) as bool;
  Future<void> setCropBorders(bool value) => _box.put('cropBorders', value);

  /// Gap in logical pixels between pages in webtoon (vertical) mode.
  double get webtoonPageGap =>
      (_box.get('webtoonPageGap', defaultValue: 0.0) as num).toDouble();
  Future<void> setWebtoonPageGap(double value) =>
      _box.put('webtoonPageGap', value);

  /// Reading colour filter: 'none' | 'grayscale' | 'invert' | 'sepia'.
  String get colorFilter =>
      _box.get('colorFilter', defaultValue: 'none') as String;
  Future<void> setColorFilter(String value) => _box.put('colorFilter', value);

  // ── Shared comfort (both readers) ──────────────────────────────────────
  /// Screen brightness override, 0..1, or -1 for "system" — i.e. no
  /// override, matching the player's own default and today's reader
  /// behavior (the reader has never touched brightness before this).
  double get brightness =>
      (_box.get('brightness', defaultValue: -1.0) as num)
          .toDouble()
          .clamp(-1.0, 1.0);
  Future<void> setBrightness(double value) =>
      _box.put('brightness', value.clamp(-1.0, 1.0));

  /// Orientation lock while reading: 'system' | 'portrait' | 'landscape'.
  /// Default 'system' applies no lock — today's behavior.
  String get orientation =>
      _box.get('orientation', defaultValue: 'system') as String;
  Future<void> setOrientation(String value) => _box.put('orientation', value);

  // ── Novel (typography) ─────────────────────────────────────────────────
  /// Body font family: 'inter' | 'serif' | 'system'.
  String get fontFamily =>
      _box.get('fontFamily', defaultValue: 'inter') as String;
  Future<void> setFontFamily(String value) => _box.put('fontFamily', value);

  /// Whether body text is justified instead of ragged-edge.
  bool get textAlignJustify =>
      _box.get('textAlignJustify', defaultValue: false) as bool;
  Future<void> setTextAlignJustify(bool value) =>
      _box.put('textAlignJustify', value);

  /// Extra spacing (logical pixels) between paragraphs.
  double get paragraphSpacing =>
      (_box.get('paragraphSpacing', defaultValue: 8.0) as num).toDouble();
  Future<void> setParagraphSpacing(double value) =>
      _box.put('paragraphSpacing', value);

  /// Whether the novel reader paginates into book-style pages instead of one
  /// continuous scroll.
  bool get novelPaginated =>
      _box.get('novelPaginated', defaultValue: false) as bool;
  Future<void> setNovelPaginated(bool value) =>
      _box.put('novelPaginated', value);

  /// Novel text direction: 'auto' | 'ltr' | 'rtl'. 'auto' detects RTL scripts
  /// (Arabic, Hebrew, ...) from the chapter text itself so Arabic novels read
  /// right-to-left without the user having to flip a setting per source.
  String get textDirection =>
      _box.get('textDirection', defaultValue: 'auto') as String;
  Future<void> setTextDirection(String value) =>
      _box.put('textDirection', value);
}
