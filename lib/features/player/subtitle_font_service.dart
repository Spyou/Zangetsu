import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show FontLoader;
import '../../core/di/injector.dart';
import '../../core/platform/app_paths.dart';
import '../../core/playback/font_family_name.dart';

import '../../core/playback/playback_prefs.dart'
    show PlaybackPrefs, kBundledSubtitleFonts;
import '../../core/playback/tv_track_helpers.dart' show subtitleFontFileName;

/// Download-on-demand for subtitle fonts. Only Inter (UI font) and Noto Sans
/// (the libass Android fallback) ship in the APK; the rest are fetched from the
/// app's own public repo on first pick, cached to `<appSupport>/sub_fonts/`, and
/// registered with Flutter's [FontLoader] so the overlay + preview can use them.
/// The same folder is mpv's `sub-fonts-dir`, so libass sees them too.
///
/// Best-effort throughout: a failed download just means the picked font falls
/// back to the default until it's fetched — subtitles are never broken.
class SubtitleFontService {
  SubtitleFontService._();
  static final SubtitleFontService instance = SubtitleFontService._();

  /// Families bundled in the APK (registered in pubspec) — always available.
  static const Set<String> bundled = {'Inter', 'Noto Sans'};

  static const String _base =
      'https://raw.githubusercontent.com/Spyou/AniAura/main/assets/fonts/';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  final Set<String> _registered = {}; // FontLoader-registered this session
  Directory? _dir;

  Future<Directory> _fontsDir() async {
    final d = _dir ??= await writableAppSubdir('sub_fonts');
    return d;
  }

  /// Drop the cached directory and the FontLoader bookkeeping.
  ///
  /// This is a process-wide singleton, so without it a test would keep the
  /// previous test's temp folder and its registrations.
  @visibleForTesting
  void resetForTest() {
    _dir = null;
    _registered.clear();
  }

  /// Families handed to [FontLoader] this session. Only the overlay can tell
  /// whether a font was registered, so tests read it from here.
  @visibleForTesting
  Set<String> get registeredForTest => _registered;

  /// The user's own fonts: family → filename in the same `sub_fonts/` folder.
  ///
  /// Read through GetIt rather than injected because this is a singleton the
  /// player reaches for directly, and it must degrade to "no custom fonts"
  /// rather than throw in a shell that has not registered prefs yet.
  Map<String, String> get _customs => sl.isRegistered<PlaybackPrefs>()
      ? sl<PlaybackPrefs>().customSubtitleFonts
      : const {};

  /// Filename for [family], whether it was downloaded or added by the user.
  ///
  /// Custom fonts are checked FIRST: [subtitleFontFileName] only knows the ten
  /// built-in families and returns null for anything else, so a custom family
  /// would otherwise look unavailable everywhere.
  String? _fileNameFor(String family) =>
      _customs[family] ?? subtitleFontFileName(family);

  /// True when [family] is usable right now (Default, bundled, downloaded, or
  /// a custom font whose file is still on disk).
  Future<bool> isAvailable(String family) async {
    if (family.isEmpty || bundled.contains(family)) return true;
    final fname = _fileNameFor(family);
    if (fname == null) return false;
    final dir = await _fontsDir();
    return File('${dir.path}/$fname').existsSync();
  }

  /// Ensure [family] is downloaded + registered. Returns true if usable after
  /// (already-available counts as success). Never throws.
  ///
  /// A custom font is never downloaded — its file is already local, so a
  /// missing one is simply false (the user deleted it) and the caller falls
  /// back to the default.
  Future<bool> ensure(String family) async {
    if (family.isEmpty || bundled.contains(family)) return true;
    final custom = _customs[family];
    if (custom != null) {
      try {
        final dir = await _fontsDir();
        final f = File('${dir.path}/$custom');
        if (!f.existsSync()) return false;
        await _register(family, f);
        return true;
      } catch (_) {
        return false;
      }
    }
    final fname = subtitleFontFileName(family);
    if (fname == null) return false;
    try {
      final dir = await _fontsDir();
      final f = File('${dir.path}/$fname');
      if (!f.existsSync()) {
        final resp = await _dio.get<List<int>>(
          '$_base$fname',
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = resp.data;
        if (bytes == null || bytes.isEmpty) return false;
        await f.writeAsBytes(bytes, flush: true);
      }
      await _register(family, f);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _register(String family, File f) async {
    if (_registered.contains(family)) return;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _registered.add(family);
    } catch (_) {}
  }

  /// Register every already-downloaded font with Flutter, so the overlay can
  /// use them immediately after a restart. Called once on player init.
  ///
  /// Custom fonts are included: [FontLoader] registrations do not survive a
  /// restart, so without this a font the user added would silently stop being
  /// applied the next time they opened the app.
  Future<void> registerCached() async {
    try {
      final dir = await _fontsDir();
      final families = <String, String>{
        for (final family in kBundledSubtitleFonts)
          if (family.isNotEmpty && !bundled.contains(family))
            family: ?subtitleFontFileName(family),
        ..._customs,
      };
      for (final e in families.entries) {
        final f = File('${dir.path}/${e.value}');
        if (f.existsSync()) await _register(e.key, f);
      }
    } catch (_) {}
  }

  /// Copy a font the user picked into `sub_fonts/` and remember it.
  ///
  /// Returns the family name to store in `subtitleFont`, or null when the file
  /// could not be read. The family comes from the font's own name table
  /// ([fontFamilyFromBytes]) because libass matches `sub-font` against that,
  /// not against the filename; the filename stem is only a fallback so a font
  /// with an unreadable name table still works in the overlay and on TV.
  Future<String?> addCustomFont(String sourcePath) async {
    try {
      final src = File(sourcePath);
      final bytes = await src.readAsBytes();
      if (bytes.isEmpty) return null;

      final stem = sourcePath
          .split('/')
          .last
          .replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');
      var family = (fontFamilyFromBytes(bytes) ?? stem).trim();
      if (family.isEmpty) return null;

      // Never shadow a built-in: two entries with one name would make the
      // picker ambiguous and the wrong file could win in sub-fonts-dir.
      final taken = {...kBundledSubtitleFonts, ..._customs.keys};
      if (taken.contains(family)) {
        var n = 2;
        while (taken.contains('$family ($n)')) {
          n++;
        }
        family = '$family ($n)';
      }

      final ext = sourcePath.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf';
      final safe = family.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      // custom_ prefix so a user's "Roboto-Regular.ttf" can never overwrite the
      // downloaded one sitting in the same folder.
      final fname = 'custom_$safe.$ext';

      final dir = await _fontsDir();
      await File('${dir.path}/$fname').writeAsBytes(bytes, flush: true);

      final prefs = sl<PlaybackPrefs>();
      await prefs.setCustomSubtitleFonts({
        ...prefs.customSubtitleFonts,
        family: fname,
      });
      await _register(family, File('${dir.path}/$fname'));
      return family;
    } catch (_) {
      return null;
    }
  }

  /// Forget a custom font and delete its file.
  ///
  /// Clearing [PlaybackPrefs.subtitleFont] when the removed font was the
  /// selected one matters: leaving it set would name a family with no file, and
  /// subtitles would quietly render in the default with no way to tell why.
  Future<void> removeCustomFont(String family) async {
    try {
      final prefs = sl<PlaybackPrefs>();
      final map = {...prefs.customSubtitleFonts};
      final fname = map.remove(family);
      await prefs.setCustomSubtitleFonts(map);
      if (prefs.subtitleFont == family) await prefs.setSubtitleFont('');
      _registered.remove(family);
      if (fname != null) {
        final dir = await _fontsDir();
        final f = File('${dir.path}/$fname');
        if (f.existsSync()) await f.delete();
      }
    } catch (_) {}
  }
}
