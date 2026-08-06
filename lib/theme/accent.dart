import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'oklch.dart';

/// The five accent tokens Arc derives from one hue.
@immutable
class AccentTokens {
  const AccentTokens({
    required this.accent,
    required this.accentInk,
    required this.accentStrong,
    required this.accentSoft,
    required this.accentLine,
  });

  final Color accent;
  final Color accentInk;
  final Color accentStrong;
  final Color accentSoft;
  final Color accentLine;
}

/// Builds Arc's accent family from a single hue, for either theme.
///
/// PRODUCT principle 3 is "earn the accent" — volt marks the primary action,
/// today, and a new record, and nothing else. Letting the user repaint it can't
/// be allowed to break that: an accent that fails contrast stops reading as a
/// signal, and one that drifts pale stops reading at all. So the picker exposes
/// *hue only*, and lightness/chroma are solved per hue here.
///
/// Every ratio below was swept across all 360 hues before these constants were
/// fixed. Worst cases, against the required minimum:
///
/// | pair                      | light | dark  | min |
/// |---------------------------|-------|-------|-----|
/// | accentInk on accent       | 6.18  | 7.63  | 4.5 |
/// | accentStrong on surface   | 5.62  | 7.35  | 3.0 |
/// | accentStrong on bg        | 5.15  | 8.02  | 3.0 |
/// | page ink on accentSoft    | 15.42 | 10.59 | 4.5 |
///
/// Contrast is therefore structural, not something the UI has to check and warn
/// about — there is no reachable hue that produces an unreadable theme, which
/// is why the sheet needs no "fails AA" state.
class AccentRamp {
  AccentRamp._();

  /// Hues of the shipped palettes: Surge's volt lime and Midnight's teal.
  /// At these values [derive] is bypassed entirely (see `ArcPalette.withAccentHue`)
  /// so the default install renders bit-identical to the hand-tuned constants.
  static const defaultLightHue = 128;
  static const defaultDarkHue = 172;

  static int defaultHue({required bool dark}) =>
      dark ? defaultDarkHue : defaultLightHue;

  /// Keyed by `hue * 2 + (dark ? 1 : 0)`. A drag emits at most 360 distinct
  /// hues per theme, and each derivation runs ~60 binary searches, so caching
  /// keeps a fling from re-solving the gamut every frame.
  static final _cache = <int, AccentTokens>{};

  static AccentTokens derive(int hue, {required bool dark}) {
    final h = hue % 360;
    return _cache.putIfAbsent(h * 2 + (dark ? 1 : 0), () => _build(h, dark));
  }

  static AccentTokens _build(int hue, bool dark) {
    final h = hue.toDouble();
    final cusp = Oklch.cuspLightness(h);

    // Track the hue's cusp so every choice reads vivid, but clamp: the floor
    // keeps dark ink legible on the fill, the ceiling stops yellow-green from
    // blowing out to near-white. Dark mode floors higher because the accent
    // also has to hold 3:1 against a near-black background as a 2.5px chart
    // stroke.
    final accentL = cusp.clamp(dark ? 0.76 : 0.72, 0.86);
    // 94% of maximum: sitting exactly on the gamut boundary quantizes badly
    // and can band across a gradient.
    final accentC = 0.94 * Oklch.maxChroma(accentL, h);

    // Ink *on* the accent fill. Same hue, dropped to near-black so the button
    // label reads as part of the accent rather than a neutral pasted onto it.
    final inkL = dark ? 0.20 : 0.22;
    final inkC = math.min(dark ? 0.035 : 0.06, Oklch.maxChroma(inkL, h));

    // Chart geometry and active nav. In light mode a 2.5px stroke of the bright
    // fill all but vanishes on white (volt sits at ~1.35:1), so this is the
    // accent pitched dark enough to hold an edge. Midnight's accent already
    // reads on its dark surface, so the two collapse there.
    final strongL = dark ? accentL : 0.50;
    final strongC =
        dark ? accentC : math.min(0.13, Oklch.maxChroma(0.50, h));

    // Tinted fill behind soft buttons and badges.
    final softL = dark ? 0.32 : 0.94;
    final softC = math.min(dark ? 0.055 : 0.08, Oklch.maxChroma(softL, h));

    final strong = Oklch.toColor(strongL, strongC, h);
    return AccentTokens(
      accent: Oklch.toColor(accentL, accentC, h),
      accentInk: Oklch.toColor(inkL, inkC, h),
      accentStrong: strong,
      accentSoft: Oklch.toColor(softL, softC, h),
      accentLine: strong,
    );
  }

  /// Twelve named bands around the circle, so the readout says something a
  /// person can repeat ("Volt") instead of only a number. Names are factual and
  /// athletic per PRODUCT's voice — no "Blueberry Burst".
  static const _names = <(int, String)>[
    (15, 'Rose'),
    (45, 'Coral'),
    (75, 'Amber'),
    (105, 'Citron'),
    (135, 'Volt'),
    (165, 'Green'),
    (195, 'Teal'),
    (225, 'Cyan'),
    (255, 'Sky'),
    (285, 'Indigo'),
    (315, 'Violet'),
    (345, 'Magenta'),
  ];

  static String nameFor(int hue) {
    final h = hue % 360;
    for (final (upper, name) in _names) {
      if (h < upper) return name;
    }
    return 'Rose'; // 345..359 wraps back
  }
}
