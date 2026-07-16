import 'package:flutter/material.dart';
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

  /// Opens the box and applies the saved accent + AMOLED choice. Call once
  /// during bootstrap, BEFORE the first frame, so the first paint uses them.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
    AppColors.accent = accent;
    _applyAmoled(amoled);
  }

  /// Whether the pure-black (AMOLED) background is on. Off by default.
  static bool get amoled => _box.get(_amoledKey, defaultValue: false) as bool;

  /// Persist + apply the AMOLED toggle and notify listeners to rebuild.
  static Future<void> setAmoled(bool on) async {
    await _box.put(_amoledKey, on);
    _applyAmoled(on);
    revision.value++;
  }

  static void _applyAmoled(bool on) {
    AppColors.bg = on ? amoledBg : AppColors.defaultBg;
    AppColors.surface = on ? amoledSurface : AppColors.defaultSurface;
    AppColors.surface2 = on ? amoledSurface2 : AppColors.defaultSurface2;
  }

  /// The saved accent, or the default coral when unset.
  static Color get accent {
    final v = _box.get(_key) as int?;
    return v == null ? AppColors.defaultAccent : Color(v);
  }

  /// Human label for the current accent, e.g. "Default" (coral) or "Blue".
  static String get accentLabel {
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
    AppColors.accent = color;
    revision.value++;
  }
}
