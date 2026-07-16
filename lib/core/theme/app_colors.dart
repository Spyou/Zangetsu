import 'package:flutter/material.dart';

abstract class AppColors {
  /// The default near-black background.
  static const Color defaultBg = Color(0xFF0B0B0F);

  static const Color defaultSurface = Color(0xFF16161C);
  static const Color defaultSurface2 = Color(0xFF20212A);

  /// Background + card surfaces. Runtime-mutable for the AMOLED (pure-black)
  /// toggle: set by [ThemeController] at startup. Default to the original
  /// values, so an untouched install looks exactly as before. AMOLED darkens
  /// all three so the whole app reads near-black on OLED.
  static Color bg = defaultBg;
  static Color surface = defaultSurface;
  static Color surface2 = defaultSurface2;
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA7A7B2);
  static const textTertiary = Color(0xFF6E6E78);
  static const hairline = Color(0x14FFFFFF);

  /// The original coral-red signature — the default accent.
  static const Color defaultAccent = Color(0xFFFF4D57);

  /// The app-wide accent. Runtime-mutable so it can be themed: set once at
  /// startup by [ThemeController] and updated when the user picks a new colour.
  /// Defaults to [defaultAccent], so an untouched install looks exactly as
  /// before. NOT `const` — the 24 former const call-sites were de-const'd.
  static Color accent = defaultAccent;

  /// A ~15% tint of [accent] for chips/highlights. Derived so it always tracks
  /// the chosen accent (was the const `0x26FF4D57`).
  static Color get accentSoft => accent.withValues(alpha: 0.15);

  /// Bottom-up scrim for art overlays (near-black -> transparent).
  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF20B0B0F), Color(0x000B0B0F)],
    stops: [0.0, 0.65],
  );

  /// Top-down scrim for hero readability under the status bar.
  static const topScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x990B0B0F), Color(0x000B0B0F)],
    stops: [0.0, 0.5],
  );
}
