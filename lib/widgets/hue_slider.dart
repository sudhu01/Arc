import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/accent.dart';
import '../theme/app_theme.dart';

/// The accent hue track.
///
/// The ramp is painted from the accents Arc would actually derive at each hue,
/// not a generic HSV rainbow — so the gradient is a preview of outcomes rather
/// than decoration, and the dip in chroma around blue is honest about what the
/// user will get.
///
/// Built from a raw gesture recognizer like [ArcStepper] rather than Material's
/// `Slider`, which arrives with its own overlay, tick and value-indicator
/// vocabulary that reads as stock Material next to Arc's controls.
class HueSlider extends StatefulWidget {
  const HueSlider({
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

  /// 24 stops (every 15°) — dense enough that the ramp reads as continuous,
  /// cheap enough to rebuild during a drag.
  List<Color> _ramp() => [
        for (var h = 0; h <= 360; h += 15)
          AccentRamp.derive(h % 360, dark: widget.dark).accent,
      ];

  void _emit(double dx, double travel) {
    // Guard the degenerate layout: a track narrower than its thumb would divide
    // by zero and hand `round()` a NaN, which throws.
    if (travel <= 0) return;
    final t = (dx / travel).clamp(0.0, 1.0);
    final hue = (t * 359).round().clamp(0, 359);
    if (hue == widget.hue) return;

    // A detent at each named band gives the drag a sense of structure without
    // quantizing the value itself.
    final band = AccentRamp.nameFor(hue);
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
    final tokens = AccentRamp.derive(widget.hue, dark: widget.dark);
    final isDefault =
        widget.hue == AccentRamp.defaultHue(dark: widget.dark);
    final swatch =
        isDefault ? ArcTheme.palette.accent : tokens.accent;

    return Semantics(
      slider: true,
      label: 'Accent hue',
      value: '${AccentRamp.nameFor(widget.hue)}, ${widget.hue} degrees',
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
                        gradient: LinearGradient(colors: _ramp()),
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
                          color: swatch,
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
