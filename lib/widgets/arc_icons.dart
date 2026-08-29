import 'package:flutter/material.dart';

/// Maps the design's stroke-icon names to Material rounded glyphs.
/// The rounded family mirrors the design's round line-caps and joins.
class ArcIcons {
  ArcIcons._();

  static IconData byName(String name, {bool filled = false}) {
    switch (name) {
      case 'home':
        return filled ? Icons.home_rounded : Icons.home_outlined;
      case 'trophy':
        return filled ? Icons.emoji_events_rounded : Icons.emoji_events_outlined;
      // No `filled` pair: the Material font has no solid calendar in any style
      // — `calendar_month`, `today` and `event` are all outlined frames — so the
      // nav's fill state is drawn instead. See [ArcCalendarGlyph], which
      // [ArcIcon] routes this name to. This stays the registry's answer for
      // anything that needs plain `IconData` (a toast, a list row).
      case 'calendar':
        return Icons.calendar_month_rounded;
      case 'dumbbell':
        return Icons.fitness_center_rounded;
      case 'plus':
        return Icons.add_rounded;
      case 'minus':
        return Icons.remove_rounded;
      case 'chevR':
        return Icons.chevron_right_rounded;
      case 'chevL':
        return Icons.chevron_left_rounded;
      case 'chevD':
        return Icons.keyboard_arrow_down_rounded;
      case 'x':
        return Icons.close_rounded;
      case 'trash':
        return Icons.delete_outline_rounded;
      case 'pencil':
        return Icons.edit_outlined;
      case 'check':
        return Icons.check_rounded;
      case 'flame':
        return Icons.local_fire_department_rounded;
      case 'trend':
        return Icons.trending_up_rounded;
      case 'arrowUp':
        return Icons.arrow_upward_rounded;
      case 'arrowDown':
        return Icons.arrow_downward_rounded;
      case 'clock':
        return Icons.schedule_rounded;
      // Conditioning. The runner reads as effort at every size Arc draws it,
      // where a heart reads as health and a stopwatch reads as the rest timer
      // this app already has one of.
      case 'run':
        return Icons.directions_run_rounded;
      case 'route':
        return Icons.route_rounded;
      // Rest timer transport. `replay` rather than a circular-arrow refresh:
      // reset puts the rest back to the top, it does not reload anything.
      case 'play':
        return Icons.play_arrow_rounded;
      case 'pause':
        return Icons.pause_rounded;
      case 'reset':
        return Icons.replay_rounded;
      case 'timer':
        return filled ? Icons.timer_rounded : Icons.timer_outlined;
      case 'sound':
        return Icons.volume_up_rounded;
      case 'vibrate':
        return Icons.vibration_rounded;
      case 'float':
        return Icons.picture_in_picture_alt_outlined;
      case 'target':
        return Icons.gps_fixed_rounded;
      // The drag rail on an arrangeable row — the library's refile grip and
      // the log sheet's reorder handle. Dots rather than `drag_handle`'s bars:
      // the bars read as a menu at this size, and Arc already spends three
      // stacked lines on nothing.
      case 'grip':
        return Icons.drag_indicator_rounded;
      case 'search':
        return Icons.search_rounded;
      case 'layers':
        return Icons.layers_outlined;
      case 'spark':
        return Icons.auto_awesome_rounded;
      case 'medal':
        return Icons.workspace_premium_rounded;
      case 'people':
        return filled ? Icons.people_rounded : Icons.people_outline_rounded;
      case 'qr':
        return Icons.qr_code_2_rounded;
      case 'scan':
        return Icons.qr_code_scanner_rounded;
      case 'image':
        return Icons.photo_library_outlined;
      // The three-node graph, not the iOS box-and-arrow: it reads as "send this
      // to someone" on both platforms, where the box-arrow means "open the
      // share sheet" only to an iPhone user.
      case 'share':
        return Icons.share_rounded;
      case 'copy':
        return Icons.content_copy_rounded;
      case 'paste':
        return Icons.content_paste_rounded;
      case 'link':
        return Icons.link_rounded;
      case 'key':
        return Icons.vpn_key_outlined;
      case 'restore':
        return Icons.settings_backup_restore_rounded;
      case 'shield':
        return Icons.verified_user_outlined;
      case 'refresh':
        return Icons.sync_rounded;
      case 'palette':
        return Icons.palette_outlined;
      // Notes. The filled sheet is the "this workout has one" state — the same
      // outline/fill pair the nav tabs use to mean current.
      case 'note':
        return filled
            ? Icons.sticky_note_2_rounded
            : Icons.sticky_note_2_outlined;
      case 'back':
        return Icons.arrow_back_rounded;
      case 'undo':
        return Icons.undo_rounded;
      case 'redo':
        return Icons.redo_rounded;
      // The note editor's formatting bar. `textUp`/`textDown` are the A⁺/A⁻
      // pair; the highlighter has no Material glyph and is drawn by hand in
      // notes/note_glyphs.dart.
      case 'checkbox':
        return filled ? Icons.check_box_rounded : Icons.check_box_outlined;
      case 'bold':
        return Icons.format_bold_rounded;
      case 'italic':
        return Icons.format_italic_rounded;
      case 'underline':
        return Icons.format_underlined_rounded;
      case 'textUp':
        return Icons.text_increase_rounded;
      case 'textDown':
        return Icons.text_decrease_rounded;
      default:
        return Icons.circle_outlined;
    }
  }
}

/// A themed icon — keeps call sites declarative (`ArcIcon('plus', size: 18)`).
class ArcIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;
  final bool filled;

  const ArcIcon(this.name, {super.key, this.size = 24, this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    if (name == 'calendar') {
      return ArcCalendarGlyph(
        size: size,
        filled: filled,
        color: color ?? IconTheme.of(context).color ?? const Color(0xFF000000),
      );
    }
    return Icon(
      ArcIcons.byName(name, filled: filled),
      size: size,
      color: color ?? IconTheme.of(context).color,
    );
  }
}

/// The calendar, drawn rather than picked — the only glyph in the set that is.
///
/// Every other tab in the bottom nav marks "current" by filling: Home swaps an
/// outlined house for a solid one, Records an outlined cup for a solid one, and
/// the dumbbell is solid to begin with. The Material font has no solid calendar
/// to swap to, so History could only ever have traded one outline for a
/// differently-shaped outline — a glyph change where the rest of the row does a
/// fill change.
///
/// Both states are drawn here on one 24-unit grid, off one set of constants, so
/// the tap is a pure inversion: same frame, same tabs, same 3×2 grid, ink and
/// negative space trading places. Nothing moves, so nothing can drift.
class ArcCalendarGlyph extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;

  const ArcCalendarGlyph({
    super.key,
    required this.size,
    required this.color,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _CalendarPainter(color: color, filled: filled),
        ),
      );
}

class _CalendarPainter extends CustomPainter {
  final Color color;
  final bool filled;

  _CalendarPainter({required this.color, required this.filled});

  // The 24-unit authoring grid the Material glyphs beside this one use. Both
  // states read from these, which is what keeps the two halves of the pair the
  // same shape.
  static const double _left = 3.2;
  static const double _right = 20.8;
  static const double _top = 4.4;
  static const double _bottom = 21.4;
  static const double _radius = 2.6;
  static const double _stroke = 1.9;

  /// The rule under the month header — a drawn line when outlined, a gap cut
  /// through the body when filled.
  static const double _rule = 9.3;
  static const double _ruleGap = 1.5;

  // The two binder tabs, sat over the outer dot columns rather than eyeballed.
  static const double _tabWidth = 2.0;
  static const double _tabTop = 2.3;
  static const double _tabBottom = 5.6;

  static const List<double> _dotX = [7.6, 12.0, 16.4];
  static const List<double> _dotY = [13.6, 17.7];
  static const double _dotR = 1.15;
  static const List<double> _tabX = [7.6, 16.4]; // == the outer _dotX columns

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24;
    final ink = Paint()
      ..color = color
      ..isAntiAlias = true;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(_left * u, _top * u, _right * u, _bottom * u),
      Radius.circular(_radius * u),
    );
    final tabs = Path();
    for (final x in _tabX) {
      tabs.addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(
          (x - _tabWidth / 2) * u,
          _tabTop * u,
          (x + _tabWidth / 2) * u,
          _tabBottom * u,
        ),
        Radius.circular(_tabWidth / 2 * u),
      ));
    }

    if (!filled) {
      canvas.drawPath(tabs, ink);
      canvas.drawRRect(
        body,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke * u
          ..isAntiAlias = true,
      );
      canvas.drawLine(
        Offset(_left * u, _rule * u),
        Offset(_right * u, _rule * u),
        Paint()
          ..color = color
          ..strokeWidth = _stroke * u
          ..isAntiAlias = true,
      );
      for (final y in _dotY) {
        for (final x in _dotX) {
          canvas.drawCircle(Offset(x * u, y * u), _dotR * u, ink);
        }
      }
      return;
    }

    // Solid body and tabs as one silhouette, then the header rule and the grid
    // punched back out of it. Cut as path geometry rather than painted over in
    // the background colour: the nav is translucent over a blur, so a "cover it
    // with nav-bg" fake would show as two flat patches against the frost.
    final solid = Path.combine(
      PathOperation.union,
      Path()..addRRect(body),
      tabs,
    );
    // Overshoot the sides so the cut clears the body edge outright — landing a
    // knockout exactly on the boundary leaves an antialiased hairline bridge.
    final holes = Path()
      ..addRect(Rect.fromLTRB(
        (_left - 1) * u,
        (_rule - _ruleGap / 2) * u,
        (_right + 1) * u,
        (_rule + _ruleGap / 2) * u,
      ));
    for (final y in _dotY) {
      for (final x in _dotX) {
        holes.addOval(Rect.fromCircle(
          center: Offset(x * u, y * u),
          radius: _dotR * u,
        ));
      }
    }
    canvas.drawPath(Path.combine(PathOperation.difference, solid, holes), ink);
  }

  @override
  bool shouldRepaint(_CalendarPainter old) =>
      old.color != color || old.filled != filled;
}
