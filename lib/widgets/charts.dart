import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../data/arc_data.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// Smooth line chart of score (1RM / reps) over time, with area fill + end dot.
class LineChart extends StatelessWidget {
  final List<num> data;
  final double height;
  final double pad;
  final bool showDots;
  final double strokeW;

  const LineChart({
    super.key,
    required this.data,
    this.height = 130,
    this.pad = 10,
    this.showDots = true,
    this.strokeW = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, c) {
          if (data.isEmpty || c.maxWidth == 0) return const SizedBox.shrink();
          return CustomPaint(
            size: Size(c.maxWidth, height),
            painter: _LinePainter(
              data: data.map((e) => e.toDouble()).toList(),
              pad: pad,
              showDots: showDots,
              strokeW: strokeW,
            ),
          );
        },
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<double> data;
  final double pad;
  final bool showDots;
  final double strokeW;

  _LinePainter({
    required this.data,
    required this.pad,
    required this.showDots,
    required this.strokeW,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final height = size.height;
    var lo = data.reduce((a, b) => a < b ? a : b);
    var hi = data.reduce((a, b) => a > b ? a : b);
    if (hi == lo) {
      hi += 1;
      lo -= 1;
    }
    final range = hi - lo;
    lo -= range * 0.18;
    hi += range * 0.18;

    const padT = 12.0, padB = 12.0;
    final padL = pad, padR = pad;
    final innerW = (w - padL - padR).clamp(1.0, double.infinity);
    final innerH = height - padT - padB;
    double x(int i) =>
        padL + (data.length == 1 ? innerW / 2 : (i / (data.length - 1)) * innerW);
    double y(double v) => padT + innerH - ((v - lo) / (hi - lo)) * innerH;

    final pts = [for (var i = 0; i < data.length; i++) Offset(x(i), y(data[i]))];

    // dashed midline
    final midY = padT + innerH * 0.5;
    final dashPaint = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    const dash = 2.0, gap = 5.0;
    var dx = padL;
    while (dx < w - padR) {
      canvas.drawLine(Offset(dx, midY), Offset((dx + dash).clamp(0, w - padR), midY), dashPaint);
      dx += dash + gap;
    }

    // smooth path (catmull-rom → bezier)
    final line = Path();
    if (pts.length == 1) {
      line.moveTo(pts[0].dx, pts[0].dy);
    } else {
      line.moveTo(pts[0].dx, pts[0].dy);
      for (var i = 0; i < pts.length - 1; i++) {
        final p0 = i > 0 ? pts[i - 1] : pts[i];
        final p1 = pts[i];
        final p2 = pts[i + 1];
        final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
        final c1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
        final c2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
        line.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
      }
    }

    // area fill
    if (pts.length > 1) {
      final area = Path.from(line)
        ..lineTo(x(data.length - 1), padT + innerH)
        ..lineTo(x(0), padT + innerH)
        ..close();
      final areaPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.accent.withValues(alpha: 0.28),
            AppColors.accent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, padT, w, innerH));
      canvas.drawPath(area, areaPaint);
    }

    // line
    canvas.drawPath(
      line,
      Paint()
        ..color = AppColors.accentLine
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // last dot
    if (showDots) {
      final last = pts.last;
      canvas.drawCircle(
          last, 6.5, Paint()..color = AppColors.accentLine.withValues(alpha: 0.18));
      canvas.drawCircle(last, 3.6, Paint()..color = AppColors.surface);
      canvas.drawCircle(
        last,
        3.6,
        Paint()
          ..color = AppColors.accentLine
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.data != data || old.strokeW != strokeW;
}

/// Tiny inline sparkline (no axes), fixed box. Uses [color] for stroke+dot,
/// defaulting to the active theme's accent.
class Spark extends StatelessWidget {
  final List<num> data;
  final double width;
  final double height;
  final double strokeW;
  final Color? color;

  const Spark({
    super.key,
    required this.data,
    this.width = 64,
    this.height = 28,
    this.strokeW = 2,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _SparkPainter(
        data.map((e) => e.toDouble()).toList(),
        strokeW,
        color ?? AppColors.accentStrong,
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> data;
  final double strokeW;
  final Color color;
  _SparkPainter(this.data, this.strokeW, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final w = size.width, h = size.height;
    final lo = data.reduce((a, b) => a < b ? a : b);
    var hi = data.reduce((a, b) => a > b ? a : b);
    if (hi == 0) hi = 1;
    final rng = (hi - lo) == 0 ? 1 : (hi - lo);
    double x(int i) =>
        data.length == 1 ? w / 2 : (i / (data.length - 1)) * (w - 4) + 2;
    double y(double v) => h - 3 - ((v - lo) / rng) * (h - 6);

    final path = Path();
    for (var i = 0; i < data.length; i++) {
      if (i == 0) {
        path.moveTo(x(i), y(data[i]));
      } else {
        path.lineTo(x(i), y(data[i]));
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(
      Offset(x(data.length - 1), y(data.last)),
      2.6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.data != data || old.color != color;
}

/// Vertical bars (e.g. weekly set counts); last bar is highlighted in accent.
class Bars extends StatelessWidget {
  final List<num> data;
  final double height;
  final List<String>? labels;
  const Bars({super.key, required this.data, this.height = 96, this.labels});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height + 18,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, c) {
          if (data.isEmpty || c.maxWidth == 0) return const SizedBox.shrink();
          return CustomPaint(
            size: Size(c.maxWidth, height + 18),
            painter: _BarsPainter(
              data.map((e) => e.toDouble()).toList(),
              height,
              labels,
            ),
          );
        },
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> data;
  final double height;
  final List<String>? labels;
  _BarsPainter(this.data, this.height, this.labels);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final hi = data.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);
    const gap = 8.0;
    final n = data.length;
    final bw = (w - gap * (n - 1)) / n;
    for (var i = 0; i < n; i++) {
      final h = (data[i] / hi * height).clamp(3.0, height);
      final xx = i * (bw + gap);
      final isLast = i == n - 1;
      final r = (bw / 2).clamp(0.0, 7.0);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(xx, height - h, bw, h),
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
      );
      canvas.drawRRect(
        rect,
        Paint()..color = isLast ? AppColors.accentLine : AppColors.bar,
      );
      if (labels != null && i < labels!.length) {
        final tp = TextPainter(
          text: TextSpan(
            text: labels![i],
            style: AppText.mono(
              size: 10.5,
              weight: FontWeight.w600,
              color: isLast ? AppColors.accentStrong : AppColors.faint,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(xx + bw / 2 - tp.width / 2, height + 4));
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.data != data;
}

/// One session in a progression chart: a measured [value] on its [date].
class ProgressPoint {
  final DateTime date;
  final double value;
  const ProgressPoint(this.date, this.value);
}

/// Line chart of a per-session metric (e.g. max weight) with real axes:
/// a labelled value axis on the left and a time axis along the bottom.
///
/// Unlike a sparkline, the X position of each session is spaced by the actual
/// elapsed days between sessions, and Y is zoomed to the data's own range (not
/// forced through zero) and labelled, so every lift shows its genuine trend
/// instead of a normalised swoosh.
class ProgressChart extends StatelessWidget {
  final List<ProgressPoint> points; // chronological, earliest first
  final String unit; // 'kg' | 'reps' | 'min/km' — shown on the top value label
  final double height;

  /// How to render a value on the axis and in the tap dialog.
  ///
  /// Null renders a plain number, which is right for kilograms and reps. Pace
  /// needs it: an axis reading `4.5` where the runner thinks in `4:32` is a
  /// number they have to convert in their head every time they glance at it.
  final String Function(double)? formatValue;

  const ProgressChart({
    super.key,
    required this.points,
    this.unit = 'kg',
    this.height = 150,
    this.formatValue,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, c) {
          if (points.isEmpty || c.maxWidth == 0) return const SizedBox.shrink();
          final size = Size(c.maxWidth, height);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _handleTap(context, d.localPosition, size),
            child: CustomPaint(
              size: size,
              painter: _ProgressPainter(
                  points: points, unit: unit, formatValue: formatValue),
            ),
          );
        },
      ),
    );
  }

  /// Hit-tests the tap against every session's plotted X position (using the
  /// same layout the painter draws with) and opens a value dialog for the
  /// nearest one, as long as the tap actually landed near a point.
  void _handleTap(BuildContext context, Offset local, Size size) {
    final geo = _ProgressGeometry(
        points: points, unit: unit, size: size, formatValue: formatValue);
    var bestI = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final dist = (geo.x(i) - local.dx).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestI = i;
      }
    }
    if (bestDist > 28) return;
    showDialog<void>(
      context: context,
      barrierColor: AppColors.scrim,
      builder: (_) => _SessionValueDialog(
          point: points[bestI], unit: unit, formatValue: formatValue),
    );
  }
}

/// Shows the exact value + date of a tapped session point.
class _SessionValueDialog extends StatelessWidget {
  final ProgressPoint point;
  final String unit;
  final String Function(double)? formatValue;
  const _SessionValueDialog(
      {required this.point, required this.unit, this.formatValue});

  @override
  Widget build(BuildContext context) {
    final valueLabel = formatValue != null
        ? formatValue!(point.value)
        : unit == 'reps'
            ? point.value.round().toString()
            : _ProgressPainter._fmt(point.value);
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 56),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.rLg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ArcData.fmtDate(ArcData.iso(point.date), 'long'),
              style: AppText.ui(
                  size: 13.5, weight: FontWeight.w600, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(valueLabel,
                    style: AppText.mono(size: 30, weight: FontWeight.w700)),
                const SizedBox(width: 6),
                Text(unit,
                    style: AppText.ui(
                        size: 14, weight: FontWeight.w600, color: AppColors.muted)),
              ],
            ),
            const SizedBox(height: 18),
            ArcButton(
              label: 'Close',
              variant: BtnVariant.quiet,
              full: true,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

const _monShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// Shared layout math for [ProgressChart]'s axes and point positions — used
/// by both the painter (to draw) and the widget (to hit-test taps), so a tap
/// always lands on the same coordinates the chart was drawn with.
class _ProgressGeometry {
  final List<ProgressPoint> points;
  final double padL, padR, padT, padB;
  final double innerW, innerH;
  final double axisLo, axisHi;
  final List<double> grid;
  final double dateLabelW;

  factory _ProgressGeometry({
    required List<ProgressPoint> points,
    required String unit,
    required Size size,
    String Function(double)? formatValue,
  }) {
    String fmt(double v) => formatValue?.call(v) ?? _ProgressPainter._fmt(v);
    final lo = points.map((p) => p.value).reduce(math.min);
    final hi = points.map((p) => p.value).reduce(math.max);
    final (axisLo, axisHi, step) = _niceScale(lo, hi);
    final grid = <double>[
      for (var v = axisLo; v <= axisHi + step * 0.5; v += step)
        double.parse(v.toStringAsFixed(5)), // tame float drift
    ];

    TextPainter ylab(String s) => TextPainter(
          text: TextSpan(
            text: s,
            style: AppText.mono(
                size: 10.5, weight: FontWeight.w600, color: AppColors.faint),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

    // gutter width sized to the widest value label (incl. unit on the top one)
    var gutterW = 0.0;
    for (final g in grid) {
      final isTop = g == grid.last;
      final tp = ylab(isTop ? '${fmt(g)} $unit' : fmt(g));
      if (tp.width > gutterW) gutterW = tp.width;
    }

    // date labels stack the day below the month ("Jun" / "3"), so reserve
    // two lines of height at the bottom instead of one.
    final dateTp = TextPainter(
      text: TextSpan(
        text: 'Jun\n1',
        style: AppText.ui(size: 10.5, weight: FontWeight.w500, color: AppColors.faint),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();

    final padL = gutterW + 8;
    const padR = 8.0, padT = 12.0;
    final padB = dateTp.height + 14;
    final innerW = (size.width - padL - padR).clamp(1.0, double.infinity);
    final innerH = (size.height - padT - padB).clamp(1.0, double.infinity);

    return _ProgressGeometry._(
      points: points,
      padL: padL,
      padR: padR,
      padT: padT,
      padB: padB,
      innerW: innerW,
      innerH: innerH,
      axisLo: axisLo,
      axisHi: axisHi,
      grid: grid,
      dateLabelW: dateTp.width,
    );
  }

  _ProgressGeometry._({
    required this.points,
    required this.padL,
    required this.padR,
    required this.padT,
    required this.padB,
    required this.innerW,
    required this.innerH,
    required this.axisLo,
    required this.axisHi,
    required this.grid,
    required this.dateLabelW,
  });

  double x(int i) {
    if (points.length == 1) return padL + innerW / 2;
    final tMin = points.first.date.millisecondsSinceEpoch;
    final tMax = points.last.date.millisecondsSinceEpoch;
    final tSpan = (tMax - tMin).toDouble();
    if (tSpan <= 0) return padL + (i / (points.length - 1)) * innerW;
    return padL +
        ((points[i].date.millisecondsSinceEpoch - tMin) / tSpan) * innerW;
  }

  double y(double v) =>
      padT + innerH - ((v - axisLo) / (axisHi - axisLo)) * innerH;
}

class _ProgressPainter extends CustomPainter {
  final List<ProgressPoint> points;
  final String unit;
  final String Function(double)? formatValue;
  _ProgressPainter(
      {required this.points, required this.unit, this.formatValue});

  static String _fmt(double v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  String _v(double v) => formatValue?.call(v) ?? _fmt(v);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final geo = _ProgressGeometry(
        points: points, unit: unit, size: size, formatValue: formatValue);
    final padL = geo.padL, padR = geo.padR, padT = geo.padT, padB = geo.padB;
    final innerW = geo.innerW, innerH = geo.innerH;

    // ── gridlines + Y labels ──
    TextPainter ylab(String s) => TextPainter(
          text: TextSpan(
            text: s,
            style: AppText.mono(
                size: 10.5, weight: FontWeight.w600, color: AppColors.faint),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

    final gridPaint = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    for (final g in geo.grid) {
      final gy = geo.y(g);
      const dash = 2.0, gap = 5.0;
      var dx = padL;
      while (dx < w - padR) {
        canvas.drawLine(Offset(dx, gy),
            Offset((dx + dash).clamp(0, w - padR), gy), gridPaint);
        dx += dash + gap;
      }
      final isTop = g == geo.grid.last;
      final tp = ylab(isTop ? '${_v(g)} $unit' : _v(g));
      tp.paint(canvas, Offset(padL - 8 - tp.width, gy - tp.height / 2));
    }

    final pts = [
      for (var i = 0; i < points.length; i++)
        Offset(geo.x(i), geo.y(points[i].value))
    ];

    // ── area fill under the line ──
    if (pts.length > 1) {
      final area = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        area.lineTo(pts[i].dx, pts[i].dy);
      }
      area
        ..lineTo(pts.last.dx, padT + innerH)
        ..lineTo(pts.first.dx, padT + innerH)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.accent.withValues(alpha: 0.22),
              AppColors.accent.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromLTWH(padL, padT, innerW, innerH)),
      );
    }

    // ── line: straight segments between real sessions (no distortion) ──
    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      line.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = AppColors.accentLine
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // ── a dot on every session, the latest one emphasised ──
    for (var i = 0; i < pts.length; i++) {
      final last = i == pts.length - 1;
      final r = last ? 4.0 : 3.0;
      canvas.drawCircle(pts[i], r, Paint()..color = AppColors.surface);
      canvas.drawCircle(
        pts[i],
        r,
        Paint()
          ..color = AppColors.accentLine
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // ── X (date) labels: month on top, day below (no side-by-side overlap) ──
    final maxLabels =
        (innerW / (geo.dateLabelW + 20)).floor().clamp(1, points.length);
    for (final i in _tickIndices(points.length, maxLabels)) {
      final d = points[i].date;
      final tp = TextPainter(
        text: TextSpan(
          text: '${_monShort[d.month - 1]}\n${d.day}',
          style: AppText.ui(
              size: 10.5, weight: FontWeight.w500, color: AppColors.faint),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      final maxX = (w - padR - tp.width).clamp(padL, double.infinity);
      final lx = (pts[i].dx - tp.width / 2).clamp(padL, maxX);
      tp.paint(canvas, Offset(lx, h - padB + 6));
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.points != points || old.unit != unit;
}

/// Evenly spaced tick indices over `0..n-1`, always including the endpoints.
List<int> _tickIndices(int n, int k) {
  if (n <= 1) return n == 1 ? const [0] : const [];
  if (k >= n) return [for (var i = 0; i < n; i++) i];
  if (k <= 1) return [n - 1];
  final out = <int>{};
  for (var j = 0; j < k; j++) {
    out.add((j * (n - 1) / (k - 1)).round());
  }
  return out.toList()..sort();
}

/// "Nice" axis bounds and tick step covering [lo, hi], zoomed to the data
/// (bounds are not forced to zero) so small differences stay legible.
(double, double, double) _niceScale(double lo, double hi, [int ticks = 4]) {
  if (hi <= lo) {
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.1;
    lo -= pad;
    hi += pad;
  }
  final range = _niceNum(hi - lo, false);
  final step = _niceNum(range / (ticks - 1), true);
  final niceLo = (lo / step).floorToDouble() * step;
  final niceHi = (hi / step).ceilToDouble() * step;
  return (niceLo, niceHi, step);
}

double _niceNum(double range, bool round) {
  final exp = (math.log(range) / math.ln10).floor();
  final frac = range / math.pow(10, exp);
  final double nf;
  if (round) {
    nf = frac < 1.5 ? 1 : (frac < 3 ? 2 : (frac < 7 ? 5 : 10));
  } else {
    nf = frac <= 1 ? 1 : (frac <= 2 ? 2 : (frac <= 5 ? 5 : 10));
  }
  return nf * math.pow(10, exp).toDouble();
}
