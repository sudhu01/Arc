import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'arc_icons.dart';

/// Wraps a child with a tactile press-to-scale animation (Surge feel).
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final BorderRadius? borderRadius;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.borderRadius,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapUp: widget.onTap == null ? null : (_) => setState(() => _down = false),
      onTapCancel: widget.onTap == null ? null : () => setState(() => _down = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Surface card with line border + soft lift.
class ArcCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  const ArcCard({super.key, required this.child, this.padding, this.onTap});

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.rLg,
        border: Border.all(color: AppColors.cardLine),
        boxShadow: AppShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    if (onTap == null) return card;
    return PressScale(onTap: onTap, scale: 0.985, child: card);
  }
}

enum BtnVariant { primary, soft, ghost, quiet, danger }

enum BtnSize { sm, md, lg }

class ArcButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final BtnVariant variant;
  final BtnSize size;
  final bool full;
  final bool disabled;
  final String? icon;

  const ArcButton({
    super.key,
    required this.label,
    this.onTap,
    this.variant = BtnVariant.primary,
    this.size = BtnSize.md,
    this.full = false,
    this.disabled = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final pad = switch (size) {
      BtnSize.lg => const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      BtnSize.sm => const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      BtnSize.md => const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    };
    final fs = switch (size) {
      BtnSize.lg => 17.0,
      BtnSize.sm => 14.0,
      BtnSize.md => 15.5,
    };

    late Color bg;
    late Color fg;
    Border? border;
    List<BoxShadow>? shadow;
    switch (variant) {
      case BtnVariant.primary:
        bg = AppColors.accent;
        fg = AppColors.accentInk;
        shadow = AppShadows.accent;
        break;
      case BtnVariant.soft:
        bg = AppColors.accentSoft;
        fg = AppColors.accentStrong;
        break;
      case BtnVariant.ghost:
        bg = Colors.transparent;
        fg = AppColors.ink;
        border = Border.all(color: AppColors.line);
        break;
      case BtnVariant.quiet:
        bg = AppColors.surface2;
        fg = AppColors.ink;
        break;
      case BtnVariant.danger:
        bg = AppColors.dangerSoft;
        fg = AppColors.danger;
        break;
    }

    final content = Container(
      width: full ? double.infinity : null,
      padding: pad,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadii.rMd,
        border: border,
        boxShadow: disabled ? null : shadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            ArcIcon(icon!, size: size == BtnSize.lg ? 20 : 18, color: fg),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: AppText.sora(
              size: fs,
              weight: FontWeight.w600,
              color: fg,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );

    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: PressScale(
        onTap: disabled ? null : onTap,
        scale: 0.97,
        child: content,
      ),
    );
  }
}

class SegOption {
  final String value;
  final String label;
  const SegOption(this.value, this.label);
}

/// Segmented control — pill background, raised active segment.
class Segmented extends StatelessWidget {
  final List<SegOption> options;
  final String value;
  final ValueChanged<String> onChanged;

  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  factory Segmented.simple({
    Key? key,
    required List<String> options,
    required String value,
    required ValueChanged<String> onChanged,
  }) =>
      Segmented(
        key: key,
        options: options.map((o) => SegOption(o, o)).toList(),
        value: value,
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      child: Row(
        children: options.map((o) {
          final active = o.value == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(o.value),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                decoration: BoxDecoration(
                  color: active ? AppColors.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.md - 4),
                  boxShadow: active ? AppShadows.sm : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  o.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.sora(
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: active ? AppColors.ink : AppColors.muted,
                    letterSpacing: -0.07,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Number field with -/+ buttons.
class ArcStepper extends StatelessWidget {
  final num value;
  final ValueChanged<num> onChanged;
  final num step;
  final num min;
  final num max;
  final String? suffix;

  const ArcStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.step = 5,
    this.min = 0,
    this.max = 9999,
    this.suffix,
  });

  void _set(num v) => onChanged(v.clamp(min, max));

  @override
  Widget build(BuildContext context) {
    Widget btn(String icon, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 38,
            height: 46,
            child: Icon(ArcIcons.byName(icon), size: 18, color: AppColors.ink),
          ),
        );

    final display = value % 1 == 0 ? value.toInt().toString() : value.toString();

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          btn('minus', () => _set(value - step)),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(display,
                      style: AppText.mono(size: 19, weight: FontWeight.w600)),
                  if (suffix != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: Text(suffix!,
                          style: AppText.sora(size: 12, color: AppColors.muted)),
                    ),
                ],
              ),
            ),
          ),
          btn('plus', () => _set(value + step)),
        ],
      ),
    );
  }
}

/// Group color dot.
class GroupDot extends StatelessWidget {
  final String group;
  final double size;
  const GroupDot(this.group, {super.key, this.size = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.group(group),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Uppercase pill tag (e.g. "NEW", "Personal Record").
class Tag extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? background;
  const Tag(this.label, {super.key, this.color, this.background});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? AppColors.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppText.sora(
          size: 11.5,
          weight: FontWeight.w700,
          color: color ?? AppColors.accentStrong,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Compact metric tile used in stat rows.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final String? unit;
  const StatTile({super.key, required this.label, required this.value, this.sub, this.unit});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: const BoxDecoration(
          color: AppColors.surface2,
          borderRadius: AppRadii.rMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: AppText.mono(size: 22, weight: FontWeight.w600, height: 1.1)),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(unit!,
                      style: AppText.sora(size: 11, weight: FontWeight.w600, color: AppColors.muted)),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(label,
                style: AppText.sora(
                    size: 11.5, weight: FontWeight.w600, color: AppColors.muted)),
            if (sub != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(sub!,
                    style: AppText.sora(size: 11, color: AppColors.faint)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Section header with optional trailing action.
class SectionHead extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHead({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(title,
                style: AppText.sora(
                    size: 19, weight: FontWeight.w700, letterSpacing: -0.38)),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!,
                  style: AppText.sora(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: AppColors.accentStrong)),
            ),
        ],
      ),
    );
  }
}

const titleStyleSize = 32.0;
