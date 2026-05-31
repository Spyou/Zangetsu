import 'package:flutter/material.dart';

abstract class AppColors {
  static const bg = Color(0xFF0B0B0F);
  static const surface = Color(0xFF16161C);
  static const surface2 = Color(0xFF20212A);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA7A7B2);
  static const textTertiary = Color(0xFF6E6E78);
  static const hairline = Color(0x14FFFFFF);
  static const accent = Color(0xFFFF4D57);          // coral-red signature
  static const accentSoft = Color(0x26FF4D57);       // accent @ ~15% for tints/chips

  /// Bottom-up scrim for art overlays (near-black -> transparent).
  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter, end: Alignment.topCenter,
    colors: [Color(0xF20B0B0F), Color(0x000B0B0F)], stops: [0.0, 0.65],
  );
  /// Top-down scrim for hero readability under the status bar.
  static const topScrim = LinearGradient(
    begin: Alignment.topCenter, end: Alignment.bottomCenter,
    colors: [Color(0x990B0B0F), Color(0x000B0B0F)], stops: [0.0, 0.5],
  );
}
