import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A run of text on the card, and what it needs from whatever is painted under
/// it: where its top-right corner sits on the motif's ramp (0 at the strongest
/// corner, 1 where the motif has gone), the color it's drawn in, and the
/// contrast ratio it has to clear — 4.5 for body text, 3.0 for the title.
typedef ClawTextZone = ({double reach, Color color, double ratio});

/// The tiger claw-rake behind a shared workout card.
///
/// Eight bands tear down from the top-right corner at ~66°, widest where they
/// leave the edge and drawn out to a needle point. Their flanks are barbed
/// rather than smooth: each one is a run of forward-hooking teeth cut back by a
/// notch, so the silhouette reads as torn — a claw rip, not an airbrushed
/// stripe. That serration is the whole motif; a tapered sliver with clean edges
/// looks like a swoosh.
///
/// It carries the live accent and blends against the live surface, so a card
/// shared on a violet theme comes out violet and a card shared in dark mode
/// comes out dark. That's why this is painted rather than shipped as an image
/// asset — the accent is derived per-hue across all 360 (see `AccentRamp`).
///
/// Two things keep it bold without eating the content, both from PRODUCT.md —
/// "the numbers are the interface" and "earn the accent":
///
///   * The rake is near-solid in the top-right corner, which is empty by
///     construction, and the alpha ramp falls off hard along the diagonal, so
///     what crosses the exercise list is a wash rather than a wall. The set
///     chips are opaque and sit above it, so no numeral is ever on a band.
///   * [_peak] is not a constant. The card hands over a [ClawTextZone] for every
///     run of text it drew and where it landed; the motif is then painted at the
///     strongest accent that still clears WCAG at all of them, solved against
///     the accent actually in force. A poster of short exercise names in one
///     column gets the full rake; a twelve-exercise card whose second column
///     runs into the corner gets a quieter one. Boldness is capped by contrast,
///     not by nerve.
///
/// Nothing here is random — geometry comes from [_bands] and a fixed jitter
/// table, so the same workout exports the same image every time.
class ClawPainter extends CustomPainter {
  ClawPainter({
    required this.accent,
    required this.surface,
    required this.dark,
    required this.zones,
  });

  final Color accent;

  /// What the bands composite onto — needed to solve [_peak].
  final Color surface;

  /// Every run of text on the card, and where it landed. See [ClawTextZone].
  final List<ClawTextZone> zones;

  /// A saturated accent at full strength reads as neon against near-black and
  /// as paper against white, so the two themes get different ceilings.
  final bool dark;

  /// Travel direction, unit length: down and to the left at about 66° below
  /// horizontal. Steep enough to rake, not so steep it reads as banding.
  static const _d = Offset(-0.402, 0.9156);

  /// Perpendicular to [_d], pointing right — band half-widths are measured
  /// along this.
  static const _p = Offset(0.9156, 0.402);

  /// How far above the top edge each band starts, as a fraction of height. The
  /// bands are already at full width and mid-barb when they cross into view,
  /// which is what makes them read as passing through rather than starting.
  static const _lead = 0.32;

  /// Width falloff along the run: `(1 - u) ^ _taper`. Under 1 it holds the
  /// width most of the way and then collapses into the point.
  static const _taper = 0.7;

  /// Where each band's spine crosses the top edge (fraction of width; over 1
  /// means it enters through the right edge instead), its half-width there
  /// (fraction of width), and how far it travels (fraction of height).
  ///
  /// Hand-placed, not stepped: an even comb reads as a texture swatch. Widths
  /// alternate heavy and thin so splinters run between the fat marks, the gaps
  /// between them vary, and the lengths are staggered so six of the seven tips
  /// land inside the card at different heights — the tips are the drama, and a
  /// rake where every mark exits the bottom edge has none.
  static const _bands = <({double x, double w, double len, int seed})>[
    (x: 0.4915, w: 0.0365, len: 0.44, seed: 0),
    (x: 0.6495, w: 0.0665, len: 0.88, seed: 1),
    (x: 0.7690, w: 0.0230, len: 0.60, seed: 2),
    (x: 0.9140, w: 0.0740, len: 0.95, seed: 3),
    (x: 1.0560, w: 0.0320, len: 0.80, seed: 4),
    (x: 1.2365, w: 0.0885, len: 1.34, seed: 5),
    (x: 1.4235, w: 0.0565, len: 1.00, seed: 6),
  ];

  /// Authored irregularity. A hash would drift between the Dart VM and JS
  /// integer semantics; a table is identical everywhere and can be tuned by
  /// eye, which is what a claw needs.
  static const _jitter = <double>[
    0.62, 0.18, 0.87, 0.41, 0.06, 0.73, //
    0.29, 0.95, 0.52, 0.11, 0.80, 0.36, //
    0.68, 0.24, 0.91, 0.47, 0.03, 0.77, //
    0.33, 0.59, 0.15, 0.84, 0.44, 0.70, //
  ];

  static double _j(int i) => _jitter[i % _jitter.length];

  /// The alpha ramp from the top-right corner to the bottom-left one: full
  /// strength through the empty corner, then a steep fall, so by the time a
  /// band is over the exercise list it is a tint. One definition, read both by
  /// the shader and by [_peak].
  static const _stops = <double>[0, 0.14, 0.32, 0.56, 0.84];
  static const _falloff = <double>[1, 1, 0.52, 0.13, 0];

  static double _rampAt(double t) {
    if (t <= _stops.first) return _falloff.first;
    for (var i = 1; i < _stops.length; i++) {
      if (t <= _stops[i]) {
        final f = (t - _stops[i - 1]) / (_stops[i] - _stops[i - 1]);
        return _falloff[i - 1] + (_falloff[i] - _falloff[i - 1]) * f;
      }
    }
    return _falloff.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final peak = _peak();

    // One shader for the whole rake, not one per band, so the fade is a
    // property of the corner rather than of each mark. It's on the fill rather
    // than washed over the top, so it follows the barbs exactly and leaves no
    // rectangular ghost.
    final shader = LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [
        for (final f in _falloff) accent.withValues(alpha: peak * f),
      ],
      stops: _stops,
    ).createShader(Offset.zero & size);

    // All eight bands in one path and one fill: where two overlap the alpha
    // composites once, so no seam darkens the join.
    final rake = Path()..fillType = PathFillType.nonZero;
    for (final b in _bands) {
      rake.addPath(_claw(size, b), Offset.zero);
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawPath(rake, Paint()..shader = shader..isAntiAlias = true);
    canvas.restore();
  }

  /// One claw mark: a barbed ribbon from off the top edge to a needle point.
  Path _claw(Size size, ({double x, double w, double len, int seed}) b) {
    final run = b.len * size.height;
    final origin = Offset(b.x * size.width, 0);

    Offset at(double t, double off) => origin + _d * t + _p * off;
    double hw(double u) =>
        b.w * size.width * math.pow(1 - u.clamp(0.0, 1.0), _taper).toDouble();

    // Out along one flank, back along the other. The tip is the last point of
    // both, so the return walk skips it rather than doubling it. The two ends
    // sit a lead above the top edge, where the closing line is off-canvas.
    final head = at(-_lead * size.height, hw(0));
    final tail = at(-_lead * size.height, -hw(0));
    final outline = [
      head,
      ..._flank(b, 1, run, at, hw),
      ..._flank(b, -1, run, at, hw).reversed.skip(1),
      tail,
    ];

    final path = Path()..moveTo(head.dx, head.dy);
    for (final pt in outline.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    return path..close();
  }

  /// One side of a band, from the top edge to the tip.
  ///
  /// A short clean run-in, then a sequence of teeth: each climbs outward on a
  /// curve to a sharp point aimed down the direction of travel, then gets cut
  /// back and slightly into the body. The last tooth has nowhere to climb — the
  /// half-width is zero there — so it resolves into the point.
  List<Offset> _flank(
    ({double x, double w, double len, int seed}) b,
    int side,
    double run,
    Offset Function(double, double) at,
    double Function(double) hw,
  ) {
    /// Two or three teeth per flank, scaled by length so tooth size stays
    /// roughly constant across the composition. Deliberately few: at any higher
    /// frequency the flanks stop reading as tears and start reading as grass.
    final teeth = math.max(2, (b.len * 2.3).round());
    const runIn = 0.10;

    final weights = [
      for (var i = 0; i < teeth; i++)
        0.65 + 0.7 * _j(b.seed * 11 + side * 5 + i),
    ];
    final total = weights.fold<double>(0, (a, x) => a + x);

    final pts = <Offset>[
      at(0, side * hw(0)),
      at(runIn * run, side * hw(runIn)),
    ];

    var cursor = runIn;
    for (var i = 0; i < teeth; i++) {
      final last = i == teeth - 1;
      final end =
          last ? 1.0 : cursor + (1 - runIn) * weights[i] / total;
      final amp = hw(end) * (0.28 + 0.80 * _j(b.seed * 17 + side * 7 + i * 3));

      // The outer edge accelerates outward (v^1.75) rather than ramping, which
      // is what gives the tooth its hooked belly instead of a triangle.
      for (final v in const [0.22, 0.45, 0.66, 0.83, 1.0]) {
        final u = cursor + (end - cursor) * v;
        pts.add(at(
          u * run,
          side * (hw(u) + amp * math.pow(v, 1.75).toDouble()),
        ));
      }

      if (!last) {
        final back = 0.34 + 0.30 * _j(b.seed * 23 + side * 3 + i * 5);
        final cut = cursor + (end - cursor) * (1 - back);
        final bite = hw(cut) * (0.10 + 0.30 * _j(b.seed * 29 + side * 13 + i));
        pts.add(at(cut * run, side * (hw(cut) - bite)));
      }
      cursor = end;
    }

    return pts;
  }

  /// The alpha the rake reaches in the corner.
  ///
  /// Steps down from the theme's ceiling until every [ClawTextZone] the card
  /// reported clears its ratio against the tint the motif actually leaves under
  /// it. The shipped palettes hold the ceiling for an ordinary workout; a dense
  /// card or a hand-picked hue that doesn't gets a quieter rake rather than an
  /// unreadable poster.
  double _peak() {
    final ceiling = dark ? 0.82 : 0.95;
    for (var p = ceiling; p > 0.20; p -= 0.02) {
      var ok = true;
      for (final z in zones) {
        final under = Color.lerp(surface, accent, p * _rampAt(z.reach))!;
        if (_contrast(z.color, under) < z.ratio) {
          ok = false;
          break;
        }
      }
      if (ok) return p;
    }
    return 0.20;
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  @override
  bool shouldRepaint(ClawPainter old) =>
      old.accent != accent ||
      old.surface != surface ||
      old.dark != dark ||
      !listEquals(old.zones, zones);
}

/// The motif sized to fill its parent, reading the palette in force.
class ClawBackdrop extends StatelessWidget {
  const ClawBackdrop({super.key, required this.zones});

  /// Where the card put its text. See [ClawTextZone].
  final List<ClawTextZone> zones;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: ClawPainter(
            accent: AppColors.accent,
            surface: AppColors.surface,
            dark: ArcTheme.isDark,
            zones: zones,
          ),
        ),
      ),
    );
  }
}
