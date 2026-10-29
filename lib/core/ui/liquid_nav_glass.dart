import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

LiquidGlassSettings liquidNavGlassSettings(
  double tint, {
  bool extraBlur = true,
  double glassVisibility = 0,
}) {
  final shade = glassVisibility.isFinite
      ? glassVisibility.clamp(0.0, 1.0)
      : 0.0;
  return LiquidGlassSettings(
    glassColor: Color.lerp(
      Color.lerp(Colors.white, Colors.black, tint)!.withValues(alpha: 0.12),
      Colors.black.withValues(alpha: 0.72),
      shade,
    )!,
    bodyMode: GlassBodyMode.clear,
    blur: extraBlur ? 3 : 0.6,
    thickness: 26,
    chromaticAberration: 0,
    lightIntensity: 0.16,
    refractiveIndex: 1.24,
    saturation: 1.15,
    ambientStrength: 0.06,
    fresnelStrength: 0.55,
    glowIntensity: 0.12,
    rimShade: 0.45,
    rimShadeEnds: 0.1,
    rimLight: 0.12,
    bodyShade: 0.12,
  );
}
