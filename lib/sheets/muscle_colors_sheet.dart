import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/muscle.dart';
import '../theme/app_theme.dart';
import '../theme/muscle_palette.dart';
import '../theme/muscle_palette_controller.dart';
import '../widgets/hue_slider.dart';
import '../widgets/muscle_picker.dart';
import '../widgets/ui.dart';

/// Two hues closer than this on the circle stop being two colours at a glance.
/// The shipped defaults are laid out so the tightest pair sits at 21°, one
/// degree clear — so a fresh install never opens this sheet already complaining.
const _tooClose = 20;

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
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

/// Repaints the thirteen muscle groups.
///
/// The board of all thirteen is the sheet, and the slider is an accessory to it.
/// That inversion is the whole design: the complaint that brings a user here is
/// never "chest is the wrong colour" in isolation, it is "chest and triceps look
/// the same" — a comparison. A picker that showed one swatch at a time would
/// make the user hold the other twelve in their head, which is exactly the thing
/// they came here because they could not do.
///
/// So every group stays on screen and in its live colour while one of them is
/// being dragged, and the sheet names the nearest neighbour underneath. Changes
/// commit and persist as they happen — this is a preference, not a form.
class MuscleColorsSheet extends StatefulWidget {
  const MuscleColorsSheet({super.key});

  @override
  State<MuscleColorsSheet> createState() => _MuscleColorsSheetState();
}

class _MuscleColorsSheetState extends State<MuscleColorsSheet> {
  Muscle _editing = Muscle.values.first;

  @override
  Widget build(BuildContext context) {
    final palette = context.watch<MusclePaletteController>();
    final hue = palette.hueOf(_editing);
    final near = palette.nearest(hue, except: _editing);
    final clash = near != null && near.distance < _tooClose ? near.muscle : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The board. Selection here means "the one I am editing", and it borrows
        // the pill vocabulary the add-exercise sheet already taught — same
        // control, same inverted-fill selected state, so nobody has to learn a
        // second way to pick a muscle group.
        MusclePicker(
          selected: {_editing},
          dotSize: 11,
          onTap: (m) => setState(() => _editing = m),
        ),
        const SizedBox(height: 26),

        // Label and readout share a line — the slider's thumb already shows the
        // colour, so a separate swatch here would just repeat it.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: _label(_editing.label)),
            Text(
              MuscleRamp.nameFor(hue),
              style: AppText.ui(size: 14, weight: FontWeight.w700),
            ),
            const SizedBox(width: 7),
            Text(
              '$hue°',
              style: AppText.mono(
                  size: 13, weight: FontWeight.w600, color: AppColors.muted),
            ),
          ],
        ),
        MuscleHueSlider(
          hue: hue,
          label: _editing.label,
          onChanged: (h) => palette.setHue(_editing, h),
        ),

        // One row for both trailing controls, and always the same height. The
        // sheet is bottom-anchored, so anything that appears down here mid-drag
        // pushes the track up under the user's finger and makes the hue jump.
        //
        // The reset pill is reserved rather than removed, both sides carry the
        // same 44px floor, and the clash note is pinned to one line — so the
        // row is the same height whichever of the two is showing. Deliberately
        // not a fixed height: at 200% text both outgrow 44 and a hard number
        // would clip them.
        Row(
          children: [
            Expanded(
              child: _Clash(
                muscle: clash,
                // Tapping the warning goes and edits the group it names. Half
                // the time the right fix is to move the *other* one, and this
                // is the shortest path to it.
                onTap: clash == null
                    ? null
                    : () => setState(() => _editing = clash),
              ),
            ),
            _ResetAction(
              visible: !palette.isDefault(_editing),
              label: 'Reset ${_editing.label} to its default color',
              onTap: () => palette.reset(_editing),
            ),
          ],
        ),
      ],
    );
  }
}

/// Names the group whose colour the current hue is closing in on, and shows it
/// — the dot is the evidence, so the user can judge the collision without going
/// to hunt for the other group on the board.
///
/// Stated, not prevented. Two groups the user trains on different days may be
/// perfectly fine to hold similar colours, and Arc does not know which those
/// are.
class _Clash extends StatelessWidget {
  final Muscle? muscle;
  final VoidCallback? onTap;

  const _Clash({required this.muscle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final m = muscle;
    if (m == null) return const SizedBox.shrink();

    return Semantics(
      button: true,
      label: 'Close to ${m.label}. Edit ${m.label} instead',
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap?.call();
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            // Matches the reset pill's floor, so the two sides of the row are
            // the same target and the row's height never depends on which of
            // them is showing.
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 2, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MuscleDot(m, size: 9),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Close to ${m.label}',
                    // One line, always: a note that wraps at a large text
                    // scale would grow this row the moment it appeared, which
                    // is the exact shift the reserved layout exists to avoid.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(
                        size: 13,
                        weight: FontWeight.w600,
                        color: AppColors.muted),
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

/// The quiet pill Arc undoes a preference with, matching the accent picker's.
/// Reserved rather than removed when there is nothing to undo, so the row it
/// sits in cannot change height.
class _ResetAction extends StatelessWidget {
  final bool visible;
  final String label;
  final VoidCallback onTap;

  const _ResetAction({
    required this.visible,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      // 44 tall minimum per PRODUCT's touch-target floor; the pill itself is
      // smaller, and the constraint supplies the rest of the target.
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'Reset',
          style: AppText.ui(
              size: 13, weight: FontWeight.w600, color: AppColors.muted),
        ),
      ),
    );

    if (!visible) {
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: pill,
      );
    }

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: pill,
      ),
    );
  }
}

/// Puts the whole palette back, from the sheet's title row.
///
/// It lives up there rather than under the slider because thirteen groups is
/// enough that "start over" is a real thing to want, and because a second reset
/// beside the per-group one would make the user read two identical pills to
/// find out which is which. Confirmed first — it is the only control here that
/// discards work the user cannot recover by dragging back.
class MuscleColorsResetAll extends StatelessWidget {
  const MuscleColorsResetAll({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.watch<MusclePaletteController>();

    final button = SheetIconButton(
      icon: 'restore',
      semanticLabel: 'Reset all group colors',
      onTap: () async {
        HapticFeedback.mediumImpact();
        final ok = await showArcConfirm(
          context: context,
          title: 'Reset all colors?',
          message: 'Every muscle group goes back to the color Arc ships with.',
          confirmLabel: 'Reset',
        );
        if (ok) palette.resetAll();
      },
    );

    // Reserved, not removed: it appears the first time a hue moves, and the
    // title row growing by a few pixels on that frame would nudge the slider
    // under the finger that caused it.
    if (palette.isAllDefault) {
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: button,
      );
    }
    return button;
  }
}
