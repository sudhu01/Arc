import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/accent.dart';
import '../theme/app_theme.dart';
import '../theme/muscle_palette.dart';

/// A hue track.
///
/// The ramp is painted from the colours Arc would actually derive at each hue,
/// not a generic HSV rainbow — so the gradient is a preview of outcomes rather
/// than decoration, and the dip in chroma around blue is honest about what the
/// user will get. [AccentHueSlider] and [MuscleHueSlider] below supply their own
/// ramps and share everything else, which is what keeps the accent picker and
/// the group-colour picker feeling like one control rather than two.
///
/// Built from a raw gesture recognizer like [ArcStepper] rather than Material's
/// `Slider`, which arrives with its own overlay, tick and value-indicator
/// vocabulary that reads as stock Material next to Arc's controls.
class HueSlider extends StatefulWidget {
  const HueSlider({
    super.key,
    required this.hue,
    required this.onChanged,
    required this.ramp,
    required this.swatch,
    required this.semanticsLabel,
    required this.bandName,
  });

  final int hue;
  final ValueChanged<int> onChanged;

  /// Gradient stops across 0..359, left to right.
  final List<Color> ramp;

  /// Thumb fill — the colour the current hue actually resolves to.
  final Color swatch;

  final String semanticsLabel;

  /// Names the band a hue falls in, for the screen-reader value and for the
  /// detent haptic.
  final String Function(int) bandName;

  @override
  State<HueSlider> createState() => _HueSliderState();
}

class _HueSliderState extends State<HueSlider> {
  static const _trackHeight = 28.0;
  static const _thumbSize = 34.0;
  // PRODUCT requires 44px minimum targets; the visible track is slimmer than
  // that, so the gesture area is padded out to meet it.
  static const _touchHeight = 44.0;

  bool _dragging = false;
  String? _lastBand;

  void _emit(double dx, double travel) {
    // Guard the degenerate layout: a track narrower than its thumb would divide
    // by zero and hand `round()` a NaN, which throws.
    if (travel <= 0) return;
    final t = (dx / travel).clamp(0.0, 1.0);
    final hue = (t * 359).round().clamp(0, 359);
    if (hue == widget.hue) return;

    // A detent at each named band gives the drag a sense of structure without
    // quantizing the value itself.
    final band = widget.bandName(hue);
    if (band != _lastBand) {
      _lastBand = band;
      HapticFeedback.selectionClick();
    }
    widget.onChanged(hue);
  }

  @override
  Widget build(BuildContext context) {
    // Honor reduced motion: the thumb should still track the finger, but it
    // shouldn't grow or ease.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Semantics(
      slider: true,
      label: widget.semanticsLabel,
      value: '${widget.bandName(widget.hue)}, ${widget.hue} degrees',
      increasedValue: '${(widget.hue + 5) % 360} degrees',
      decreasedValue: '${(widget.hue - 5) % 360} degrees',
      onIncrease: () => widget.onChanged((widget.hue + 5) % 360),
      onDecrease: () => widget.onChanged((widget.hue - 5) % 360),
      child: LayoutBuilder(
        builder: (context, c) {
          final width = c.maxWidth;
          final t = widget.hue / 359;
          // Inset so the thumb's centre can't run past the track's rounded end.
          final travel = width - _thumbSize;
          final left = t * travel;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _emit(
                d.localPosition.dx - _thumbSize / 2, travel),
            onHorizontalDragStart: (d) {
              setState(() => _dragging = true);
              _emit(d.localPosition.dx - _thumbSize / 2, travel);
            },
            onHorizontalDragUpdate: (d) =>
                _emit(d.localPosition.dx - _thumbSize / 2, travel),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              HapticFeedback.lightImpact();
            },
            onHorizontalDragCancel: () => setState(() => _dragging = false),
            child: SizedBox(
              height: _touchHeight,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Center(
                    child: Container(
                      height: _trackHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_trackHeight / 2),
                        gradient: LinearGradient(colors: widget.ramp),
                        border: Border.all(color: AppColors.cardLine),
                      ),
                    ),
                  ),
                  Positioned(
                    left: left,
                    child: AnimatedScale(
                      scale: _dragging && !reduceMotion ? 1.12 : 1,
                      duration: Duration(
                          milliseconds: reduceMotion ? 0 : 140),
                      curve: Curves.easeOutQuart,
                      child: Container(
                        width: _thumbSize,
                        height: _thumbSize,
                        decoration: BoxDecoration(
                          color: widget.swatch,
                          shape: BoxShape.circle,
                          // The ring is what keeps the thumb legible at every
                          // hue — against a same-hue track, colour alone can't
                          // separate it.
                          border: Border.all(
                              color: AppColors.surface, width: 3.5),
                          boxShadow: AppShadows.card,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The accent hue track, ramped through [AccentRamp].
class AccentHueSlider extends StatelessWidget {
  const AccentHueSlider({
    super.key,
    required this.hue,
    required this.onChanged,
    required this.dark,
  });

  final int hue;
  final ValueChanged<int> onChanged;

  /// Which theme's ramp to paint. Passed in rather than read from [ArcTheme]
  /// so the track is correct on the frame the mode flips.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    // At the shipped hue the palette bypasses derivation entirely, so the thumb
    // has to read the hand-tuned constant or it sits a shade off the app behind
    // it.
    final isDefault = hue == AccentRamp.defaultHue(dark: dark);
    return HueSlider(
      hue: hue,
      onChanged: onChanged,
      // 25 stops (every 15°) — dense enough that the ramp reads as continuous,
      // cheap enough to rebuild during a drag.
      ramp: [
        for (var h = 0; h <= 360; h += 15)
          AccentRamp.derive(h % 360, dark: dark).accent,
      ],
      swatch:
          isDefault ? ArcTheme.palette.accent : AccentRamp.derive(hue, dark: dark).accent,
      semanticsLabel: 'Accent hue',
      bandName: AccentRamp.nameFor,
    );
  }
}

/// The group-colour hue track, ramped through [MuscleRamp].
///
/// Flatter than the accent ramp by design: every stop is the same lightness, so
/// the track reads as one continuous band of equal-weight colour — which is
/// exactly the promise the picker is making about the thirteen dots.
class MuscleHueSlider extends StatelessWidget {
  const MuscleHueSlider({
    super.key,
    required this.hue,
    required this.onChanged,
    required this.label,
  });

  final int hue;
  final ValueChanged<int> onChanged;

  /// The group being edited, for the screen-reader label — "Chest colour"
  /// rather than a thirteenth anonymous slider.
  final String label;

  @override
  Widget build(BuildContext context) {
    return HueSlider(
      hue: hue,
      onChanged: onChanged,
      ramp: [
        for (var h = 0; h <= 360; h += 15) MuscleRamp.color(h % 360),
      ],
      swatch: MuscleRamp.color(hue),
      semanticsLabel: '$label color',
      bandName: MuscleRamp.nameFor,
    );
  }
}
