import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'timer_screen.dart';

/// The tag that ties the count on the full screen to the count in the bar.
///
/// One flight, one element: the number. Everything else on the timer screen
/// fades, and the number travels — which is what makes leaving the screen read
/// as the timer minimising rather than as a screen closing and a bar appearing.
const String kTimerCountHero = 'arc.timer.count';

/// The route the full timer is pushed on.
///
/// Not opaque: the shell keeps painting underneath, so the last third of the
/// exit shows the app already back and the count still on its way into the bar.
/// An opaque route would cut to the shell at the end of the flight instead, and
/// the illusion is the whole point.
class TimerRoute extends PageRouteBuilder<void> {
  TimerRoute()
      : super(
          opaque: false,
          barrierColor: null,
          barrierDismissible: false,
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, _, _) => const TimerScreen(),
          transitionsBuilder: _transition,
        );

  static Widget _transition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondary,
    Widget child,
  ) {
    // "Remove animations" is honoured by cutting, not by shortening: a 380ms
    // flight at 1x speed is still a flight.
    if (MediaQuery.disableAnimationsOf(context)) return child;

    final t = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutQuart,
      reverseCurve: Curves.easeInQuart,
    );

    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) {
        final v = t.value;
        return Stack(
          children: [
            // The ground the screen sits on, fading in ahead of the content and
            // out behind it, so the shell is never visible through half-opaque
            // text.
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: AppColors.bg.withValues(
                      alpha: Curves.easeOut.transform(v.clamp(0.0, 1.0))),
                ),
              ),
            ),
            // The chrome — everything except the flying count — arrives after
            // the ground and leaves before it.
            Opacity(
              opacity: (v * 1.45 - 0.45).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - v) * 26),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}
