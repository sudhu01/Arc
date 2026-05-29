import 'package:flutter/material.dart';

/// Surge — "Bold athletic · volt" palette.
/// Ported from the design's OKLCH custom properties to sRGB.
class AppColors {
  AppColors._();

  static const bg = Color(0xFFF4F5F7);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEEF0F3);

  static const ink = Color(0xFF0E1217);
  static const muted = Color(0xFF53595F);
  static const faint = Color(0xFF82878C);

  static const line = Color(0xFFDBDEE1);
  static const cardLine = Color(0xFFE0E3E6);

  // The volt accent.
  static const accent = Color(0xFFA4E238);
  static const accentInk = Color(0xFF092104);
  static const accentStrong = Color(0xFF357426);
  static const accentSoft = Color(0xFFDCF6BD);

  static const up = Color(0xFF267D30);
  static const danger = Color(0xFFC53637);
  static const dangerSoft = Color(0xFFFFDFDA);

  static const bar = Color(0xFFD7DBE0);
  static const toastBg = Color(0xFF0E1217);
  static const toastInk = Color(0xFFFFFFFF);

  static const navMuted = Color(0xFF6F757B);

  // Muscle-group dots — oklch(0.68 0.15 H).
  static const groupPush = Color(0xFFE66F62);
  static const groupPull = Color(0xFF539AF2);
  static const groupLegs = Color(0xFF45B164);
  static const groupCore = Color(0xFFC077D1);

  static Color group(String g) {
    switch (g) {
      case 'Push':
        return groupPush;
      case 'Pull':
        return groupPull;
      case 'Legs':
        return groupLegs;
      case 'Core':
        return groupCore;
      default:
        return groupPush;
    }
  }
}

/// Corner radii — Surge uses tight, athletic corners.
class AppRadii {
  AppRadii._();
  static const double sm = 9;
  static const double md = 13;
  static const double lg = 20;

  static const rSm = BorderRadius.all(Radius.circular(sm));
  static const rMd = BorderRadius.all(Radius.circular(md));
  static const rLg = BorderRadius.all(Radius.circular(lg));
}

class AppShadows {
  AppShadows._();

  /// Soft card lift — `0 3px 18px oklch(0.3 0.03 250 / .07)`.
  static const card = [
    BoxShadow(color: Color(0x121A2230), blurRadius: 18, offset: Offset(0, 3)),
  ];

  /// Subtle inner-control shadow — `0 1px 3px rgba(0,0,0,.07)`.
  static const sm = [
    BoxShadow(color: Color(0x12000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// The volt FAB glow — `0 6px 20px oklch(0.84 0.2 128 / .5)`.
  static List<BoxShadow> accent = [
    BoxShadow(
      color: AppColors.accent.withValues(alpha: 0.5),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
  ];
}

/// Typography — Surge sets display, body, and numerals all in Sora (bundled
/// as a variable font; we drive the `wght` axis directly for crisp weights).
class AppText {
  AppText._();

  static const String family = 'Sora';
  static const _tabular = [FontFeature.tabularFigures()];

  static TextStyle sora({
    required double size,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.ink,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Numerals slot — Sora with tabular figures (Surge relies on tabular
  /// numbers for alignment rather than a separate mono face).
  static TextStyle mono({
    required double size,
    FontWeight weight = FontWeight.w600,
    Color color = AppColors.ink,
    double? height,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      color: color,
      height: height,
      fontFeatures: _tabular,
    );
  }
}

ThemeData buildArcTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: AppText.family,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.light,
      primary: AppColors.accent,
      onPrimary: AppColors.accentInk,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
      fontFamily: AppText.family,
    ),
  );
}
