import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Apple-like type scale, with platform CJK fallbacks so Japanese/Chinese
/// copy isn't tofu when the UI language isn't Latin.
///
/// The styles are GETTERS, not constants: [fontFamily] is chosen by the user
/// (Settings → Interface → Appearance → Font) and changes while the app runs,
/// so a style baked at compile time would keep whatever font it was built
/// with. Nothing in the app const-constructs these, so this costs nothing.
abstract class AppText {
  /// The family every style below is drawn in. Set from [AppFontPrefs] at
  /// boot and on every change — same shape as [AppColors.accent].
  static String fontFamily = defaultFontFamily;

  /// What a fresh install uses.
  static const String defaultFontFamily = 'Nunito';

  /// Platform CJK fonts. None of the UI families carry CJK glyphs; missing
  /// characters fall through to these (iOS Hiragino/PingFang, Android Noto).
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

  static String get _f => fontFamily;
  static const _fb = fontFamilyFallback;

  static TextStyle get largeTitle => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 32,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: AppColors.textPrimary,
  );
  static TextStyle get title => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 22,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );
  static TextStyle get headline => TextStyle(
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
  static TextStyle get body => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static TextStyle get caption => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );
  static TextStyle get button => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static TextStyle get overline => TextStyle(
    fontFamily: _f,
    fontFamilyFallback: _fb,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: AppColors.textSecondary,
  );
}
