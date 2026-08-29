import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/muscle_picker.dart';
import '../widgets/ui.dart';

/// Bulk re-sort for exercises whose group Arc guessed.
///
/// The old Push/Pull/Legs/Core library could not say whether "Push" meant chest
/// or shoulders or triceps, so the upgrade reads every name through a
/// dictionary and flags the ones it couldn't place. This is where those get
/// settled — one screen, one tap each, and an accept-all for a library Arc
/// already got right.
///
/// Deliberately not a first-run wall: it opens from a card the user can dismiss,
/// and every exercise in it already works.
class MuscleReviewSheet extends StatefulWidget {
  const MuscleReviewSheet({super.key});

  @override
  State<MuscleReviewSheet> createState() => _MuscleReviewSheetState();
}

class _MuscleReviewSheetState extends State<MuscleReviewSheet> {
  /// Frozen at open. Confirming a row removes it from the store's unconfirmed
  /// set, and a list that deleted rows out from under the user's thumb mid-sort
  /// would be its own bug.
  List<Exercise>? _queue;

  String? _openId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final queue = _queue ??=
        store.exercises.where((e) => !e.muscleConfirmed).toList();

    if (queue.isEmpty) return const _AllDone();

    final byId = {for (final e in store.exercises) e.id: e};
    final remaining = queue.where((e) => !(byId[e.id]?.muscleConfirmed ?? true));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Arc guessed these from their names when it moved your library to '
          'muscle groups. Correct any it got wrong.',
          style: AppText.ui(
              size: 14,
              height: 1.5,
              weight: FontWeight.w500,
              color: AppColors.muted),
        ),
        const SizedBox(height: 18),
        for (final stale in queue) ...[
          _ReviewRow(
            exercise: byId[stale.id] ?? stale,
            settled: byId[stale.id]?.muscleConfirmed ?? false,
            open: _openId == stale.id,
            onToggleOpen: () => setState(
                () => _openId = _openId == stale.id ? null : stale.id),
            onPick: (m) async {
              setState(() => _openId = null);
              await store.setExerciseMuscles(stale.id, muscle: m);
            },
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 12),
        ArcButton(
          label: remaining.isEmpty
              ? 'Done'
              : 'Keep the remaining ${remaining.length}',
          icon: 'check',
          full: true,
          onTap: () async {
            await store.confirmAllMuscles();
            if (context.mounted) Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final Exercise exercise;
  final bool settled;
  final bool open;
  final VoidCallback onToggleOpen;
  final ValueChanged<Muscle> onPick;

  const _ReviewRow({
    required this.exercise,
    required this.settled,
    required this.open,
    required this.onToggleOpen,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadii.rMd,
        border: Border.all(
            color: open ? AppColors.accentLine : AppColors.cardLine),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: open,
            label: '${exercise.name}, currently ${exercise.muscle.label}'
                '${settled ? ', confirmed' : ''}',
            // ExcludeSemantics drops the child's tap action; without this the
            // row announces as a button that cannot be opened.
            onTap: onToggleOpen,
            child: ExcludeSemantics(
              child: GestureDetector(
                onTap: onToggleOpen,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(exercise.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.ui(
                                size: 15, weight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 10),
                      MuscleDot(exercise.muscle, size: 8),
                      const SizedBox(width: 7),
                      Text(
                        exercise.muscle.label,
                        style: AppText.ui(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color:
                              settled ? AppColors.ink : AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
              child: MusclePicker(
                selected: {exercise.muscle},
                onTap: onPick,
                // The review card only ever holds lifts whose group Arc
                // guessed. Cardio is never guessed, so Conditioning is never
                // an answer here.
                muscles: Muscle.trainable,
              ),
            ),
        ],
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        'Every exercise has a muscle group.',
        textAlign: TextAlign.center,
        style: AppText.ui(size: 15.5, weight: FontWeight.w600),
      ),
    );
  }
}
