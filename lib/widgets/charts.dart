import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // last dot
    if (showDots) {
      final last = pts.last;
      canvas.drawCircle(
          last, 6.5, Paint()..color = AppColors.accent.withValues(alpha: 0.18));
      canvas.drawCircle(last, 3.6, Paint()..color = AppColors.surface);
      canvas.drawCircle(
        last,
        3.6,
        Paint()
          ..color = AppColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.data != data || old.strokeW != strokeW;
}

/// Tiny inline sparkline (no axes), fixed box. Uses [color] for stroke+dot.
class Spark extends StatelessWidget {
  final List<num> data;
  final double width;
  final double height;
  final double strokeW;
  final Color color;

  const Spark({
    super.key,
    required this.data,
    this.width = 64,
    this.height = 28,
    this.strokeW = 2,
    this.color = AppColors.accentStrong,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _SparkPainter(
        data.map((e) => e.toDouble()).toList(),
        strokeW,
        color,
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

/// Vertical bars (e.g. weekly volume); last bar is highlighted in accent.
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
        Paint()..color = isLast ? AppColors.accent : AppColors.bar,
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
