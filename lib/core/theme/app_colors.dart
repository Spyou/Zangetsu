import 'package:flutter/material.dart';

/// Apple-TV-style dark palette. Near-monochrome; art carries the color.
abstract class AppColors {
  static const bg = Color(0xFF0A0A0C);
  static const surface = Color(0xFF141417);
  static const surface2 = Color(0xFF1E1E22);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB9B9C0);
  static const textTertiary = Color(0xFF7C7C85);
  static const hairline = Color(0x14FFFFFF); // white @ 8%
  static const accent = Color(0xFF0A84FF); // Apple dark system blue (selection/active)

  /// Bottom-up scrim for art overlays (transparent → near-black).
  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xE6000000), Color(0x00000000)],
    stops: [0.0, 0.6],
  );
}
