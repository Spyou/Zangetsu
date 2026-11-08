import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';

void main() {
  test('light picks are clamped dark but keep their hue', () {
    final bg = ThemeController.darkened(const Color(0xFFFF0000));
    final hsv = HSVColor.fromColor(bg);
    expect(hsv.value, lessThan(0.43));
    expect(hsv.hue, closeTo(0, 0.5));
  });

  test('already-dark picks pass through untouched', () {
    const dark = Color(0xFF101018);
    expect(ThemeController.darkened(dark), dark);
  });

  test('the stock background is already safe', () {
    expect(ThemeController.darkened(AppColors.defaultBg), AppColors.defaultBg);
  });
}
