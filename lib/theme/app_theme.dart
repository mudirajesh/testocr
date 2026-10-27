import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          tertiary: AppColors.tertiary,
          error: AppColors.danger,
          surface: AppColors.background,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      textTheme: GoogleFonts.interTextTheme(),
    );
  }
}
