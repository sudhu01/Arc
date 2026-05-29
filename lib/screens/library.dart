import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';

class Library extends StatefulWidget {
  const Library({super.key});

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();

    final trainCount = <String, int>{};
    for (final s in store.sessions) {
      for (final e in s.entries) {
        trainCount[e.exerciseId] = (trainCount[e.exerciseId] ?? 0) + 1;
      }
    }

    final list = store.exercises
        .where((e) => _filter == 'All' || e.group == _filter)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Exercises',
                style: AppText.sora(
                    size: titleStyleSize,
                    weight: FontWeight.w700,
                    letterSpacing: -0.96)),
            ArcButton(
              label: 'New',
              icon: 'plus',
              size: BtnSize.sm,
              variant: BtnVariant.soft,
              onTap: () => Sheets.openAddExercise(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Segmented.simple(
          options: const ['All', 'Push', 'Pull', 'Legs'],
          value: _filter,
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 18),
        Container(
          decoration: BoxDecoration(
            borderRadius: AppRadii.rLg,
            border: Border.all(color: AppColors.cardLine),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < list.length; i++) ...[
                _LibraryRow(
                  exercise: list[i],
                  trained: trainCount[list[i].id] ?? 0,
                  best: store.records[list[i].id]?.best,
                ),
                if (i != list.length - 1)
                  Container(height: 1, color: AppColors.cardLine),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _LibraryRow extends StatelessWidget {
  final dynamic exercise;
  final int trained;
  final dynamic best;
  const _LibraryRow(
      {required this.exercise, required this.trained, this.best});

  @override
  Widget build(BuildContext context) {
    final isBw = exercise.unit == 'bw';

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

    return GestureDetector(
      onTap: best != null ? () => Sheets.openPR(context, exercise.id) : null,
      onLongPress: confirmDelete,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            GroupDot(exercise.group, size: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(exercise.name,
                      style: AppText.sora(size: 15.5, weight: FontWeight.w600)),
                  Text('${exercise.group} · trained $trained×',
                      style: AppText.sora(
                          size: 12,
                          weight: FontWeight.w500,
                          color: AppColors.faint)),
                ],
              ),
            ),
            if (best != null) ...[
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(isBw ? '${best.reps}' : '${best.score}',
                      style: AppText.mono(size: 16, weight: FontWeight.w700)),
                  Text(isBw ? 'reps' : 'kg 1RM',
                      style: AppText.sora(
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
    );
  }
}
