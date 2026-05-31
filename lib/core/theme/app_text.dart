import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Apple-like type scale on bundled Inter.
abstract class AppText {
  static const _f = 'Inter';
  static const largeTitle = TextStyle(fontFamily: _f, fontSize: 32, height: 1.1, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: AppColors.textPrimary);
  static const title = TextStyle(fontFamily: _f, fontSize: 22, height: 1.15, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppColors.textPrimary);
  static const headline = TextStyle(fontFamily: _f, fontSize: 17, height: 1.2, fontWeight: FontWeight.w600, color: AppColors.textPrimary);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.textSecondary);
  static const caption = TextStyle(fontFamily: _f, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500, color: AppColors.textTertiary);
  static const button = TextStyle(fontFamily: _f, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2);
  static const overline = TextStyle(fontFamily: _f, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: AppColors.textSecondary);
}
