import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';

class Dashboard extends StatefulWidget {
  final void Function(int tab) onNavTab;
  const Dashboard({super.key, required this.onNavTab});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  String? _sel;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final records = store.records;
    final exercises = store.exercises;
    final sessions = store.sessions;
    final stats = store.stats;

    final hour = DateTime.now().hour;
    final greet =
        hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';

    final lifts = ['bench', 'squat', 'deadlift']
        .where((id) => records[id] != null && records[id]!.history.isNotEmpty)
        .toList();
    final sel = _sel ??
        (lifts.isNotEmpty
            ? lifts.first
            : (exercises.isNotEmpty ? exercises.first.id : null));
    final selRec = sel == null ? null : records[sel];
    final selHist = selRec?.history ?? [];
    final selDelta = selHist.length > 1
        ? selHist[selHist.length - 1].score - selHist[selHist.length - 2].score
        : 0;

    // recent PRs
    final prList = exercises
        .map((e) => records[e.id])
        .where((r) => r != null && r.best != null)
        .toList()
      ..sort((a, b) => b!.best!.date.compareTo(a!.best!.date));
    final prShown = prList.take(5).toList();
    final recent = sessions.take(4).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      children: [
        // greeting + companions entry
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(greet,
                      style: AppText.sora(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: AppColors.muted)),
                  const SizedBox(height: 2),
                  Text(
                    ArcData.fmtDate(ArcData.iso(ArcData.today), 'long'),
                    style: AppText.sora(
                        size: 30,
                        weight: FontWeight.w700,
                        letterSpacing: -0.9,
                        height: 1.05),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            PressScale(
              onTap: () => Sheets.openCompanions(context),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardLine),
                  boxShadow: AppShadows.card,
                ),
                child: const Icon(Icons.people_outline_rounded,
                    size: 22, color: AppColors.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // week stats
        Row(
          children: [
            StatTile(label: 'This week', value: '${stats.thisWeek}', unit: 'workouts'),
            const SizedBox(width: 10),
            StatTile(
                label: 'Volume',
                value: ArcData.fmtVolK(stats.totalVol),
                unit: 'kg'),
            const SizedBox(width: 10),
            StatTile(label: 'Total sets', value: '${stats.totalSets}'),
          ],
        ),
        const SizedBox(height: 24),

        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 56, 0, 24),
            child: Column(
              children: [
                const ArcIcon('dumbbell', size: 40, color: AppColors.faint),
                const SizedBox(height: 14),
                Text('No workouts yet',
                    style: AppText.sora(size: 18, weight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  'Log your first workout to start tracking progress, '
                  'records, and weekly stats.',
                  textAlign: TextAlign.center,
                  style: AppText.sora(
                      size: 13.5, height: 1.4, color: AppColors.muted),
                ),
                const SizedBox(height: 18),
                ArcButton(
                  label: 'Log a workout',
                  icon: 'plus',
                  onTap: () => Sheets.openLog(context),
                ),
              ],
            ),
          )
        else ...[
        // progress chart card
        ArcCard(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const ArcIcon('trend', size: 17, color: AppColors.accentStrong),
                  const SizedBox(width: 7),
                  Text('Strength progress',
                      style: AppText.sora(size: 15, weight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 12),
              Segmented(
                options: lifts
                    .map((id) =>
                        SegOption(id, records[id]!.ex.name.split(' ').first))
                    .toList(),
                value: sel ?? '',
                onChanged: (v) => setState(() => _sel = v),
              ),
              const SizedBox(height: 14),
              if (selRec != null && selRec.best != null)
                GestureDetector(
                  onTap: () => Sheets.openPR(context, sel!),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('${selRec.best!.score}',
                              style: AppText.mono(
                                  size: 34, weight: FontWeight.w700, height: 1)),
                          const SizedBox(width: 8),
                          Text('kg est. 1RM',
                              style: AppText.sora(
                                  size: 14,
                                  weight: FontWeight.w600,
                                  color: AppColors.muted)),
                          const Spacer(),
                          if (selDelta > 0)
                            Row(
                              children: [
                                const ArcIcon('arrowUp',
                                    size: 13, color: AppColors.up),
                                const SizedBox(width: 3),
                                Text('+$selDelta',
                                    style: AppText.sora(
                                        size: 13,
                                        weight: FontWeight.w700,
                                        color: AppColors.up)),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LineChart(
                          data: selHist.map((h) => h.score).toList(),
                          height: 120),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // PRs
        SectionHead(
            title: 'Personal records',
            action: 'See all',
            onAction: () => widget.onNavTab(1)),
        SizedBox(
          height: 186,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 2),
            itemCount: prShown.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final r = prShown[i]!;
              final isBw = r.ex.isBodyweight;
              final isNew = ArcData.daysAgo(r.best!.date) <= 16;
              String fmtW(double w) =>
                  w % 1 == 0 ? w.toInt().toString() : w.toString();
              return PressScale(
                onTap: () => Sheets.openPR(context, r.ex.id),
                scale: 0.97,
                child: Container(
                  width: 158,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppRadii.rLg,
                    border: Border.all(color: AppColors.cardLine),
                    boxShadow: AppShadows.card,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          GroupDot(r.ex.group),
                          if (isNew) const Tag('New'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(isBw ? '${r.best!.reps}' : '${r.best!.score}',
                              style: AppText.mono(
                                  size: 30, weight: FontWeight.w700, height: 1)),
                          const SizedBox(width: 4),
                          Text(isBw ? 'reps' : 'kg',
                              style: AppText.sora(
                                  size: 13,
                                  weight: FontWeight.w600,
                                  color: AppColors.muted)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(r.ex.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.sora(size: 13.5, weight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Spark(
                        data: r.history.map((h) => h.score).toList(),
                        width: 130,
                        height: 26,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${isBw ? '${r.best!.reps} reps' : '${fmtW(r.best!.weight)} × ${r.best!.reps}'} · ${ArcData.relDate(r.best!.date)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.sora(
                            size: 11.5,
                            weight: FontWeight.w500,
                            color: AppColors.faint),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24),

        // recent workouts
        SectionHead(
            title: 'Recent workouts',
            action: 'History',
            onAction: () => widget.onNavTab(2)),
        for (final ses in recent) ...[
          _RecentRow(ses: ses),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  final dynamic ses;
  const _RecentRow({required this.ses});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    final grp = ses.title.contains('Push')
        ? 'Push'
        : ses.title.contains('Pull')
            ? 'Pull'
            : 'Legs';
    final names = ses.entries
        .map((e) => store.exById(e.exerciseId)?.name)
        .where((n) => n != null)
        .join(' · ');
    final d = ArcData.parseISO(ses.date);
    final vol = ArcData.sessionVolume(ses);

    return ArcCard(
      onTap: () => Sheets.openDay(context, ses.date),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                color: AppColors.surface2, borderRadius: BorderRadius.circular(14)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${d.day}',
                    style: AppText.mono(size: 17, weight: FontWeight.w700, height: 1)),
                const SizedBox(height: 1),
                Text(ArcData.weekdayShort[ArcData.jsWeekday(d)].toUpperCase(),
                    style: AppText.sora(
                        size: 9.5,
                        weight: FontWeight.w700,
                        color: AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GroupDot(grp),
                    const SizedBox(width: 7),
                    Text(ses.title,
                        style: AppText.sora(size: 15.5, weight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(names,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.sora(size: 12.5, color: AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${(vol / 1000).toStringAsFixed(1)}k',
                  style: AppText.mono(size: 13.5, weight: FontWeight.w600)),
              Text(ArcData.relDate(ses.date),
                  style: AppText.sora(
                      size: 10.5, weight: FontWeight.w600, color: AppColors.faint)),
            ],
          ),
        ],
      ),
    );
  }
}
