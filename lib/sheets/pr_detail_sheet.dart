import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

class PRDetailSheet extends StatelessWidget {
  /// Exercise to look up in the user's own store. Null when [record] is given.
  final String? exId;

  /// A record handed in directly — a companion's, which lives outside the
  /// store. Read-only: the "Log" action is dropped.
  final ExerciseRecord? record;

  const PRDetailSheet({super.key, required String this.exId}) : record = null;

  /// Read-only view of a record that isn't the user's own (companion progress).
  const PRDetailSheet.forRecord({
    super.key,
    required ExerciseRecord this.record,
  }) : exId = null;

  @override
  Widget build(BuildContext context) {
    final rec = record ?? context.watch<ArcStore>().records[exId];
    if (rec == null || rec.best == null) return const SizedBox.shrink();
    final ex = rec.ex;
    final isBw = ex.isBodyweight;
    final hist = rec.history;
    final best = rec.best!;
    final maxWeight = hist.isEmpty
        ? 0.0
        : hist.map((h) => h.weight).reduce((a, b) => a > b ? a : b);
    final totalReps = hist.fold<int>(0, (a, h) => a + h.reps);
    // Gain mirrors the chart below: reps for bodyweight, max weight otherwise.
    final num gain = hist.length > 1
        ? (isBw
            ? hist.last.reps - hist.first.reps
            : hist.last.maxWeight - hist.first.maxWeight)
        : 0;

    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // group + tag row
        Row(
          children: [
            GroupDot(ex.region),
            const SizedBox(width: 8),
            // The dot carries the coarse region; spell out the muscle, which is
            // the more specific thing and the only one worth the words.
            Text(ex.muscle.label,
                style: AppText.ui(
                    size: 13.5, weight: FontWeight.w600, color: AppColors.muted)),
            const SizedBox(width: 8),
            const Tag('Personal Record'),
          ],
        ),
        const SizedBox(height: 16),

        // hero number
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: AppRadii.rLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isBw ? 'BEST SET' : 'ESTIMATED 1RM',
                style: AppText.ui(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: AppColors.accentStrong,
                  letterSpacing: 0.75,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    isBw ? '${best.reps}' : ArcData.fmtScore(best.score),
                    style: AppText.mono(size: 52, weight: FontWeight.w700, height: 1),
                  ),
                  const SizedBox(width: 8),
                  Text(isBw ? 'reps' : 'kg',
                      style: AppText.ui(
                          size: 18,
                          weight: FontWeight.w700,
                          color: AppColors.accentStrong)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${isBw ? '${best.reps} reps' : '${fmtW(best.weight)} kg × ${best.reps}'} · ${ArcData.fmtDate(best.date, 'long')}',
                style: AppText.ui(
                    size: 14, weight: FontWeight.w500, color: AppColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // trend chart
        Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadii.rLg,
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(isBw ? 'Reps over time' : 'Max weight per session',
                      style: AppText.ui(size: 13, weight: FontWeight.w600)),
                  if (gain > 0)
                    Row(
                      children: [
                        ArcIcon('arrowUp', size: 13, color: AppColors.up),
                        const SizedBox(width: 3),
                        Text('+${isBw ? gain : fmtW(gain.toDouble())} ${isBw ? 'reps' : 'kg'}',
                            style: AppText.ui(
                                size: 12.5,
                                weight: FontWeight.w700,
                                color: AppColors.up)),
                      ],
                    ),
                ],
              ),
              ProgressChart(
                points: [
                  for (final h in hist)
                    ProgressPoint(ArcData.parseISO(h.date),
                        isBw ? h.reps.toDouble() : h.maxWeight),
                ],
                unit: isBw ? 'reps' : 'kg',
                height: 150,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // stats row
        Row(
          children: [
            if (!isBw) ...[
              StatTile(label: 'Top weight', value: fmtW(maxWeight), unit: 'kg'),
              const SizedBox(width: 10),
            ],
            StatTile(label: 'Sessions', value: '${hist.length}'),
            const SizedBox(width: 10),
            StatTile(label: 'Total reps', value: '$totalReps'),
          ],
        ),
        const SizedBox(height: 16),

        // progression log
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
          child: Text('PROGRESSION',
              style: AppText.ui(
                  size: 13,
                  weight: FontWeight.w700,
                  color: AppColors.muted,
                  letterSpacing: 0.5)),
        ),
        ClipRRect(
          borderRadius: AppRadii.rMd,
          child: Column(
            children: [
              for (var i = hist.length - 1; i >= 0; i--)
                _ProgressRow(
                  point: hist[i],
                  isBw: isBw,
                  isPR: hist[i].score == best.score && hist[i].date == best.date,
                  showDivider: i != 0,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (exId != null)
          ArcButton(
            label: 'Log ${ex.name}',
            icon: 'plus',
            full: true,
            onTap: () {
              Navigator.of(context).maybePop();
              Future.delayed(const Duration(milliseconds: 180), () {
                if (context.mounted) {
                  Sheets.openLog(context, prefillExId: exId);
                }
              });
            },
          ),
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final RecordPoint point;
  final bool isBw;
  final bool isPR;
  final bool showDivider;
  const _ProgressRow({
    required this.point,
    required this.isBw,
    required this.isPR,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(ArcData.fmtDate(point.date),
                      style: AppText.ui(
                          size: 13.5,
                          weight: FontWeight.w500,
                          color: AppColors.muted)),
                ),
                const SizedBox(width: 9),
                Text(
                  isBw
                      ? '${point.reps} reps'
                      : '${fmtW(point.weight)} × ${point.reps}',
                  style: AppText.mono(size: 14.5, weight: FontWeight.w600),
                ),
                if (isPR) ...[
                  const SizedBox(width: 8),
                  ArcIcon('medal', size: 15, color: AppColors.accentStrong),
                ],
                const Spacer(),
                if (!isBw)
                  Text('${ArcData.fmtScore(point.score)} 1RM',
                      style: AppText.mono(
                          size: 13, weight: FontWeight.w500, color: AppColors.faint)),
              ],
            ),
          ),
          if (showDivider) Container(height: 1, color: AppColors.line),
        ],
      ),
    );
  }
}
