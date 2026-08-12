import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import 'timer_controller.dart';
import 'timer_route.dart';
import 'timer_settings.dart';

/// The rest bar: the running timer, docked under the status bar and present on
/// every screen in Arc.
///
/// It is the count and two controls, and nothing else. Everything that could be
/// on it and isn't — a label for the exercise, a set counter, a progress ring —
/// would be competing with the one number the user is actually reading, from
/// arm's length, with a barbell in the other hand.
class TimerBar extends StatelessWidget {
  const TimerBar({super.key, this.onOpen});

  /// Height the bar occupies when shown, so the shell can inset behind it.
  static const double height = 58;

  /// Opens the full timer. Supplied by the shell, which owns the navigator the
  /// minimise animation flies back into.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final instant = MediaQuery.disableAnimationsOf(context);

    return AnimatedSlide(
      offset: Offset(0, timer.isActive ? 0 : -1.6),
      duration: Duration(milliseconds: instant ? 0 : 320),
      curve: Curves.easeOutQuart,
      child: AnimatedOpacity(
        opacity: timer.isActive ? 1 : 0,
        duration: Duration(milliseconds: instant ? 0 : 180),
        child: IgnorePointer(
          ignoring: !timer.isActive,
          child: _BarBody(onOpen: onOpen),
        ),
      ),
    );
  }
}

class _BarBody extends StatelessWidget {
  const _BarBody({this.onOpen});

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final over = timer.isFinished;
    final paused = timer.isPaused;
    final urgent = over || timer.isFinalStretch;

    final label = over ? 'REST OVER' : (paused ? 'PAUSED' : 'REST');
    final count = formatRest(timer.remaining);

    return Semantics(
      container: true,
      button: true,
      label: over
          ? 'Rest over'
          : '${paused ? 'Rest paused' : 'Rest'}, '
              '${spokenRest(timer.remaining)} left',
      hint: 'Opens the timer',
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: Container(
            height: TimerBar.height,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rLg,
              border: Border.all(color: AppColors.cardLine),
              boxShadow: AppShadows.card,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              // Centred, not the Stack's top-left default: the row is 44 tall
              // inside a 58 bar, and left to itself it sits seven pixels high
              // with the slack pooling under it.
              alignment: Alignment.center,
              children: [
                Row(
                  children: [
                    // Clear of the corner radius. The label is the first thing
                    // in the bar now — the accent belongs to the rail, which
                    // is already saying the same thing with real information.
                    const SizedBox(width: 18),
                    Text(
                      label,
                      style: AppText.ui(
                        size: 11.5,
                        weight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.muted,
                      ),
                    ),
                    const Spacer(),
                    TimerCount(
                      value: count,
                      size: 26,
                      color: urgent ? AppColors.accentStrong : AppColors.ink,
                      // Only the visible bar carries the hero. Without this the
                      // count would fly into a bar that is sliding away, which
                      // is a flight to nowhere.
                      hero: timer.isActive,
                    ),
                    const SizedBox(width: 10),
                    if (over)
                      _BarButton(
                        icon: 'check',
                        label: 'Dismiss the finished rest',
                        tint: AppColors.accentStrong,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          timer.reset();
                        },
                      )
                    else
                      _BarButton(
                        icon: paused ? 'play' : 'pause',
                        label: paused ? 'Resume rest' : 'Pause rest',
                        onTap: () {
                          HapticFeedback.selectionClick();
                          timer.toggle();
                        },
                      ),
                    _BarButton(
                      icon: 'reset',
                      label: 'Reset rest',
                      tint: AppColors.muted,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        timer.reset();
                      },
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DrainRail(
                    progress: timer.progress,
                    thick: urgent,
                    dimmed: paused,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The count, at whatever size the surface it is on calls for.
///
/// Shared by the bar and the full screen so the flight between them is one
/// widget changing size rather than two widgets pretending. A [FittedBox] on
/// both ends is what keeps that flight smooth: the hero tweens a rectangle, and
/// the glyphs scale continuously inside it instead of reflowing at each frame.
class TimerCount extends StatelessWidget {
  const TimerCount({
    super.key,
    required this.value,
    required this.size,
    required this.color,
    this.hero = true,
  });

  final String value;
  final double size;
  final Color color;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final text = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        value,
        maxLines: 1,
        softWrap: false,
        style: AppText.mono(
          size: size,
          weight: FontWeight.w600,
          height: 1,
          color: color,
        ),
      ),
    );

    if (!hero) return text;
    return Hero(
      tag: kTimerCountHero,
      // The shuttle is transparent-backed on purpose — a Material default
      // would paint a white slab under the number for the length of the
      // flight.
      flightShuttleBuilder: (_, _, _, _, toHero) => Material(
        type: MaterialType.transparency,
        child: toHero.widget,
      ),
      child: text,
    );
  }
}

/// The rail that empties as the rest runs down.
///
/// A bar, not a ring. The rest is a span with a start and an end, and a span is
/// read against a line — the same reason Arc's progress lives on a real axis
/// rather than in a dial.
class DrainRail extends StatelessWidget {
  const DrainRail({
    super.key,
    required this.progress,
    this.thick = false,
    this.dimmed = false,
  });

  final double progress;
  final bool thick;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: Duration(milliseconds: instant ? 0 : 200),
      curve: Curves.easeOut,
      height: thick ? 3 : 2,
      color: AppColors.bar,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: (1 - progress).clamp(0.0, 1.0),
        child: ColoredBox(
          color: dimmed ? AppColors.muted : AppColors.accent,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          // 44 square, per PRODUCT's touch-target floor. The glyph inside is
          // 21; the rest is slop for a sweaty thumb.
          width: 44,
          height: 44,
          child: Icon(
            ArcIcons.byName(icon),
            size: 21,
            color: tint ?? AppColors.ink,
          ),
        ),
      ),
    );
  }
}

/// Opens the full timer from anywhere, with the transition that flies back into
/// the bar on the way out.
Future<void> openTimer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(TimerRoute());
