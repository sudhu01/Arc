import 'dart:async';
import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/arc_data.dart';
import '../theme/app_theme.dart';
import 'arc_icons.dart';

/// Round icon button that copies text and morphs its glyph into a tick to
/// confirm it landed — sized to sit beside the sheet's close button.
class CopyIconButton extends StatefulWidget {
  /// Resolved on tap, so what's copied reflects the state at that moment.
  final String Function() text;
  final double size;
  final String semanticLabel;

  const CopyIconButton({
    super.key,
    required this.text,
    this.size = 34,
    this.semanticLabel = 'Copy',
  });

  @override
  State<CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<CopyIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 260),
  );
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    _c.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text()));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    _c.forward(from: 0);
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 1700), () {
      if (mounted) _c.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    final glyph = widget.size * 0.53;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // the clipboard glyph clears out before the tick draws in, so the
            // two never read as one muddled shape mid-swap
            final out = Curves.easeIn.transform((t / 0.4).clamp(0.0, 1.0));
            final tick = Curves.easeOutBack
                .transform(((t - 0.28) / 0.72).clamp(0.0, 1.0));
            // one soft pop of the whole button as the glyphs trade places
            final pop = 1 + 0.12 * sin(pi * Curves.easeOut.transform(t));

            return Transform.scale(
              scale: pop,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: Color.lerp(AppColors.surface2, AppColors.accentSoft, t),
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: 1 - out,
                      child: Transform.scale(
                        scale: 1 - 0.35 * out,
                        child: ArcIcon('copy',
                            size: glyph, color: AppColors.muted),
                      ),
                    ),
                    Opacity(
                      // easeOutBack overshoots past 1; opacity can't
                      opacity: tick.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: tick,
                        child: Transform.rotate(
                          angle: -0.5 * (1 - tick),
                          child: ArcIcon('check',
                              size: glyph + 2, color: AppColors.accentStrong),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps a child with a tactile press-to-scale animation (Surge feel).
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Optional shortcut gesture. Never the only route to an action — the
  /// long-press on the Appearance button duplicates the toggle inside it.
  final VoidCallback? onLongPress;
  final double scale;
  final BorderRadius? borderRadius;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
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
    final pressable = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              setState(() => _down = false);
              widget.onLongPress!();
            },
      onTapDown: !pressable ? null : (_) => setState(() => _down = true),
      onTapUp: !pressable ? null : (_) => setState(() => _down = false),
      onTapCancel: !pressable ? null : () => setState(() => _down = false),
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
          // Flexible so a long label (or a large system text scale) ellipsizes
          // instead of overflowing the button.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui(
                size: fs,
                weight: FontWeight.w600,
                color: fg,
                letterSpacing: -0.1,
              ),
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

/// Arc-styled confirm dialog. Resolves to `true` only if the user confirms.
Future<bool> showArcConfirm({
  required BuildContext context,
  required String title,
  String? message,
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
  bool danger = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.rLg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: AppText.ui(size: 18, weight: FontWeight.w700)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message,
                  style: AppText.ui(
                      size: 13.5, height: 1.4, color: AppColors.muted)),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ArcButton(
                    label: cancelLabel,
                    variant: BtnVariant.quiet,
                    full: true,
                    onTap: () => Navigator.of(ctx).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ArcButton(
                    label: confirmLabel,
                    variant: danger ? BtnVariant.danger : BtnVariant.primary,
                    full: true,
                    onTap: () => Navigator.of(ctx).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return ok ?? false;
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
      decoration: BoxDecoration(
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
                  style: AppText.ui(
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

/// Number field with -/+ buttons. When [editable] is true, double-tapping the
/// value lets the user type it in directly (numeric only, up to [decimals]
/// decimal places).
class ArcStepper extends StatefulWidget {
  final num value;
  final ValueChanged<num> onChanged;
  final num step;
  final num min;
  final num max;
  final String? suffix;
  final bool editable;
  final int decimals;

  const ArcStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.step = 5,
    this.min = 0,
    this.max = 9999,
    this.suffix,
    this.editable = false,
    this.decimals = 0,
  });

  @override
  State<ArcStepper> createState() => _ArcStepperState();
}

class _ArcStepperState extends State<ArcStepper> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(num v) => widget.onChanged(v.clamp(widget.min, widget.max));

  String get _display => widget.value % 1 == 0
      ? widget.value.toInt().toString()
      : widget.value.toString();

  void _startEditing() {
    _controller.text = _display;
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _commit() {
    if (!_editing) return;
    var text = _controller.text.trim();
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    final parsed = num.tryParse(text);
    if (parsed != null) _set(parsed);
    setState(() => _editing = false);
  }

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

    Widget center;
    if (_editing) {
      center = TextField(
        controller: _controller,
        focusNode: _focus,
        textAlign: TextAlign.center,
        keyboardType:
            TextInputType.numberWithOptions(decimal: widget.decimals > 0),
        inputFormatters: [_DecimalInputFormatter(widget.decimals)],
        cursorColor: AppColors.accentStrong,
        onSubmitted: (_) => _commit(),
        // On mobile, tapping outside a TextField does not drop focus by
        // default, so without this the edit is never committed when the user
        // taps "Save" — the set reverts to its pre-edit value.
        onTapOutside: (_) => _focus.unfocus(),
        style: AppText.mono(size: 19, weight: FontWeight.w600),
        decoration: const InputDecoration(
          isCollapsed: true,
          contentPadding: EdgeInsets.symmetric(vertical: 14),
          border: InputBorder.none,
        ),
      );
    } else {
      center = FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(_display,
                style: AppText.mono(size: 19, weight: FontWeight.w600)),
            if (widget.suffix != null)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(widget.suffix!,
                    style: AppText.ui(size: 12, color: AppColors.muted)),
              ),
          ],
        ),
      );
      if (widget.editable) {
        center = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _startEditing,
          child: center,
        );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          btn('minus', () => _set(widget.value - widget.step)),
          Expanded(child: center),
          btn('plus', () => _set(widget.value + widget.step)),
        ],
      ),
    );
  }
}

/// Allows only numeric input with at most [decimals] digits after a single
/// decimal point (e.g. "62.5"). When [decimals] is 0, only whole numbers pass.
class _DecimalInputFormatter extends TextInputFormatter {
  final int decimals;
  const _DecimalInputFormatter(this.decimals);

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    final pattern = decimals > 0 ? '^\\d*\\.?\\d{0,$decimals}\$' : r'^\d*$';
    return RegExp(pattern).hasMatch(text) ? newValue : oldValue;
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

/// Calendar-style date chip for workout rows: month, day, weekday stacked
/// (e.g. AUG / 5 / TUE).
class DateChip extends StatelessWidget {
  final DateTime date;
  const DateChip({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final label = AppText.ui(
        size: 8.5,
        weight: FontWeight.w700,
        height: 1.1,
        letterSpacing: 0.4);
    return Container(
      width: 50,
      height: 52,
      decoration: BoxDecoration(
          color: AppColors.surface2, borderRadius: BorderRadius.circular(14)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(ArcData.monthsShort[date.month - 1].toUpperCase(),
              style: label.copyWith(color: AppColors.faint)),
          const SizedBox(height: 2),
          Text('${date.day}',
              style: AppText.mono(size: 16.5, weight: FontWeight.w700, height: 1)),
          const SizedBox(height: 2),
          Text(ArcData.weekdayShort[ArcData.jsWeekday(date)].toUpperCase(),
              style: label.copyWith(color: AppColors.muted)),
        ],
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
        style: AppText.ui(
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
        decoration: BoxDecoration(
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
                      style: AppText.ui(size: 11, weight: FontWeight.w600, color: AppColors.muted)),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(label,
                style: AppText.ui(
                    size: 11.5, weight: FontWeight.w600, color: AppColors.muted)),
            if (sub != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(sub!,
                    style: AppText.ui(size: 11, color: AppColors.faint)),
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
                style: AppText.ui(
                    size: 19, weight: FontWeight.w700, letterSpacing: -0.38)),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!,
                  style: AppText.ui(
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
