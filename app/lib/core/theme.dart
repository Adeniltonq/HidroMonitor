import 'package:flutter/material.dart';

/// Paleta HidroMonitor: azul-água, branco, preto e verde vivos.
class AppColors {
  AppColors._();

  static const Color waterBlue = Color(0xFF0077C8);
  static const Color deepBlue = Color(0xFF003B5C);
  static const Color aqua = Color(0xFF00BCD4);
  static const Color vividGreen = Color(0xFF00B85C);
  static const Color ink = Color(0xFF071A26);
  static const Color night = Color(0xFF000000);
}

/// Tema Material 3 com dois modos explícitos: Branco (claro) e Preto (escuro).
class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(_lightScheme());

  static ThemeData dark() => _build(_darkScheme());

  static ColorScheme _lightScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.waterBlue,
      brightness: Brightness.light,
    );
    return base.copyWith(
      primary: AppColors.waterBlue,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFD6EEFF),
      onPrimaryContainer: AppColors.deepBlue,
      secondary: AppColors.vividGreen,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFC9F7DD),
      onSecondaryContainer: const Color(0xFF00391B),
      tertiary: AppColors.aqua,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFC8F6FB),
      onTertiaryContainer: const Color(0xFF00363D),
      surface: Colors.white,
      onSurface: AppColors.ink,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF3FAFF),
      surfaceContainer: const Color(0xFFE9F5FD),
      surfaceContainerHigh: const Color(0xFFDFEFFA),
      surfaceContainerHighest: const Color(0xFFD4E8F6),
      outline: const Color(0xFF9FB6C6),
      outlineVariant: const Color(0xFFD3E2EE),
      error: const Color(0xFFD32F2F),
      onError: Colors.white,
    );
  }

  static ColorScheme _darkScheme() {
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.waterBlue,
      brightness: Brightness.dark,
    );
    return base.copyWith(
      primary: const Color(0xFF4FC3F7),
      onPrimary: const Color(0xFF00263A),
      primaryContainer: const Color(0xFF004E73),
      onPrimaryContainer: const Color(0xFFCDEBFF),
      secondary: const Color(0xFF00E676),
      onSecondary: const Color(0xFF00391B),
      secondaryContainer: const Color(0xFF00522A),
      onSecondaryContainer: const Color(0xFFC9F7DD),
      tertiary: const Color(0xFF26E0F0),
      onTertiary: const Color(0xFF00363D),
      tertiaryContainer: const Color(0xFF00505A),
      onTertiaryContainer: const Color(0xFFC8F6FB),
      surface: AppColors.night,
      onSurface: const Color(0xFFE8F6FF),
      surfaceContainerLowest: AppColors.night,
      surfaceContainerLow: const Color(0xFF0B141A),
      surfaceContainer: const Color(0xFF101D25),
      surfaceContainerHigh: const Color(0xFF16262F),
      surfaceContainerHighest: const Color(0xFF1D3039),
      outline: const Color(0xFF4A6572),
      outlineVariant: const Color(0xFF24343D),
      error: const Color(0xFFFF6B6B),
      onError: const Color(0xFF3B0000),
    );
  }

  static ThemeData _build(ColorScheme scheme) {
    final radius = BorderRadius.circular(16);
    final isDark = scheme.brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: radius),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.55)),
          foregroundColor: scheme.primary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? scheme.surfaceContainerHigh : scheme.deepNight,
        contentTextStyle: TextStyle(
          color: isDark ? scheme.onSurface : Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: isDark ? const Color(0xFF081218) : Colors.white,
        indicatorColor: isDark
            ? const Color(0xFF004E73)
            : const Color(0xFFD6EEFF),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? (isDark ? const Color(0xFF7FD4FF) : AppColors.waterBlue)
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: isDark ? const Color(0xFF000000) : Colors.white,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: isDark
            ? const Color(0xFF004E73)
            : const Color(0xFFD6EEFF),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(100),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 24),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}

extension on ColorScheme {
  /// Preto quase puro usado no snackbar do tema claro.
  Color get deepNight => const Color(0xFF0A1A24);
}
