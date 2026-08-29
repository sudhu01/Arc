import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import 'arc_icons.dart';
import 'ui.dart';

/// One exercise, as it appears everywhere Arc lists them: the library, a muscle
/// group's sheet, the review sheet. Tapping opens the PR detail when there is a
/// record to open; long-pressing deletes.
///
/// The best set is the reason to look at this row at all, so it carries the
/// only mono numerals and the only right-hand weight in the layout.
class ExerciseRow extends StatelessWidget {
  final Exercise exercise;
  final int trained;
  final RecordPoint? best;

  /// Whether to name the muscle group in the subtitle. Off inside a group's own
  /// sheet, where every row would repeat the sheet's title.
  final bool showMuscle;

  /// Replaces the default open-PR behaviour — used by the review sheet, where a
  /// tap means "reassign this one" instead.
  final VoidCallback? onTap;

  /// The refile grip, seated in a rail down the row's left edge. Supplied by
  /// the library, which owns the drag; every other list passes nothing and
  /// keeps the tighter inset it always had.
  ///
  /// Deliberately outside the row's own gesture detector: holding the grip must
  /// never trip the long-press that deletes.
  final Widget? handle;

  /// True while this row is the one in the air. It stays in place and goes
  /// translucent rather than collapsing — mid-drag the list is a set of
  /// destinations, and one that resized under the finger would move all of them.
  final bool lifted;

  const ExerciseRow({
    super.key,
    required this.exercise,
    required this.trained,
    this.best,
    this.showMuscle = true,
    this.onTap,
    this.handle,
    this.lifted = false,
  });

  @override
  Widget build(BuildContext context) {
    final isBw = exercise.isBodyweight;
    final b = best;

    Future<void> confirmDelete() async {
      HapticFeedback.mediumImpact();
      final ok = await showArcConfirm(
        context: context,
        title: 'Delete ${exercise.name}?',
        message: trained > 0
            ? 'It will be removed from your library. Past workouts that used '
                'it keep their logged sets.'
            : 'It will be removed from your exercise library.',
        confirmLabel: 'Delete',
      );
      if (!ok || !context.mounted) return;
      await context.read<ArcStore>().deleteExercise(exercise.id);
    }

    final subtitle = [
      if (showMuscle) exercise.muscle.label,
      trained > 0 ? 'trained $trained×' : 'never trained',
    ].join(' · ');

    final activate =
        onTap ?? (b != null ? () => Sheets.openPR(context, exercise.id) : null);

    final body = Semantics(
      button: true,
      label: '${exercise.name}, $subtitle'
          '${b == null ? '' : ', best ${isBw ? '${b.reps} reps' : '${ArcData.fmtScore(b.score)} kilo estimated one rep max'}'}',
      // Registered on the semantics node itself. ExcludeSemantics below drops
      // the gesture detector's own actions, so without these the row announces
      // as a button that cannot be pressed and hides its delete entirely.
      onTap: activate,
      onLongPress: confirmDelete,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: activate,
          onLongPress: confirmDelete,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            // The rail already carries the row's left inset when there is one.
            padding: EdgeInsets.fromLTRB(handle == null ? 16 : 2, 15, 16, 15),
            child: Row(
              children: [
                MuscleDot(exercise.muscle, size: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(exercise.name,
                          style:
                              AppText.ui(size: 15.5, weight: FontWeight.w600)),
                      Text(subtitle,
                          style: AppText.ui(
                              size: 12,
                              weight: FontWeight.w500,
                              color: AppColors.faint)),
                    ],
                  ),
                ),
                if (b != null) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                          exercise.isCardio
                              ? bestCardioValue(b, exercise.cardio)
                              : isBw
                                  ? '${b.reps}'
                                  : ArcData.fmtScore(b.score),
                          style:
                              AppText.mono(size: 16, weight: FontWeight.w700)),
                      Text(
                          exercise.isCardio
                              ? bestCardioUnit(exercise.cardio)
                              : isBw
                                  ? 'reps'
                                  : 'kg 1RM',
                          style: AppText.ui(
                              size: 10,
                              weight: FontWeight.w600,
                              color: AppColors.faint)),
                    ],
                  ),
                  const SizedBox(width: 8),
                ],
                Icon(ArcIcons.byName('chevR'), size: 17, color: AppColors.faint),
              ],
            ),
          ),
        ),
      ),
    );

    return Container(
      color: AppColors.surface,
      child: AnimatedOpacity(
        opacity: lifted ? 0.34 : 1,
        duration: const Duration(milliseconds: 140),
        child: handle == null
            ? body
            : Row(children: [handle!, Expanded(child: body)]),
      ),
    );
  }
}

/// The hairline-separated container Arc wraps every list of rows in. Pulled out
/// so the library, the muscle sheet and the review sheet can't drift apart on
/// border radius or divider colour.
class ExerciseGroupCard extends StatelessWidget {
  final List<Widget> rows;

  /// True while a lift is hovering this group in the library. The whole card
  /// answers rather than the row under the finger: the drop files the exercise
  /// under the *group*, and the card is what the group looks like.
  final bool highlighted;

  const ExerciseGroupCard({
    super.key,
    required this.rows,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: AppRadii.rLg,
        border: Border.all(
            color: highlighted ? AppColors.accentLine : AppColors.cardLine),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // The drop indicator: the accent seam a released lift lands on. Zero
          // height until the group is the one under the finger, so it opens the
          // card rather than decorating it.
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutQuart,
            height: highlighted ? 3 : 0,
            color: AppColors.accent,
          ),
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1)
              Container(height: 1, color: AppColors.cardLine),
          ],
        ],
      ),
    );
  }
}
