import 'package:flutter/material.dart';

import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';

/// Read-only view of a companion's synced progress — mirrors the dashboard
/// (week/all-time stats, strength chart, PR rail, recent workouts) using the
/// companion's own exercises + sessions. Shown in a full sheet.
class CompanionProgressSheet extends StatefulWidget {
  final CompanionData data;
  const CompanionProgressSheet({super.key, required this.data});

  @override
  State<CompanionProgressSheet> createState() => _CompanionProgressSheetState();
}

class _CompanionProgressSheetState extends State<CompanionProgressSheet> {
  String? _sel;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final records = d.records;
    final sessions = d.sessions;
    final stats = d.stats;

    // Lifts that have a progression, ranked by best score → chart selector.
    final lifts = d.exercises
        .where((e) => records[e.id]?.history.isNotEmpty ?? false)
        .toList()
      ..sort((a, b) => (records[b.id]?.best?.score ?? 0)
          .compareTo(records[a.id]?.best?.score ?? 0));
    final chartLifts = lifts.take(3).toList();
    final sel = _sel ?? (chartLifts.isNotEmpty ? chartLifts.first.id : null);
    final selRec = sel == null ? null : records[sel];
    final selHist = selRec?.history ?? const <RecordPoint>[];
    final selDelta = selHist.length > 1
        ? selHist[selHist.length - 1].score - selHist[selHist.length - 2].score
        : 0;

    final prShown = (d.exercises
            .map((e) => records[e.id])
            .where((r) => r != null && r.best != null)
            .toList()
          ..sort((a, b) => b!.best!.date.compareTo(a!.best!.date)))
        .take(8)
        .toList();
    final recent = sessions.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _IdentityStrip(data: d),
        const SizedBox(height: 18),

        if (sessions.isEmpty)
          _emptyState(d.companion.displayName)
        else ...[
          // ── all-time stats ──────────────────────────────────────────
          Row(
            children: [
              StatTile(label: 'Workouts', value: '${stats.total}'),
              const SizedBox(width: 10),
              StatTile(
                  label: 'Volume',
                  value: ArcData.fmtVolK(stats.totalVol),
                  sub: 'kg all-time'),
              const SizedBox(width: 10),
              StatTile(label: 'Total sets', value: '${stats.totalSets}'),
            ],
          ),
          const SizedBox(height: 22),

          // ── strength progress ───────────────────────────────────────
          if (chartLifts.isNotEmpty && selRec != null && selRec.best != null) ...[
            ArcCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const ArcIcon('trend',
                          size: 17, color: AppColors.accentStrong),
                      const SizedBox(width: 7),
                      Text('Strength progress',
                          style: AppText.sora(size: 15, weight: FontWeight.w700)),
                    ],
                  ),
                  if (chartLifts.length > 1) ...[
                    const SizedBox(height: 12),
                    Segmented(
                      options: chartLifts
                          .map((e) => SegOption(e.id, e.name.split(' ').first))
                          .toList(),
                      value: sel ?? chartLifts.first.id,
                      onChanged: (v) => setState(() => _sel = v),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('${selRec.best!.score}',
                          style: AppText.mono(
                              size: 34, weight: FontWeight.w700, height: 1)),
                      const SizedBox(width: 8),
                      Text(selRec.ex.isBodyweight ? 'reps best' : 'kg est. 1RM',
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
                      data: selHist.map((h) => h.score).toList(), height: 120),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── personal records ────────────────────────────────────────
          if (prShown.isNotEmpty) ...[
            SectionHead(title: 'Personal records'),
            SizedBox(
              height: 186,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 2),
                itemCount: prShown.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _PrCard(record: prShown[i]!),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── recent workouts ─────────────────────────────────────────
          SectionHead(title: 'Recent workouts'),
          for (final s in recent) ...[
            _RecentRow(session: s, data: d),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _emptyState(String name) => ArcCard(
        padding: const EdgeInsets.fromLTRB(20, 30, 20, 26),
        child: Column(
          children: [
            const ArcIcon('people', size: 40, color: AppColors.faint),
            const SizedBox(height: 14),
            Text('Nothing synced yet',
                style: AppText.sora(size: 18, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              "When $name logs workouts and syncs, their progress shows up here. "
              'Pull to sync from the Companions screen.',
              textAlign: TextAlign.center,
              style:
                  AppText.sora(size: 13.5, height: 1.4, color: AppColors.muted),
            ),
          ],
        ),
      );
}

class _IdentityStrip extends StatelessWidget {
  final CompanionData data;
  const _IdentityStrip({required this.data});

  @override
  Widget build(BuildContext context) {
    final last = data.sessions.isNotEmpty ? data.sessions.first.date : null;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            color: AppColors.accentSoft,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(_initials(data.companion.displayName),
              style: AppText.sora(
                  size: 17,
                  weight: FontWeight.w700,
                  color: AppColors.accentStrong)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                last != null
                    ? 'Last workout ${ArcData.relDate(last)}'
                    : 'No workouts yet',
                style: AppText.sora(size: 14, weight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(_shortId(data.companion.publicId),
                  style: AppText.mono(size: 11.5, color: AppColors.muted)),
            ],
          ),
        ),
        const Tag('Synced'),
      ],
    );
  }

  static String _shortId(String id) => id.length <= 16
      ? id
      : '${id.substring(0, 8)}…${id.substring(id.length - 6)}';

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }
}

/// Personal-record card (mirrors the dashboard's PR rail), read-only.
class _PrCard extends StatelessWidget {
  final ExerciseRecord record;
  const _PrCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final r = record;
    final isBw = r.ex.isBodyweight;
    final isNew = ArcData.daysAgo(r.best!.date) <= 16;
    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    return Container(
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
                  style:
                      AppText.mono(size: 30, weight: FontWeight.w700, height: 1)),
              const SizedBox(width: 4),
              Text(isBw ? 'reps' : 'kg',
                  style: AppText.sora(
                      size: 13, weight: FontWeight.w600, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 8),
          Text(r.ex.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.sora(size: 13.5, weight: FontWeight.w600)),
          const SizedBox(height: 6),
          Spark(data: r.history.map((h) => h.score).toList(), width: 130, height: 26),
          const SizedBox(height: 6),
          Text(
            '${isBw ? '${r.best!.reps} reps' : '${fmtW(r.best!.weight)} × ${r.best!.reps}'} · ${ArcData.relDate(r.best!.date)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.sora(
                size: 11.5, weight: FontWeight.w500, color: AppColors.faint),
          ),
        ],
      ),
    );
  }
}

/// Recent-workout row (mirrors the dashboard), resolving names from the
/// companion's own exercise library.
class _RecentRow extends StatelessWidget {
  final Session session;
  final CompanionData data;
  const _RecentRow({required this.session, required this.data});

  @override
  Widget build(BuildContext context) {
    final grp = session.title.contains('Push')
        ? 'Push'
        : session.title.contains('Pull')
            ? 'Pull'
            : 'Legs';
    final names = session.entries
        .map((e) => data.exById(e.exerciseId)?.name)
        .where((n) => n != null)
        .join(' · ');
    final dt = ArcData.parseISO(session.date);
    final vol = ArcData.sessionVolume(session);

    return ArcCard(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(14)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${dt.day}',
                    style:
                        AppText.mono(size: 17, weight: FontWeight.w700, height: 1)),
                const SizedBox(height: 1),
                Text(ArcData.weekdayShort[ArcData.jsWeekday(dt)].toUpperCase(),
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
                    Text(session.title,
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
              Text(ArcData.relDate(session.date),
                  style: AppText.sora(
                      size: 10.5, weight: FontWeight.w600, color: AppColors.faint)),
            ],
          ),
        ],
      ),
    );
  }
}
