import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';

class Records extends StatefulWidget {
  const Records({super.key});

  @override
  State<Records> createState() => _RecordsState();
}

class _RecordsState extends State<Records> {
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final list = store.exercises
        .map((e) => store.records[e.id])
        .where((r) => r != null && r.best != null)
        .where((r) => _filter == 'All' || r!.ex.group == _filter)
        .toList()
      ..sort((a, b) {
        final sa = a!.ex.isBodyweight ? 0 : a.best!.score;
        final sb = b!.ex.isBodyweight ? 0 : b.best!.score;
        return sb.compareTo(sa);
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      children: [
        Text('Records',
            style: AppText.sora(
                size: titleStyleSize, weight: FontWeight.w700, letterSpacing: -0.96)),
        const SizedBox(height: 16),
        Segmented.simple(
          options: const ['All', 'Push', 'Pull', 'Legs'],
          value: _filter,
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 18),
        for (final r in list) ...[
          _RecordRow(rec: r!),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _RecordRow extends StatelessWidget {
  final dynamic rec;
  const _RecordRow({required this.rec});

  @override
  Widget build(BuildContext context) {
    final ex = rec.ex;
    final isBw = ex.isBodyweight;
    final best = rec.best;
    final isNew = ArcData.daysAgo(best.date) <= 16;
    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    return ArcCard(
      onTap: () => Sheets.openPR(context, ex.id),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GroupDot(ex.group),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(ex.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.sora(size: 16, weight: FontWeight.w700)),
                    ),
                    if (isNew) ...[
                      const SizedBox(width: 7),
                      const Tag('New'),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${isBw ? '${best.reps} reps' : '${fmtW(best.weight)} kg × ${best.reps}'} · ${ArcData.relDate(best.date)}',
                  style: AppText.sora(
                      size: 12.5, weight: FontWeight.w500, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 13),
          Spark(
              data: List<num>.from(rec.history.map((h) => h.score)),
              width: 56,
              height: 26),
          const SizedBox(width: 13),
          SizedBox(
            width: 56,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(isBw ? '${best.reps}' : '${best.score}',
                    style: AppText.mono(size: 22, weight: FontWeight.w700, height: 1)),
                const SizedBox(height: 1),
                Text(isBw ? 'reps' : 'est. 1RM',
                    style: AppText.sora(
                        size: 10.5,
                        weight: FontWeight.w600,
                        color: AppColors.faint)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
