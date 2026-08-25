import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

import 'app_colors.dart';

/// Owns the user's accent-colour choice. Persists it in Hive, applies it to
/// [AppColors.accent] at startup, and bumps [revision] on change so the app can
/// rebuild. Accent only — the dark base theme is unchanged. Default is the
/// original coral, so an untouched install looks identical to before.
class ThemeController {
  const ThemeController._();

  static const String boxName = 'theme_prefs';
  static const String _key = 'accent';
  static const String _amoledKey = 'amoled';
  static const String _materialYouKey = 'materialYou';

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
      _box.get(_materialYouKey, defaultValue: false) as bool;

  /// Persist + apply the Material You toggle and notify listeners to rebuild.
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

    AppColors.accent = d?.accent ?? accent;

    if (amoled) {
      AppColors.bg = amoledBg;
      AppColors.surface = amoledSurface;
      AppColors.surface2 = amoledSurface2;
    } else if (d != null) {
      AppColors.bg = d.bg;
      AppColors.surface = d.surface;
      AppColors.surface2 = d.surface2;
    } else {
      AppColors.bg = AppColors.defaultBg;
      AppColors.surface = AppColors.defaultSurface;
      AppColors.surface2 = AppColors.defaultSurface2;
    }
  }

  /// Opens the box and applies the saved accent + AMOLED choice. Call once
  /// during bootstrap, BEFORE the first frame, so the first paint uses them.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
    await _loadPalette();
    _applyColors();
  }

  /// Whether the pure-black (AMOLED) background is on. Off by default.
  static bool get amoled => _box.get(_amoledKey, defaultValue: false) as bool;

  /// Persist + apply the AMOLED toggle and notify listeners to rebuild.
  static Future<void> setAmoled(bool on) async {
    await _box.put(_amoledKey, on);
    _applyColors();
    revision.value++;
  }

  /// The saved accent, or the default coral when unset.
  static Color get accent {
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

  /// Persist + apply a new accent and notify listeners to rebuild.
  static Future<void> setAccent(Color color) async {
    await _box.put(_key, color.toARGB32());
    _applyColors();
    revision.value++;
  }
}
