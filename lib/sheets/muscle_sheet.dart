import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/exercise_row.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

/// Everything filed under one muscle group — what the body opens when you tap
/// it, and what the list opens when you tap a section header.
class MuscleSheet extends StatelessWidget {
  final Muscle muscle;
  const MuscleSheet({super.key, required this.muscle});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();

    final trainCount = <String, int>{};
    for (final s in store.sessions) {
      for (final e in s.entries) {
        trainCount[e.exerciseId] = (trainCount[e.exerciseId] ?? 0) + 1;
      }
    }

    final primary =
        store.exercises.where((e) => e.muscle == muscle).toList();
    final assisting =
        store.exercises.where((e) => e.secondary.contains(muscle)).toList();
    final sets = ArcData.muscleSets(store.sessions, store.exById, muscle);

    Widget row(Exercise e) => ExerciseRow(
          exercise: e,
          trained: trainCount[e.id] ?? 0,
          best: store.records[e.id]?.best,
          showMuscle: false,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Stats(muscle: muscle, exercises: primary.length, sets: sets),
        const SizedBox(height: 18),
        if (primary.isEmpty)
          _Empty(muscle: muscle)
        else
          ExerciseGroupCard(rows: [for (final e in primary) row(e)]),
        if (assisting.isNotEmpty) ...[
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              'ALSO WORKED BY',
              style: AppText.ui(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: AppColors.muted,
                  letterSpacing: 0.5),
            ),
          ),
          // Filed elsewhere, so they read quieter than the group's own lifts —
          // but they're the difference between "I never train triceps" and the
          // truth, so they're on the sheet rather than buried.
          Opacity(
            opacity: 0.62,
            child: ExerciseGroupCard(rows: [for (final e in assisting) row(e)]),
          ),
        ],
        const SizedBox(height: 20),
        ArcButton(
          label: 'Add ${muscle.label.toLowerCase()} exercise',
          icon: 'plus',
          full: true,
          onTap: () => Sheets.openAddExercise(context, muscle: muscle),
        ),
      ],
    );
  }
}

/// The group's last fortnight, stated in sets. Fourteen days is the window the
/// body's heat map uses; saying so keeps the number and the glow the same claim.
class _Stats extends StatelessWidget {
  final Muscle muscle;
  final int exercises;
  final ({int direct, int assisted}) sets;

  const _Stats(
      {required this.muscle, required this.exercises, required this.sets});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '$exercises exercise${exercises == 1 ? '' : 's'}',
      if (sets.direct > 0 || sets.assisted == 0)
        '${sets.direct} set${sets.direct == 1 ? '' : 's'} in 14 days',
      if (sets.assisted > 0) '${sets.assisted} assisted',
    ];

    return Row(
      children: [
        GroupDot(muscle.region, size: 9),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: AppText.ui(
                size: 13.5, weight: FontWeight.w500, color: AppColors.muted),
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final Muscle muscle;
  const _Empty({required this.muscle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 28),
      decoration: BoxDecoration(
        borderRadius: AppRadii.rLg,
        border: Border.all(color: AppColors.cardLine),
      ),
      child: Column(
        children: [
          Text(
            'Nothing filed under ${muscle.label.toLowerCase()} yet.',
            textAlign: TextAlign.center,
            style: AppText.ui(size: 15.5, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Add one and it shows up here, on the body, and in the picker '
            'next time you log.',
            textAlign: TextAlign.center,
            style: AppText.ui(
                size: 13.5,
                height: 1.45,
                weight: FontWeight.w500,
                color: AppColors.faint),
          ),
        ],
      ),
    );
  }
}
