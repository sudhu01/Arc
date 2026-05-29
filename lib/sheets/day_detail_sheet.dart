import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

class DayDetailSheet extends StatelessWidget {
  final String date;
  const DayDetailSheet({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final ses = store.sessionForDate(date);

    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    void edit() {
      Navigator.of(context).maybePop();
      Future.delayed(const Duration(milliseconds: 180), () {
        if (context.mounted) Sheets.openLog(context, date: date);
      });
    }

    if (ses == null) {
      // rest day empty state
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Column(
          children: [
            const ArcIcon('dumbbell', size: 40, color: AppColors.faint),
            const SizedBox(height: 14),
            Text('Rest day',
                style: AppText.sora(size: 17, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('No workout logged for this day.',
                style: AppText.sora(size: 14, color: AppColors.muted)),
            const SizedBox(height: 18),
            ArcButton(
                label: 'Log a workout', icon: 'plus', full: true, onTap: edit),
          ],
        ),
      );
    }

    final totalSets =
        ses.entries.fold<int>(0, (a, e) => a + e.sets.length);
    final vol = ArcData.sessionVolume(ses);

    Future<void> delete() async {
      final ok = await showArcConfirm(
        context: context,
        title: 'Delete workout?',
        message:
            "This removes ${ses.title} and all its sets from your history. "
            "This can't be undone.",
        confirmLabel: 'Delete',
      );
      if (!ok || !context.mounted) return;
      await context.read<ArcStore>().deleteSession(date);
      if (context.mounted) Navigator.of(context).maybePop();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Tag(ses.title),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '$totalSets sets · ${vol.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')} kg volume',
                style: AppText.sora(
                    size: 13, weight: FontWeight.w500, color: AppColors.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        for (final e in ses.entries)
          if (store.exById(e.exerciseId) case final ex?) ...[
            _EntryCard(exercise: ex, sets: e.sets, fmtW: fmtW),
            const SizedBox(height: 14),
          ],
        Row(
          children: [
            Expanded(
              child: ArcButton(
                  label: 'Edit workout',
                  icon: 'pencil',
                  variant: BtnVariant.ghost,
                  full: true,
                  onTap: edit),
            ),
            const SizedBox(width: 10),
            ArcButton(
                label: 'Delete',
                icon: 'trash',
                variant: BtnVariant.danger,
                onTap: delete),
          ],
        ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  final dynamic exercise;
  final List sets;
  final String Function(double) fmtW;
  const _EntryCard(
      {required this.exercise, required this.sets, required this.fmtW});

  @override
  Widget build(BuildContext context) {
    final isBw = exercise.unit == 'bw';
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GroupDot(exercise.group),
              const SizedBox(width: 8),
              Text(exercise.name,
                  style: AppText.sora(size: 16, weight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final s in sets)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: const BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: AppRadii.rSm,
                  ),
                  child: Text(
                    isBw
                        ? '${s.reps} reps'
                        : '${fmtW(s.weight as double)} × ${s.reps}',
                    style: AppText.mono(size: 13.5, weight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
