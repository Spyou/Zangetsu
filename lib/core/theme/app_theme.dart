import 'package:flutter/material.dart';
import 'app_colors.dart';

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    surface: AppColors.bg,
    primary: AppColors.textPrimary, // white primary actions
    secondary: AppColors.accent,
    onPrimary: Colors.black,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      thickness: 0.5,
      space: 0.5,
    ),
  );
}
