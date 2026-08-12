import 'dart:math' show pi;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// The checkbox drawn in place of a `☐`/`☑` in a note.
///
/// A drawn control, not the stored character: the marks in the text are
/// storage, and a bare Unicode ballot box on screen would be a glyph standing
/// in for an icon. Sized off the run it sits in, so a checklist item set at
/// x-large gets a box to match.
class NoteCheckbox extends StatelessWidget {
  final bool checked;

  /// Font size of the run this box sits in.
  final double fontSize;

  /// Null in a read-only note — a companion reads the list, they don't work it.
  final VoidCallback? onTap;

  const NoteCheckbox({
    super.key,
    required this.checked,
    required this.fontSize,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = fontSize * 0.92;
    final art = SizedBox(
      width: box,
      height: box,
      child: CustomPaint(
        painter: _CheckboxPainter(
          checked: checked,
          empty: AppColors.faint,
          fill: AppColors.accent,
          tick: AppColors.accentInk,
        ),
      ),
    );

    final labelled = Semantics(
      label: checked ? 'Checked' : 'Unchecked',
      checked: checked,
      button: onTap != null,
      excludeSemantics: true,
      child: art,
    );

    if (onTap == null) return labelled;
    return GestureDetector(
      // The box is smaller than a thumb, and it lives inside a text field that
      // will happily take the tap as a caret move. Opaque, and padded out
      // sideways as far as the line will allow without shifting the text.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: labelled,
    );
  }
}

class _CheckboxPainter extends CustomPainter {
  final bool checked;
  final Color empty;
  final Color fill;
  final Color tick;

  _CheckboxPainter({
    required this.checked,
    required this.empty,
    required this.fill,
    required this.tick,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.06, s * 0.06, s * 0.88, s * 0.88),
      Radius.circular(s * 0.28),
    );

    if (!checked) {
      canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.11
          ..color = empty,
      );
      return;
    }

    canvas.drawRRect(r, Paint()..color = fill);
    final path = Path()
      ..moveTo(s * 0.27, s * 0.52)
      ..lineTo(s * 0.43, s * 0.68)
      ..lineTo(s * 0.74, s * 0.33);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.14
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = tick,
    );
  }

  @override
  bool shouldRepaint(_CheckboxPainter old) =>
      old.checked != checked ||
      old.empty != empty ||
      old.fill != fill ||
      old.tick != tick;
}

/// The highlighter in the note toolbar.
///
/// Drawn rather than picked from the icon registry: this Flutter build has no
/// `format_ink_highlighter`, and the Material glyphs that come closest
/// (`border_color`, `brush`) read as "edit" and "paint" — neither of which is
/// the action. A marker held at an angle over the stroke it leaves is the one
/// shape that says highlight, and it is thirty lines.
class HighlighterGlyph extends StatelessWidget {
  final double size;
  final Color color;

  const HighlighterGlyph({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _HighlighterPainter(color)),
      );
}

class _HighlighterPainter extends CustomPainter {
  final Color color;

  _HighlighterPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // Authored on a 24-unit grid, to match the Material glyphs it sits beside.
    final u = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The mark the marker leaves: a stroke under the pen, at the weight of a
    // real highlighter pass rather than a rule.
    canvas.drawLine(
      Offset(4 * u, 20.4 * u),
      Offset(20 * u, 20.4 * u),
      Paint()
        ..color = color
        ..strokeWidth = 2.6 * u
        ..strokeCap = StrokeCap.round,
    );

    canvas.save();
    canvas.translate(13.2 * u, 9.6 * u);
    canvas.rotate(pi / 5);

    // Barrel.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-3.4 * u, -8.2 * u, 6.8 * u, 9.2 * u),
        Radius.circular(1.5 * u),
      ),
      paint,
    );
    // Nib — tapered, and filled so the business end reads as the heavy part.
    canvas.drawPath(
      Path()
        ..moveTo(-3.4 * u, 1.0 * u)
        ..lineTo(3.4 * u, 1.0 * u)
        ..lineTo(1.9 * u, 5.4 * u)
        ..lineTo(-1.9 * u, 5.4 * u)
        ..close(),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HighlighterPainter old) => old.color != color;
}
