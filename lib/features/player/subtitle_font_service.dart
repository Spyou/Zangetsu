import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path_provider/path_provider.dart';

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

  /// family name (matches [kBundledSubtitleFonts]) → .ttf filename in the repo.
  static const Map<String, String> _files = {
    'Inter': 'Inter.ttf',
    'Poppins': 'Poppins-Regular.ttf',
    'Roboto': 'Roboto-Regular.ttf',
    'Open Sans': 'OpenSans-Regular.ttf',
    'Lato': 'Lato-Regular.ttf',
    'Montserrat': 'Montserrat-Regular.ttf',
    'Nunito': 'Nunito-Regular.ttf',
    'Rubik': 'Rubik-Regular.ttf',
    'Noto Sans': 'NotoSans-Regular.ttf',
    'Source Sans 3': 'SourceSans3-Regular.ttf',
  };

  /// Families bundled in the APK (registered in pubspec) — always available.
  static const Set<String> bundled = {'Inter', 'Noto Sans'};

  static const String _base =
      'https://raw.githubusercontent.com/Spyou/Zangetsu/main/assets/fonts/';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
  ));
  final Set<String> _registered = {}; // FontLoader-registered this session
  Directory? _dir;

  Future<Directory> _fontsDir() async {
    final d = _dir ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/sub_fonts',
    );
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// True when [family] is usable right now (Default, bundled, or downloaded).
  Future<bool> isAvailable(String family) async {
    if (family.isEmpty || bundled.contains(family)) return true;
    final fname = _files[family];
    if (fname == null) return false;
    final dir = await _fontsDir();
    return File('${dir.path}/$fname').existsSync();
  }

  /// Ensure [family] is downloaded + registered. Returns true if usable after
  /// (already-available counts as success). Never throws.
  Future<bool> ensure(String family) async {
    if (family.isEmpty || bundled.contains(family)) return true;
    final fname = _files[family];
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
  Future<void> registerCached() async {
    try {
      final dir = await _fontsDir();
      for (final entry in _files.entries) {
        if (bundled.contains(entry.key)) continue;
        final f = File('${dir.path}/${entry.value}');
        if (f.existsSync()) await _register(entry.key, f);
      }
    } catch (_) {}
  }
}
