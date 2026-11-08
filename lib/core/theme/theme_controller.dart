import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

import 'app_colors.dart';

/// Applies device appearance defaults and the active profile's optional
/// overrides, then bumps [revision] so the app rebuilds. Untouched profiles
/// inherit the existing device settings.
class ThemeController {
  const ThemeController._();

  static const String boxName = 'theme_prefs';
  static const String _key = 'accent';
  static const String _amoledKey = 'amoled';
  static const String _materialYouKey = 'materialYou';
  static const String _adaptiveKey = 'adaptiveColour';
  static const String _titleLogoKey = 'titleLogo';
  static const String _bgKey = 'backgroundColour';

  /// Near-black palette used when AMOLED is on (bg + card surfaces).
  static const Color amoledBg = Color(0xFF000000);
  static const Color amoledSurface = Color(0xFF0D0D11);
  static const Color amoledSurface2 = Color(0xFF17171C);

  /// Bumped whenever the accent changes, so listeners (root app, shell) rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Selectable accents. First entry is the default coral.
  static const List<(String, Color)> accentPresets = [
    ('Coral', AppColors.defaultAccent),
    ('Blue', Color(0xFF4D8DFF)),
    ('Violet', Color(0xFF9B6DFF)),
    ('Emerald', Color(0xFF32D583)),
    ('Amber', Color(0xFFFFB020)),
    ('Rose', Color(0xFFFF5FA2)),
    ('Cyan', Color(0xFF3DD6D0)),
    ('Crimson', Color(0xFFF04438)),
  ];

  static Box get _box => Hive.box(boxName);

  // ── Material You ──────────────────────────────────────────────────────────
  // Android 12+ exposes a palette generated from the user's wallpaper. We take
  // four values out of it — the same four the accent picker and AMOLED toggle
  // already write — so the rest of the app is untouched. Text stays white and
  // artwork is never tinted; only the app's own chrome follows the wallpaper.

  /// The four colours pulled out of the wallpaper palette, or null when
  /// unread / unsupported / the toggle is off. Kept as plain [Color]s rather
  /// than the palette object so nothing else has to know about the tonal API.
  static ({Color accent, Color bg, Color surface, Color surface2})? _dynamic;
  static Color? _profileAccent;
  static bool? _profileMaterialYou;
  static bool? _profileAmoled;

  /// Null until probed. False on iOS, Android < 12, or if the read fails —
  /// used to hide the setting rather than show a switch that does nothing.
  static bool? _supported;

  /// Whether this device can theme from the wallpaper. Safe to call anywhere;
  /// the first call probes, later ones are free.
  static Future<bool> supported() async {
    final cached = _supported;
    if (cached != null) return cached;
    if (!Platform.isAndroid) return _supported = false;
    try {
      return _supported = await DynamicColorPlugin.getCorePalette() != null;
    } catch (_) {
      return _supported = false;
    }
  }

  /// Whether the user asked for wallpaper colours. Off by default, so an
  /// untouched install looks exactly as it does today.
  static bool get materialYou =>
      Platform.isAndroid &&
      _supported != false &&
      (_profileMaterialYou ??
          _box.get(_materialYouKey, defaultValue: false) as bool);

  /// Persist + apply the device-wide Material You fallback.
  static Future<void> setMaterialYou(bool on) async {
    await _box.put(_materialYouKey, on);
    await _loadPalette();
    _applyColors();
    revision.value++;
  }

  /// Re-read the wallpaper palette. Called at startup and whenever the app
  /// comes back to the foreground, so changing wallpaper is picked up.
  static Future<void> refresh() async {
    if (!materialYou) return;
    final before = _dynamic?.accent;
    await _loadPalette();
    if (_dynamic?.accent == before) return; // wallpaper hasn't moved
    _applyColors();
    revision.value++;
  }

  static Future<void> _loadPalette() async {
    if (!materialYou || !Platform.isAndroid) {
      _dynamic = null;
      return;
    }
    try {
      final p = await DynamicColorPlugin.getCorePalette();
      if (p == null) {
        _dynamic = null;
        return;
      }
      // Material 3 dark scheme, by the book — no tuning. CorePalette already
      // applies the spec's chroma (primary = max(48, seed), neutral = 4), so
      // these are just the documented role tones:
      //   surface 6 · surfaceContainerLow 10 · surfaceContainerHigh 17
      //   primary 80
      // Deliberately lighter and less saturated than the app's own palette —
      // that IS what Material 3 looks like.
      _dynamic = (
        accent: Color(p.primary.get(80)),
        bg: Color(p.neutral.get(6)),
        surface: Color(p.neutral.get(10)),
        surface2: Color(p.neutral.get(17)),
      );
    } catch (_) {
      _dynamic = null; // fall back to the saved accent + default surfaces
    }
  }

  /// Single place that decides the four mutable colours, so the accent picker,
  /// AMOLED and Material You can't fight each other.
  ///
  /// Precedence for the surfaces is AMOLED → Material You → default: someone
  /// who asked for pure black wants pure black, but they still get the
  /// wallpaper's accent.
  static void _applyColors() {
    final d = materialYou ? _dynamic : null;

    AppColors.accent = d?.accent ?? _profileAccent ?? accent;

    if (amoled) {
      AppColors.bg = amoledBg;
      AppColors.surface = amoledSurface;
      AppColors.surface2 = amoledSurface2;
    } else if (d != null) {
      AppColors.bg = d.bg;
      AppColors.surface = d.surface;
      AppColors.surface2 = d.surface2;
    } else {
      final custom = backgroundColour;
      AppColors.bg = custom == null ? AppColors.defaultBg : darkened(custom);
      AppColors.surface = AppColors.defaultSurface;
      AppColors.surface2 = AppColors.defaultSurface2;
    }
  }

  /// Ceiling for a custom background's HSV value (#6B). The app draws white
  /// text on it, so anything lighter would drop body text below 4.5:1. The
  /// background picker caps its brightness slider here too, so the wheel never
  /// offers shades that would be silently darkened.
  static const double maxBackgroundValue = 0.42;

  /// The picked app background, or null while the stock background is in use.
  /// Device-wide, like [adaptiveColour].
  static Color? get backgroundColour {
    if (!Hive.isBoxOpen(boxName)) return null;
    final v = _box.get(_bgKey) as int?;
    return v == null ? null : Color(v);
  }

  /// Persist a custom app background and rebuild listeners. Home and Detail
  /// keep the adaptive poster tint when that is on; every other screen uses
  /// this colour.
  static Future<void> setBackgroundColour(Color? colour) async {
    if (colour == null) {
      await _box.delete(_bgKey);
    } else {
      await _box.put(_bgKey, colour.toARGB32());
    }
    _applyColors();
    revision.value++;
  }

  /// Clamps a pick to a dark tone, keeping its hue and saturation. Only the
  /// value changes, so a vivid red still reads as red — just a background red.
  static Color darkened(Color colour) {
    final hsv = HSVColor.fromColor(colour);
    return hsv.value <= maxBackgroundValue
        ? colour
        : hsv.withValue(maxBackgroundValue).toColor();
  }

  /// Opens the box and applies the saved accent + AMOLED choice. Call once
  /// during bootstrap, BEFORE the first frame, so the first paint uses them.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
    await _loadPalette();
    _applyColors();
  }

  /// Whether the pure-black (AMOLED) background is on. Off by default.
  static bool get amoled =>
      _profileAmoled ?? _box.get(_amoledKey, defaultValue: false) as bool;

  /// Persist + apply the device-wide AMOLED fallback.
  static Future<void> setAmoled(bool on) async {
    await _box.put(_amoledKey, on);
    _applyColors();
    revision.value++;
  }

  /// Whether the poster-tinted background (Home + Detail) is on. Off by
  /// default. Device-wide, not per-profile — see the appearance screen.
  static bool get adaptiveColour {
    // Screens are pumped in tests without opening the theme box — treat that
    // as off rather than throwing during build.
    if (!Hive.isBoxOpen(boxName)) return false;
    return _box.get(_adaptiveKey, defaultValue: false) as bool;
  }

  /// Persist the poster-tint toggle and rebuild listeners.
  static Future<void> setAdaptiveColour(bool on) async {
    await _box.put(_adaptiveKey, on);
    revision.value++;
  }

  /// Whether the Detail screen shows the official TMDB title logo instead of
  /// plain text. On by default. Device-wide, like [adaptiveColour]. A title
  /// with no logo still shows text — the toggle only unlocks the logo look.
  static bool get titleLogo {
    if (!Hive.isBoxOpen(boxName)) return true;
    return _box.get(_titleLogoKey, defaultValue: true) as bool;
  }

  /// Persist the title-logo toggle and rebuild listeners.
  static Future<void> setTitleLogo(bool on) async {
    await _box.put(_titleLogoKey, on);
    revision.value++;
  }

  /// The active profile's accent, or the saved device fallback.
  static Color get accent {
    if (_profileAccent != null) return _profileAccent!;
    final v = _box.get(_key) as int?;
    return v == null ? AppColors.defaultAccent : Color(v);
  }

  /// Human label for the current accent, e.g. "Default" (coral) or "Blue".
  ///
  /// Reports the EFFECTIVE source, not the stored one: with Material You on
  /// the saved accent is still coral, and showing "Default" next to a blue dot
  /// read as a bug.
  static String get accentLabel {
    if (materialYou && _dynamic != null) return 'Wallpaper';
    final cur = accent.toARGB32();
    if (cur == AppColors.defaultAccent.toARGB32()) return 'Default';
    for (final (name, color) in accentPresets) {
      if (color.toARGB32() == cur) return name;
    }
    return 'Custom';
  }

  /// Whether [color] is the default coral.
  static bool isDefault(Color color) =>
      color.toARGB32() == AppColors.defaultAccent.toARGB32();

  /// Persist + apply a new device-wide accent fallback.
  static Future<void> setAccent(Color color) async {
    await _box.put(_key, color.toARGB32());
    _applyColors();
    revision.value++;
  }

  /// Applies the active profile's optional overrides over the existing app
  /// defaults. Null keeps the prior device-wide value for older profiles.
  static Future<void> applyProfileTheme({
    required int? accentColor,
    required bool? materialYou,
    required bool? amoled,
  }) async {
    if (!Hive.isBoxOpen(boxName)) await init();
    final wasMaterialYou = ThemeController.materialYou;
    _profileAccent =
        accentColor == null || accentColor < 0 || accentColor > 0xFFFFFFFF
        ? null
        : Color(accentColor);
    _profileMaterialYou = materialYou;
    _profileAmoled = amoled;
    final useMaterialYou = ThemeController.materialYou;
    if (useMaterialYou && (!wasMaterialYou || _dynamic == null)) {
      await _loadPalette();
    } else if (!useMaterialYou) {
      _dynamic = null;
    }
    _applyColors();
    revision.value++;
  }
}
