import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';
import 'timer_bar.dart';
import 'timer_controller.dart';
import 'timer_settings.dart';

/// The rest timer, whole.
///
/// One screen holding the count, the transport, and every setting that governs
/// them — because a timer's settings are not a preferences pane, they are how
/// the timer is dialled in between sets. Changes commit live and persist on
/// their own; there is no Save, the same way Appearance has none.
class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const _Header(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 40),
                children: [
                  const _Face(),
                  const SizedBox(height: 26),
                  const _Transport(),
                  const SizedBox(height: 34),
                  _Label('Duration'),
                  const _DurationControl(),
                  const SizedBox(height: 34),
                  _Label('Behaviour'),
                  const _Behaviour(),
                  const SizedBox(height: 34),
                  _Label('Alarm'),
                  const _SoundSection(),
                  // Ordered by severity. A missing notification grant means the
                  // background alarm does not sound at all; a missing
                  // exact-alarm grant means it sounds late.
                  if (!timer.notificationsAllowed) ...[
                    const SizedBox(height: 20),
                    const _NotificationNotice(),
                  ],
                  if (!timer.exactAlarms) ...[
                    const SizedBox(height: 20),
                    const _ExactAlarmNotice(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The uppercase micro-label Arc files settings under, matching the Appearance
/// sheet so a section reads the same wherever it appears.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: AppText.ui(
            size: 11.5,
            weight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.5,
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Rest timer',
              style: AppText.ui(
                  size: 21, weight: FontWeight.w700, letterSpacing: -0.21),
            ),
          ),
          Semantics(
            button: true,
            label: 'Close the timer',
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(ArcIcons.byName('x'),
                        size: 18, color: AppColors.muted),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The count and the gauge under it — the instrument itself.
class _Face extends StatelessWidget {
  const _Face();

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final urgent = timer.isFinished || timer.isFinalStretch;
    final state = timer.isFinished
        ? 'Rest over'
        : timer.isPaused
            ? 'Paused'
            : timer.isRunning
                ? 'Resting'
                : 'Ready';

    return Semantics(
      liveRegion: timer.isRunning,
      label: timer.isFinished
          ? 'Rest over'
          : '$state, ${spokenRest(timer.remaining)}',
      child: ExcludeSemantics(
        child: Column(
          children: [
            const SizedBox(height: 18),
            Text(
              state.toUpperCase(),
              style: AppText.ui(
                size: 11.5,
                weight: FontWeight.w700,
                letterSpacing: 0.5,
                color: urgent ? AppColors.accentStrong : AppColors.muted,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              // Fixed box so the gauge below never shifts as the digit count
              // changes, and so 200% system text scales the numerals down
              // rather than pushing the transport off the screen.
              height: 104,
              child: TimerCount(
                value: formatRest(timer.remaining),
                size: 96,
                color: urgent ? AppColors.accentStrong : AppColors.ink,
              ),
            ),
            const SizedBox(height: 22),
            _Gauge(
              progress: timer.progress,
              total: timer.settings.duration,
              dimmed: timer.isPaused,
            ),
          ],
        ),
      ),
    );
  }
}

/// A graduated rail: the rest as a span, with the units printed on it.
///
/// Not a ring. A rest has a start, an end and a direction, and Arc reads
/// progress off a real axis rather than a dial — the same argument that keeps
/// the strength curve on a chart instead of in a dashboard donut.
class _Gauge extends StatelessWidget {
  const _Gauge({
    required this.progress,
    required this.total,
    required this.dimmed,
  });

  final double progress;
  final Duration total;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: CustomPaint(
        painter: _GaugePainter(
          progress: progress,
          total: total,
          track: AppColors.bar,
          fill: dimmed ? AppColors.muted : AppColors.accent,
          tick: AppColors.line,
          labelStyle: AppText.mono(
              size: 10, weight: FontWeight.w600, color: AppColors.faint),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.progress,
    required this.total,
    required this.track,
    required this.fill,
    required this.tick,
    required this.labelStyle,
  });

  final double progress;
  final Duration total;
  final Color track;
  final Color fill;
  final Color tick;
  final TextStyle labelStyle;

  static const double _railH = 6;
  static const double _tickTop = _railH + 5;

  @override
  void paint(Canvas canvas, Size size) {
    final rail = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, _railH),
      const Radius.circular(3),
    );
    canvas.drawRRect(rail, Paint()..color = track);

    // Remaining, anchored left: the gauge empties toward the start, so "how
    // much bar is left" is literally how much rest is left.
    final left = (1 - progress).clamp(0.0, 1.0);
    if (left > 0) {
      canvas.save();
      canvas.clipRRect(rail);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width * left, _railH),
        Paint()..color = fill,
      );
      canvas.restore();
    }

    // Graduations every thirty seconds, taller on the minute. Below about two
    // and a half minutes the thirty-second marks are readable; past that they
    // crowd, so only the minutes are drawn.
    final seconds = total.inSeconds;
    if (seconds <= 0) return;
    final everyMinuteOnly = seconds > 300;
    final stepSeconds = everyMinuteOnly ? 60 : 30;
    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 1;

    for (var s = stepSeconds; s < seconds; s += stepSeconds) {
      final x = size.width * (s / seconds);
      final onMinute = s % 60 == 0;
      canvas.drawLine(
        Offset(x, _tickTop),
        Offset(x, _tickTop + (onMinute ? 7 : 4)),
        tickPaint,
      );
      if (onMinute) {
        _text(canvas, formatRest(Duration(seconds: s)), x, centred: true,
            width: size.width);
      }
    }

    // The ends, labelled and pinned inside the rail's own width rather than
    // centred on it, so neither runs off the screen.
    _text(canvas, '0:00', 0, align: TextAlign.left, width: size.width);
    _text(canvas, formatRest(total), size.width,
        align: TextAlign.right, width: size.width);
  }

  void _text(
    Canvas canvas,
    String value,
    double x, {
    bool centred = false,
    TextAlign align = TextAlign.center,
    required double width,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.left => 0.0,
      TextAlign.right => width - painter.width,
      _ => (x - painter.width / 2).clamp(0.0, width - painter.width),
    };
    painter.paint(canvas, Offset(centred || align == TextAlign.center ? dx : dx,
        _tickTop + 10));
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress ||
      old.total != total ||
      old.fill != fill ||
      old.track != track;
}

/// Start / pause, and reset. The two controls that matter, sized so neither has
/// to be aimed at.
///
/// Glyphs only. A play triangle and a replay arrow directly under a running
/// count need no caption, and the words were the only thing on this screen
/// competing with the numerals. The labels live on as the spoken names.
class _Transport extends StatelessWidget {
  const _Transport();

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final primary = switch (timer.phase) {
      TimerPhase.running => (label: 'Pause', icon: 'pause'),
      TimerPhase.paused => (label: 'Resume', icon: 'play'),
      TimerPhase.finished => (label: 'Start again', icon: 'play'),
      TimerPhase.idle => (label: 'Start rest', icon: 'play'),
    };

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: ArcButton(
            label: primary.label,
            icon: primary.icon,
            iconOnly: true,
            size: BtnSize.lg,
            full: true,
            onTap: () {
              HapticFeedback.selectionClick();
              timer.toggle();
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ArcButton(
            label: 'Reset',
            icon: 'reset',
            iconOnly: true,
            size: BtnSize.lg,
            variant: BtnVariant.quiet,
            full: true,
            disabled: timer.isIdle,
            onTap: timer.isIdle
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    timer.reset();
                  },
          ),
        ),
      ],
    );
  }
}

/// How long a rest is: the exact value, and the four everyone actually uses.
///
/// While a rest is running the ± moves the *deadline* rather than the setting —
/// the set that turned out heavier needs another thirty seconds now, not next
/// time.
class _DurationControl extends StatelessWidget {
  const _DurationControl();

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final live = timer.isRunning || timer.isPaused;
    final shown = live ? timer.remaining : timer.settings.duration;

    void move(int sign) {
      HapticFeedback.selectionClick();
      final by = TimerSettings.step * sign;
      if (live) {
        timer.nudge(by);
      } else {
        timer.setDuration(TimerSettings.snap(timer.settings.duration + by));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: live ? 'Time remaining' : 'Rest length',
          value: spokenRest(shown),
          child: ExcludeSemantics(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: AppRadii.rMd,
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  _StepButton(
                    icon: 'minus',
                    label: 'Fifteen seconds less',
                    onTap: () => move(-1),
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        formatRest(shown),
                        style: AppText.mono(size: 19, weight: FontWeight.w600),
                      ),
                    ),
                  ),
                  _StepButton(
                    icon: 'plus',
                    label: 'Fifteen seconds more',
                    onTap: () => move(1),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Segmented(
          options: [
            for (final d in TimerSettings.presets)
              SegOption('${d.inSeconds}', formatRest(d)),
          ],
          value: '${timer.settings.duration.inSeconds}',
          onChanged: (v) {
            HapticFeedback.selectionClick();
            final seconds = int.tryParse(v);
            if (seconds == null) return;
            timer.setDuration(Duration(seconds: seconds));
          },
        ),
        if (live) ...[
          const SizedBox(height: 8),
          Text(
            'Adjusts this rest. The next one is '
            '${formatRest(timer.settings.duration)}.',
            style: AppText.ui(
                size: 12.5, height: 1.35, color: AppColors.muted),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(ArcIcons.byName(icon), size: 18, color: AppColors.ink),
        ),
      ),
    );
  }
}

class _Behaviour extends StatelessWidget {
  const _Behaviour();

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();

    return Column(
      children: [
        ArcSwitchRow(
          label: 'Start on every set',
          sub: 'The rest runs the moment you add a set to a workout.',
          value: timer.settings.autoStart,
          onChanged: timer.setAutoStart,
        ),
        const _Rule(),
        ArcSwitchRow(
          label: 'Vibrate only',
          sub: 'No sound at the end. The phone still buzzes.',
          value: timer.settings.silent,
          onChanged: timer.setSilent,
        ),
        const _Rule(),
        const _FloatingRow(),
      ],
    );
  }
}

/// The one setting that can refuse: the floating bar needs a grant the user
/// gives outside Arc, so the switch reports what actually happened rather than
/// sitting on while nothing floats.
class _FloatingRow extends StatelessWidget {
  const _FloatingRow();

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();

    return ArcSwitchRow(
      label: 'Float over other apps',
      sub: 'Keeps the countdown on screen after you leave Arc. '
          'Android asks for permission the first time.',
      value: timer.settings.floating,
      onChanged: (value) async {
        final granted = await timer.setFloating(value);
        if (!granted && context.mounted) {
          context
              .read<ArcStore>()
              .announce('Permission needed to float over other apps', 'x');
        }
      },
    );
  }
}

/// The alarm sound: what it is, what it sounds like, and how to change it.
class _SoundSection extends StatefulWidget {
  const _SoundSection();

  @override
  State<_SoundSection> createState() => _SoundSectionState();
}

class _SoundSectionState extends State<_SoundSection> {
  bool _choosing = false;

  Future<void> _choose() async {
    final timer = context.read<TimerController>();
    final store = context.read<ArcStore>();
    setState(() => _choosing = true);
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Audio',
          mimeTypes: ['audio/*'],
          extensions: ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'],
        ),
      ]);
      if (file == null) return;
      final ok = await timer.setSound(file.path, file.name);
      store.announce(
        ok ? 'Alarm set to ${file.name}' : 'That file could not be used',
        ok ? 'check' : 'x',
      );
    } catch (e) {
      store.announce('That file could not be used', 'x');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<TimerController>();
    final settings = timer.settings;
    final silent = settings.silent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          // Dimmed rather than hidden while silent: the sound is still
          // configured, it simply is not being used, and hiding it would make
          // the setting look lost.
          opacity: silent ? 0.45 : 1,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: AppRadii.rMd,
            ),
            child: Row(
              children: [
                Icon(ArcIcons.byName(silent ? 'vibrate' : 'sound'),
                    size: 18, color: AppColors.muted),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        settings.soundLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(size: 15, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        silent
                            ? 'Muted while Vibrate only is on'
                            : settings.usesCustomSound
                                ? 'Your file'
                                : 'Three beeps, built in',
                        style: AppText.ui(
                            size: 12.5,
                            weight: FontWeight.w500,
                            color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                Semantics(
                  button: true,
                  label: 'Play the alarm',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: silent
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            timer.previewSound();
                          },
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(ArcIcons.byName('play'),
                          size: 22, color: AppColors.accentStrong),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ArcButton(
                label: _choosing ? 'Opening…' : 'Choose a sound',
                icon: 'sound',
                variant: BtnVariant.quiet,
                full: true,
                disabled: _choosing,
                onTap: _choosing ? null : _choose,
              ),
            ),
            // Appears only once there is something to undo — the same rule the
            // accent reset follows.
            if (settings.usesCustomSound) ...[
              const SizedBox(width: 10),
              ArcButton(
                label: 'Default',
                variant: BtnVariant.ghost,
                onTap: () {
                  HapticFeedback.selectionClick();
                  timer.clearSound();
                },
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// The alarm for a rest that ends with Arc off screen is a notification, so
/// without the notification grant it does not sound at all.
///
/// This is the failure that hides best: the in-app alarm needs no permission
/// and keeps working, so the timer looks entirely healthy right up until the
/// one moment it is relied on — the phone in a pocket between sets.
class _NotificationNotice extends StatelessWidget {
  const _NotificationNotice();

  @override
  Widget build(BuildContext context) {
    final timer = context.read<TimerController>();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The alarm cannot sound in the background',
              style: AppText.ui(size: 14.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Arc is not allowed to post notifications, and the alarm for a '
            'rest that ends while you are in another app is one. It will '
            'still sound with Arc on screen.',
            style: AppText.ui(size: 12.5, height: 1.4, color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ArcButton(
              label: 'Allow notifications',
              size: BtnSize.sm,
              variant: BtnVariant.quiet,
              onTap: () => unawaited(timer.ensureNotificationPermission()),
            ),
          ),
        ],
      ),
    );
  }
}

/// Said plainly rather than hidden: without the exact-alarm grant Android is
/// free to run the background alarm late, and a rest timer that is quietly
/// approximate is worse than one that admits it.
class _ExactAlarmNotice extends StatelessWidget {
  const _ExactAlarmNotice();

  @override
  Widget build(BuildContext context) {
    final timer = context.read<TimerController>();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Alarms may run late',
              style: AppText.ui(size: 14.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Android is not letting Arc set exact alarms, so a rest that '
            'finishes while Arc is closed can land a minute or two late.',
            style: AppText.ui(
                size: 12.5, height: 1.4, color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ArcButton(
              label: 'Allow exact alarms',
              size: BtnSize.sm,
              variant: BtnVariant.quiet,
              onTap: () => unawaited(timer.requestExactAlarms()),
            ),
          ),
        ],
      ),
    );
  }
}

/// The hairline between switch rows. One pixel at every density, which a
/// `Divider` does not guarantee.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          height: math.max(1 / MediaQuery.devicePixelRatioOf(context), 0.5),
          child: ColoredBox(
            color: AppColors.line,
            child: const SizedBox.expand(),
          ),
        ),
      );
}
