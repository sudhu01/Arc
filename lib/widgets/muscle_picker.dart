import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/muscle.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// The thirteen muscle groups as a wrap of pills.
///
/// Thirteen is past what a `Segmented` row can hold, and a dropdown would hide
/// twelve options behind a tap — so they all stay on screen. Selection inverts
/// the pill (ink fill, surface text) rather than spending the accent: picking a
/// group in a form is not the accent's job, and a wall of volt would drown the
/// one control that is.
///
/// Every pill keeps its group dot in both states, so the colour the user filed
/// the group under stays readable — and group identity is never carried by
/// colour on its own, since the name is right beside it.
class MusclePicker extends StatelessWidget {
  final Set<Muscle> selected;
  final ValueChanged<Muscle> onTap;

  /// Rendered at half opacity and inert — used for the primary group while the
  /// user is choosing secondaries, since a lift can't support itself.
  final Set<Muscle> disabled;

  /// Bigger where the colour is the point rather than a tag — the group-colour
  /// picker, where the user is comparing thirteen swatches against each other
  /// and a 7px dot is not enough to judge.
  final double dotSize;

  /// Which groups to offer. Defaults to all fourteen, which is right for a
  /// browsing surface like the records filter. A form asking what a *lift*
  /// works passes [Muscle.trainable] — Conditioning is not an answer to that
  /// question, and offering it would let a barbell be filed under it.
  final List<Muscle>? muscles;

  const MusclePicker({
    super.key,
    required this.selected,
    required this.onTap,
    this.disabled = const {},
    this.dotSize = 7,
    this.muscles,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final m in muscles ?? Muscle.values)
          _MusclePill(
            muscle: m,
            selected: selected.contains(m),
            disabled: disabled.contains(m),
            dotSize: dotSize,
            onTap: () => onTap(m),
          ),
      ],
    );
  }
}

class _MusclePill extends StatelessWidget {
  final Muscle muscle;
  final bool selected;
  final bool disabled;
  final double dotSize;
  final VoidCallback onTap;

  const _MusclePill({
    required this.muscle,
    required this.selected,
    required this.disabled,
    required this.dotSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      // 44 is the floor everything tappable in Arc holds to — these sit in a
      // sheet with a keyboard up, which is the worst case for thumb accuracy.
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: selected ? AppColors.ink : AppColors.surface2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? AppColors.ink : AppColors.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MuscleDot(muscle, size: dotSize),
          const SizedBox(width: 8),
          Text(
            muscle.label,
            style: AppText.ui(
              size: 14,
              weight: FontWeight.w600,
              color: selected ? AppColors.surface : AppColors.ink,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      enabled: !disabled,
      label: '${muscle.label}, ${muscle.region}',
      // The wrapper below drops the child's tap action, so the pill needs its
      // own here or it announces as a button that will not pick.
      onTap: disabled
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: ExcludeSemantics(
        child: Opacity(
          opacity: disabled ? 0.35 : 1,
          child: GestureDetector(
            onTap: disabled
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap();
                  },
            behavior: HitTestBehavior.opaque,
            child: pill,
          ),
        ),
      ),
    );
  }
}

/// One-line summary of an exercise's secondary groups — "Triceps, Shoulders",
/// or a prompt when there are none. Used as the collapsed head of the
/// secondary-group picker.
String secondarySummary(List<Muscle> muscles) => muscles.isEmpty
    ? 'None'
    : muscles.map((m) => m.label).join(', ');
