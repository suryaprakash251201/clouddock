// CloudDock design system: modern dark-first theme + glassmorphism kit.
// Light mode is supported; glass adapts its tint per brightness.

import 'package:flutter/material.dart';

class AppColors {
  static const teal = Color(0xFF2DD4BF);
  static const cyan = Color(0xFF22D3EE);
  static const violet = Color(0xFF8B5CF6);
  static const indigo = Color(0xFF6366F1);
  static const darkBg = Color(0xFF090E1C);
  static const darkBg2 = Color(0xFF0E1630);
  static const lightBg = Color(0xFFF2F5F9);

  static const aws = Color(0xFFFF9900);
  static const r2 = Color(0xFFF6821F);
  static const minio = Color(0xFFF43F5E);
  static const wasabi = Color(0xFF00B199);
  static const b2 = Color(0xFFEE2E24);
  static const custom = Color(0xFF64748B);
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.teal,
    brightness: Brightness.light,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.lightBg,
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.7),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.teal,
    brightness: Brightness.dark,
  ).copyWith(primary: AppColors.teal, secondary: AppColors.violet);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.darkBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerColor: Colors.white.withValues(alpha: 0.08),
  );
}
