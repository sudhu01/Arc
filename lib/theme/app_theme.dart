import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accent.dart';
import 'muscle_palette.dart';

/// A complete set of design tokens for one Arc theme.
///
/// The two instances below are ports of the design canvas's themes:
/// `B · Surge` (bold athletic · volt) for light, and `C · Midnight`
/// (dark mode · electric) for dark. Colors, radii and shadows come from that
/// theme's OKLCH custom properties, converted to sRGB.
///
/// Type is the one deliberate departure: the design gives each theme its own
/// pairing, but Arc keeps a single one — Sora primary, Space Grotesk for
/// numerals — across both.
@immutable
class ArcPalette {
  const ArcPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.cardLine,
    required this.accent,
    required this.accentInk,
    required this.accentStrong,
    required this.accentSoft,
    required this.accentLine,
    required this.accentGlowOpacity,
    required this.accentGlowBlur,
    required this.up,
    required this.danger,
    required this.dangerSoft,
    required this.bar,
    required this.toastBg,
    required this.toastInk,
    required this.navBg,
    required this.navLine,
    required this.navMuted,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.cardShadow,
    required this.smallShadow,
    required this.fontFamily,
    required this.monoFamily,
  });

  final Brightness brightness;

  final Color bg;
  final Color surface;
  final Color surface2;

  final Color ink;
  final Color muted;
  final Color faint;

  final Color line;
  final Color cardLine;

  final Color accent;
  final Color accentInk;
  final Color accentStrong;
  final Color accentSoft;

  /// Accent for chart geometry — plot lines, dots, the highlighted bar. Kept
  /// separate from [accent] because a 2.5px stroke has none of a filled
  /// button's mass: Surge's volt lime sits at ~1.35:1 against the white card
  /// and all but vanishes as a line. This is the accent pitched dark enough to
  /// hold an edge (it matches [accentStrong], which the chart cards already use
  /// for their header icons); Midnight's teal reads fine as-is.
  final Color accentLine;

  /// The `--accent-shadow` glow: alpha + blur of the accent-colored drop.
  final double accentGlowOpacity;
  final double accentGlowBlur;

  final Color up;
  final Color danger;
  final Color dangerSoft;

  final Color bar;
  final Color toastBg;
  final Color toastInk;

  /// Translucent bottom-nav fill, drawn over a backdrop blur.
  final Color navBg;
  final Color navLine;
  final Color navMuted;

  final double radiusSm;
  final double radiusMd;
  final double radiusLg;

  final List<BoxShadow> cardShadow;
  final List<BoxShadow> smallShadow;

  /// Primary (display + body) face, and the secondary face used for numerals.
  /// Both themes share the same pairing — Sora over Space Grotesk.
  final String fontFamily;
  final String monoFamily;

  bool get isDark => brightness == Brightness.dark;

  /// Ink for surfaces that stay light in both themes (the pairing QR code,
  /// which needs scanner-grade contrast against its fixed white card).
  static const qrInk = Color(0xFF0E1217);

  /// This palette with its accent family re-derived from [hue].
  ///
  /// Returns `this` untouched at the theme's default hue. The constants below
  /// are hand-tuned and the derivation lands a hair off them (`#A4E238` vs
  /// `#A8E92F`) — imperceptible, but not identical, and the shipped look is the
  /// one that was designed. Every other hue is computed; see [AccentRamp].
  ArcPalette withAccentHue(int hue) {
    if (hue % 360 == AccentRamp.defaultHue(dark: isDark)) return this;
    final a = AccentRamp.derive(hue, dark: isDark);
    return ArcPalette(
      brightness: brightness,
      bg: bg,
      surface: surface,
      surface2: surface2,
      ink: ink,
      muted: muted,
      faint: faint,
      line: line,
      cardLine: cardLine,
      accent: a.accent,
      accentInk: a.accentInk,
      accentStrong: a.accentStrong,
      accentSoft: a.accentSoft,
      accentLine: a.accentLine,
      accentGlowOpacity: accentGlowOpacity,
      accentGlowBlur: accentGlowBlur,
      up: up,
      danger: danger,
      dangerSoft: dangerSoft,
      bar: bar,
      toastBg: toastBg,
      toastInk: toastInk,
      navBg: navBg,
      navLine: navLine,
      navMuted: navMuted,
      radiusSm: radiusSm,
      radiusMd: radiusMd,
      radiusLg: radiusLg,
      cardShadow: cardShadow,
      smallShadow: smallShadow,
      fontFamily: fontFamily,
      monoFamily: monoFamily,
    );
  }

  /// `B · Surge` — bold athletic · volt.
  static const surge = ArcPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEEF0F3),
    ink: Color(0xFF0E1217),
    muted: Color(0xFF53595F),
    faint: Color(0xFF82878C),
    line: Color(0xFFDBDEE1),
    cardLine: Color(0xFFE0E3E6),
    accent: Color(0xFFA4E238),
    accentInk: Color(0xFF092104),
    accentStrong: Color(0xFF357426),
    accentSoft: Color(0xFFDCF6BD),
    accentLine: Color(0xFF357426),
    accentGlowOpacity: 0.5,
    accentGlowBlur: 20,
    up: Color(0xFF267D30),
    danger: Color(0xFFC53637),
    dangerSoft: Color(0xFFFFDFDA),
    bar: Color(0xFFD7DBE0),
    toastBg: Color(0xFF0E1217),
    toastInk: Color(0xFFFFFFFF),
    navBg: Color(0xD9FFFFFF), // white @ 85%
    navLine: Color(0xFFDBDEE1),
    navMuted: Color(0xFF6F757B),
    radiusSm: 9,
    radiusMd: 13,
    radiusLg: 20,
    // 0 3px 18px oklch(0.3 0.03 250 / .07)
    cardShadow: [
      BoxShadow(color: Color(0x121A2230), blurRadius: 18, offset: Offset(0, 3)),
    ],
    // 0 1px 3px rgba(0,0,0,.07)
    smallShadow: [
      BoxShadow(color: Color(0x12000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
    fontFamily: 'Sora',
    monoFamily: 'Space Grotesk',
  );

  /// `C · Midnight` — dark mode · electric.
  static const midnight = ArcPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0C0F17),
    surface: Color(0xFF151923),
    surface2: Color(0xFF202530),
    ink: Color(0xFFECEEF3),
    muted: Color(0xFF959BA9),
    faint: Color(0xFF686F7C),
    line: Color(0xFF2B303B),
    cardLine: Color(0xFF292E38),
    accent: Color(0xFF34EEC2),
    accentInk: Color(0xFF001B1D),
    accentStrong: Color(0xFF34EEC2),
    accentSoft: Color(0xFF003B3B),
    accentLine: Color(0xFF34EEC2),
    // The design calls for `0 6px 22px accent/.4`, but that teal at 40% over a
    // near-black background halos hard around every CTA. Softened to a hint of
    // lift instead.
    accentGlowOpacity: 0.16,
    accentGlowBlur: 16,
    up: Color(0xFF53E2A6),
    danger: Color(0xFFF2716A),
    dangerSoft: Color(0xFF512320),
    bar: Color(0xFF303541),
    toastBg: Color(0xFF262B36),
    toastInk: Color(0xFFF0F2F6),
    navBg: Color(0xD110141C), // oklch(0.19 0.018 265) @ 82%
    navLine: Color(0xFF292E38),
    navMuted: Color(0xFF7A808E),
    radiusSm: 12,
    radiusMd: 18,
    radiusLg: 26,
    // 0 4px 24px rgba(0,0,0,0.3)
    cardShadow: [
      BoxShadow(color: Color(0x4D000000), blurRadius: 24, offset: Offset(0, 4)),
    ],
    // 0 1px 4px rgba(0,0,0,0.3)
    smallShadow: [
      BoxShadow(color: Color(0x4D000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
    fontFamily: 'Sora',
    monoFamily: 'Space Grotesk',
  );
}

/// Holds the palette currently in force.
///
/// Tokens are read through plain statics (`AppColors.ink`, `AppRadii.rMd`, …)
/// rather than off a `BuildContext`, so switching themes swaps this holder and
/// then rebuilds the tree — see `ThemeController`, which drives both.
class ArcTheme {
  ArcTheme._();

  static ArcPalette _palette = ArcPalette.surge;

  static ArcPalette get palette => _palette;
  static bool get isDark => _palette.isDark;

  /// Each theme keeps its own accent hue, so editing in dark never disturbs
  /// light. Held here rather than passed on every call because [apply] runs
  /// from the mode toggle too, which knows nothing about accents.
  static int _lightHue = AccentRamp.defaultLightHue;
  static int _darkHue = AccentRamp.defaultDarkHue;

  static int hueFor({required bool dark}) => dark ? _darkHue : _lightHue;

  static void apply({required bool dark, int? lightHue, int? darkHue}) {
    if (lightHue != null) _lightHue = lightHue % 360;
    if (darkHue != null) _darkHue = darkHue % 360;
    final base = dark ? ArcPalette.midnight : ArcPalette.surge;
    _palette = base.withAccentHue(dark ? _darkHue : _lightHue);
  }

  /// Status-bar icon treatment for the active palette. Dark surfaces need
  /// light icons and vice versa.
  static SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: _palette.bg,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
      );
}

/// Semantic colors for the active theme.
class AppColors {
  AppColors._();

  static ArcPalette get _p => ArcTheme.palette;

  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surface2 => _p.surface2;

  static Color get ink => _p.ink;
  static Color get muted => _p.muted;
  static Color get faint => _p.faint;

  static Color get line => _p.line;
  static Color get cardLine => _p.cardLine;

  static Color get accent => _p.accent;
  static Color get accentInk => _p.accentInk;
  static Color get accentStrong => _p.accentStrong;
  static Color get accentSoft => _p.accentSoft;
  static Color get accentLine => _p.accentLine;

  static Color get up => _p.up;
  static Color get danger => _p.danger;
  static Color get dangerSoft => _p.dangerSoft;

  static Color get bar => _p.bar;
  static Color get toastBg => _p.toastBg;
  static Color get toastInk => _p.toastInk;

  static Color get navBg => _p.navBg;
  static Color get navLine => _p.navLine;
  static Color get navMuted => _p.navMuted;

  /// Modal scrim — `rgba(10,8,6,0.42)` in the design, shared by both themes.
  static const scrim = Color(0x6B0A0806);

  /// Bottom-sheet lift — `0 -10px 40px rgba(0,0,0,0.18)`, shared by both
  /// themes.
  static const sheetShadow = [
    BoxShadow(color: Color(0x2E000000), blurRadius: 40, offset: Offset(0, -10)),
  ];

  // Muscle-group colour lives in `MusclePalette` now: thirteen groups each own
  // a hue the user can repoint, all at the design's `oklch(0.68 0.15 H)`, and
  // theme-independent as it has always been. See `theme/muscle_palette.dart`.

  // The figure on the Exercises screen.
  //
  // It renders into the page's own background rather than a framed panel, so
  // the canvas ground is just [bg] — the body sits *in* the screen instead of
  // in a box cut out of it.
  static Color get bodyField => _p.bg;

  /// The figure's colour in the light theme, where it is drawn as accumulated
  /// ink on paper rather than as accumulated light. Tinted off the accent so
  /// the two polarities are recognisably the same figure, and kept dark enough
  /// that the densest passages still clear contrast against [bg].
  static Color get bodyInk =>
      Color.lerp(_p.ink, _p.accentStrong, 0.22) ?? _p.ink;

  /// The colour of a coarse region — what the calendar and the session dots
  /// speak. Summarised from the groups inside it rather than held separately;
  /// see [MusclePalette.regionColor].
  static Color group(String g) => MusclePalette.regionColor(g);
}

/// Corner radii for the active theme.
class AppRadii {
  AppRadii._();

  static double get sm => ArcTheme.palette.radiusSm;
  static double get md => ArcTheme.palette.radiusMd;
  static double get lg => ArcTheme.palette.radiusLg;

  static BorderRadius get rSm => BorderRadius.circular(sm);
  static BorderRadius get rMd => BorderRadius.circular(md);
  static BorderRadius get rLg => BorderRadius.circular(lg);
}

class AppShadows {
  AppShadows._();

  /// Soft card lift.
  static List<BoxShadow> get card => ArcTheme.palette.cardShadow;

  /// Subtle inner-control shadow.
  static List<BoxShadow> get sm => ArcTheme.palette.smallShadow;

  /// The accent glow under primary buttons and the FAB.
  static List<BoxShadow> get accent {
    final p = ArcTheme.palette;
    return [
      BoxShadow(
        color: p.accent.withValues(alpha: p.accentGlowOpacity),
        blurRadius: p.accentGlowBlur,
        offset: const Offset(0, 6),
      ),
    ];
  }
}

/// Typography. Both faces are bundled variable fonts, so the `wght` axis is
/// driven directly for crisp weights.
class AppText {
  AppText._();

  static const _tabular = [FontFeature.tabularFigures()];

  /// Primary face — Sora.
  static String get family => ArcTheme.palette.fontFamily;

  /// Secondary face — Space Grotesk.
  static String get monoFamily => ArcTheme.palette.monoFamily;

  /// Primary slot: display + body.
  static TextStyle ui({
    required double size,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      color: color ?? AppColors.ink,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Secondary slot: numerals, set with tabular figures so columns of weights
  /// stay aligned.
  static TextStyle mono({
    required double size,
    FontWeight weight = FontWeight.w600,
    Color? color,
    double? height,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontSize: size,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      color: color ?? AppColors.ink,
      height: height,
      fontFeatures: _tabular,
    );
  }
}

ThemeData buildArcTheme() {
  final p = ArcTheme.palette;
  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    fontFamily: p.fontFamily,
    scaffoldBackgroundColor: p.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: p.brightness,
      primary: p.accent,
      onPrimary: p.accentInk,
      surface: p.surface,
      onSurface: p.ink,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: p.ink,
      displayColor: p.ink,
      fontFamily: p.fontFamily,
    ),
  );
}
