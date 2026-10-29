import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/liquid_nav_glass.dart';

void main() {
  test('zero shading preserves the current glass settings', () {
    final original = liquidNavGlassSettings(0.82);
    final off = liquidNavGlassSettings(0.82, glassVisibility: 0);
    expect(off, original);
    expect(off.edgeAbsorption, 0);
    expect(off.bodyShade, 0.12);
    expect(off.blur, 3);
    expect(off.thickness, 26);
    expect(off.rimShade, 0.45);
  });

  test('visibility darkens the whole glass without changing other effects', () {
    final original = liquidNavGlassSettings(0.4, extraBlur: false);
    final shaded = liquidNavGlassSettings(
      0.4,
      extraBlur: false,
      glassVisibility: 0.7,
    );
    expect(shaded.glassColor.a, greaterThan(original.glassColor.a));
    expect(
      shaded.glassColor.computeLuminance(),
      lessThan(original.glassColor.computeLuminance()),
    );
    expect(shaded.copyWith(glassColor: original.glassColor), original);
  });

  test('invalid shading is bounded', () {
    expect(
      liquidNavGlassSettings(0.82, glassVisibility: -1),
      liquidNavGlassSettings(0.82),
    );
    expect(
      liquidNavGlassSettings(0.82, glassVisibility: double.nan),
      liquidNavGlassSettings(0.82),
    );
    expect(
      liquidNavGlassSettings(0.82, glassVisibility: 2),
      liquidNavGlassSettings(0.82, glassVisibility: 1),
    );
  });
}
