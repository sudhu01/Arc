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
      case 'calendar':
        return filled ? Icons.calendar_month_rounded : Icons.calendar_today_outlined;
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
      case 'clock':
        return Icons.schedule_rounded;
      case 'target':
        return Icons.gps_fixed_rounded;
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
      case 'share':
        return Icons.ios_share_rounded;
      case 'copy':
        return Icons.content_copy_rounded;
      case 'key':
        return Icons.vpn_key_outlined;
      case 'shield':
        return Icons.verified_user_outlined;
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
    return Icon(
      ArcIcons.byName(name, filled: filled),
      size: size,
      color: color ?? IconTheme.of(context).color,
    );
  }
}
