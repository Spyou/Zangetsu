import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Apple-like type scale on bundled Inter, with platform CJK fallbacks so
/// Japanese/Chinese copy isn't tofu when the UI language isn't Latin.
abstract class AppText {
  static const fontFamily = 'Inter';

  /// Platform CJK fonts. Inter has no CJK glyphs; missing characters fall
  /// through to these (iOS Hiragino/PingFang, Android Noto / sans-serif).
  static const fontFamilyFallback = <String>[
    'Hiragino Sans',
    'Hiragino Kaku Gothic ProN',
    'PingFang SC',
    'PingFang TC',
    'Noto Sans CJK JP',
    'Noto Sans CJK SC',
    'Noto Sans CJK TC',
    'sans-serif',
  ];

  static const _f = fontFamily;
  static const _fb = fontFamilyFallback;

  static const largeTitle = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 32,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: AppColors.textPrimary,
  );
  static const title = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 22,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );
  static const headline = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 17,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  /// Compact app-bar title for settings-family screens — matches the settings
  /// section header so drilling deeper keeps one header size.
  static final barTitle =
      headline.copyWith(fontSize: 18, fontWeight: FontWeight.w700);
  static const body = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static const caption = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );
  static const button = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const overline = TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: AppColors.textSecondary,
  );
}
