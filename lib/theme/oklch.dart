import 'dart:math' as math;
import 'dart:ui' show Color;

/// OKLCH → sRGB, with sRGB gamut mapping.
///
/// Arc derives a whole family of accent tokens from a single user-chosen hue,
/// which only works in a perceptually uniform space: equal steps in OKLCH
/// lightness *look* equal, so a role defined as "L = 0.50" reads as the same
/// darkness at every hue. The same promise in HSL is worthless — HSL 50% yellow
/// and HSL 50% blue differ by roughly 3:1 in luminance.
///
/// The awkward part is that sRGB is not a nice shape in OKLCH. The maximum
/// chroma available at a fixed lightness swings by ~3× around the hue circle
/// (at L = 0.85: 0.23 at green, 0.07 at blue-violet), so any fixed
/// lightness/chroma pair is unreachable for most hues. Everything here exists
/// to answer "how much chroma can this hue actually hold" — see [maxChroma]
/// and [cuspLightness].
class Oklch {
  Oklch._();

  /// Linear-light → gamma-encoded sRGB.
  static double _encode(double c) =>
      c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - 0.055;

  /// OKLCH → linear sRGB, unclamped. Components outside 0..1 mean the color
  /// is outside the sRGB gamut, which is exactly what [_inGamut] tests for.
  static (double, double, double) _linear(double l, double c, double h) {
    final hr = h * math.pi / 180;
    final a = c * math.cos(hr);
    final b = c * math.sin(hr);

    final lp = l + 0.3963377774 * a + 0.2158037573 * b;
    final mp = l - 0.1055613458 * a - 0.0638541728 * b;
    final sp = l - 0.0894841775 * a - 1.2914855480 * b;

    final ll = lp * lp * lp;
    final mm = mp * mp * mp;
    final ss = sp * sp * sp;

    return (
      4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
      -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
      -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss,
    );
  }

  static bool _inGamut(double l, double c, double h) {
    final (r, g, b) = _linear(l, c, h);
    const lo = -1e-4;
    const hi = 1 + 1e-4;
    return r >= lo && r <= hi && g >= lo && g <= hi && b >= lo && b <= hi;
  }

  /// The largest chroma this (lightness, hue) can hold inside sRGB.
  ///
  /// Binary search rather than a closed form: the gamut boundary is a cubic
  /// surface with no cheap analytic inverse, and 20 iterations lands within
  /// 4e-7 — far below a ue8 quantum.
  static double maxChroma(double l, double h) {
    var lo = 0.0;
    var hi = 0.4;
    for (var i = 0; i < 20; i++) {
      final mid = (lo + hi) / 2;
      if (_inGamut(l, mid, h)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The lightness at which [h] reaches peak chroma — the gamut "cusp".
  ///
  /// This is what lets a user-picked hue stay vivid instead of collapsing to
  /// pastel. Yellow peaks near L = 0.96, blue-violet near L = 0.45; pinning
  /// every hue to one lightness would starve half the circle of chroma.
  ///
  /// Coarse sweep then a local refine — cheaper than a fine sweep and the
  /// curve is unimodal in L, so the refine cannot miss the peak.
  static double cuspLightness(double h) {
    var best = 0.0;
    var bestC = -1.0;
    for (var l = 0.04; l <= 0.98; l += 0.02) {
      final c = maxChroma(l, h);
      if (c > bestC) {
        bestC = c;
        best = l;
      }
    }
    for (var l = best - 0.02; l <= best + 0.02; l += 0.004) {
      if (l <= 0 || l >= 1) continue;
      final c = maxChroma(l, h);
      if (c > bestC) {
        bestC = c;
        best = l;
      }
    }
    return best;
  }

  /// OKLCH → [Color], clamping into sRGB. Callers that care about staying in
  /// gamut should size their chroma with [maxChroma] first; the clamp here is
  /// a floor, not a strategy — it would shift hue if leaned on.
  static Color toColor(double l, double c, double h, {double opacity = 1}) {
    final (r, g, b) = _linear(l, c, h);
    int ch(double v) =>
        (_encode(v.clamp(0.0, 1.0)) * 255).round().clamp(0, 255);
    return Color.fromARGB((opacity * 255).round(), ch(r), ch(g), ch(b));
  }
}
