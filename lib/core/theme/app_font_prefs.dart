import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../features/player/subtitle_font_service.dart';
import '../hive/safe_box.dart';
import 'app_text.dart';

/// One font the UI can be drawn in.
///
/// Only families that carry REAL weights are offered. A single-weight file
/// makes Flutter fake the bold by smearing the glyphs, and every heading in
/// the app is w600 or heavier — Poppins and Lato are both bundled and both
/// look wrong under that, so they are deliberately not here.
class AppFont {
  const AppFont(this.family, this.label, {this.bundled = false});

  /// For a bundled font, must match the `family:` in pubspec.yaml. For the
  /// rest, must match a key of `subtitleFontFileName` — that is what names the
  /// file to fetch, and what [FontLoader] registers it under.
  final String family;
  final String label;

  /// In the APK. Everything else is fetched on first pick.
  final bool bundled;
}

/// The UI font, and the small store behind it.
///
/// Only the default is in the APK — a default has to paint on the first frame
/// with no network. The rest are fetched on first pick by
/// [SubtitleFontService], which registers them through [FontLoader]; that is
/// app-wide, not subtitle-only, so a downloaded family works for the UI.
class AppFontPrefs {
  const AppFontPrefs._();

  static const String boxName = 'app_font_prefs';
  static const String _key = 'family';

  /// Bumped on change so the app can rebuild — main.dart listens, exactly as
  /// it does for [ThemeController.revision].
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Offered in the picker, in the order shown. Nunito first: it is the
  /// default and the one the app is designed around.
  static const List<AppFont> fonts = [
    AppFont('Nunito', 'Nunito', bundled: true),
    AppFont('Inter', 'Inter', bundled: true),
    AppFont('Noto Sans', 'Noto Sans', bundled: true),
    AppFont('Rubik', 'Rubik'),
    AppFont('Open Sans', 'Open Sans'),
    AppFont('Source Sans 3', 'Source Sans 3'),
    AppFont('Montserrat', 'Montserrat'),
    AppFont('Roboto', 'Roboto'),
  ];

  static bool isBundled(String family) =>
      fonts.any((f) => f.family == family && f.bundled);

  /// Fetch + register [family] if it isn't already usable. False means the
  /// download failed — the caller must NOT save it, or the app restarts into a
  /// family Flutter has never heard of and silently draws the platform default.
  static Future<bool> ensure(String family) async {
    if (isBundled(family)) return true;
    return SubtitleFontService.instance.ensure(family);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Opens the box and applies the saved font BEFORE the first frame, so the
  /// app never paints one font and then swaps.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
    final saved = family;
    // FontLoader registrations do not survive a restart, so a downloaded
    // family has to be registered again before it is applied — otherwise the
    // app boots into a font Flutter doesn't know and quietly draws the
    // platform default, which reads as the setting having been forgotten.
    if (!isBundled(saved)) {
      final ok = await SubtitleFontService.instance.ensure(saved);
      if (!ok) {
        AppText.fontFamily = AppText.defaultFontFamily;
        return;
      }
    }
    AppText.fontFamily = saved;
  }

  /// The saved family, or the default when unset — or when what was saved is
  /// no longer offered (a font dropped from the list shouldn't leave the app
  /// asking for a family that isn't declared, which renders as the platform
  /// default and looks like a bug).
  static String get family {
    final saved = _boxOrNull?.get(_key) as String?;
    if (saved == null) return AppText.defaultFontFamily;
    final known = fonts.any((f) => f.family == saved);
    return known ? saved : AppText.defaultFontFamily;
  }

  static Future<void> setFamily(String family) async {
    final box = _boxOrNull;
    if (box == null) return;
    await box.put(_key, family);
    AppText.fontFamily = AppFontPrefs.family;
    revision.value++;
  }

  /// The label for what is set, for the settings row's trailing value.
  static String get label =>
      fonts.firstWhere(
        (f) => f.family == family,
        orElse: () => fonts.first,
      ).label;
}
