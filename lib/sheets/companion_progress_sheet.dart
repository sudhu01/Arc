import 'package:flutter/material.dart';

import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

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
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final records = d.records;
    final sessions = d.sessions;
    final stats = d.stats;

    // Lifts the companion has actually logged, ranked so the heaviest 1RM
    // surfaces first; bodyweight lifts (no 1RM) sort to the back.
    final logged = d.exercises
        .where((e) => records[e.id]?.history.isNotEmpty ?? false)
        .toList()
      ..sort((a, b) {
        final byUnit =
            (a.isBodyweight ? 1 : 0).compareTo(b.isBodyweight ? 1 : 0);
        if (byUnit != 0) return byUnit;
        return (records[b.id]?.best?.score ?? 0.0)
            .compareTo(records[a.id]?.best?.score ?? 0.0);
      });
    final defaultSel = logged.isNotEmpty ? logged.first.id : null;
    final sel = (_sel != null && (records[_sel]?.history.isNotEmpty ?? false))
        ? _sel
        : defaultSel;
    final selRec = sel == null ? null : records[sel];
    final selHist = selRec?.history ?? const <RecordPoint>[];
    final selBw = selRec?.ex.isBodyweight ?? false;
    final selDelta = selHist.length > 1
        ? selHist[selHist.length - 1].score - selHist[selHist.length - 2].score
        : 0;

    final query = _query.trim().toLowerCase();
    final results = query.isEmpty
        ? const <Exercise>[]
        : logged.where((e) => e.name.toLowerCase().contains(query)).toList();

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
          // ── this-week stats ─────────────────────────────────────────
          Row(
            children: [
              StatTile(
                  label: 'This week',
                  value: '${stats.thisWeek}',
                  unit: 'workouts'),
              const SizedBox(width: 10),
              StatTile(
                  label: 'This week',
                  value: '${stats.setsThisWeek}',
                  unit: 'sets'),
            ],
          ),
          const SizedBox(height: 22),

          // ── strength progress — searchable 1RM over time ─────────────
          ArcCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ArcIcon('trend', size: 17, color: AppColors.accentStrong),
                    const SizedBox(width: 7),
                    Text('Strength progress',
                        style: AppText.ui(size: 15, weight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 12),
                _searchField(d.companion.displayName),
                if (results.isNotEmpty)
                  ..._resultRows(results, records)
                else if (query.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 20, 2, 6),
                    child: Text('No logged exercise matches that search.',
                        style: AppText.ui(
                            size: 13,
                            weight: FontWeight.w500,
                            color: AppColors.muted)),
                  )
                else if (selRec != null && selRec.best != null)
                  _selectedProgress(selRec, selHist, selBw, selDelta)
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 20, 2, 6),
                    child: Text(
                        'No weighted sets synced yet, so there is no 1RM to '
                        'chart.',
                        style: AppText.ui(
                            size: 13,
                            weight: FontWeight.w500,
                            color: AppColors.muted)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),

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

  Widget _searchField(String name) {
    final has = _query.isNotEmpty;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      child: Row(
        children: [
          ArcIcon('search', size: 18, color: AppColors.faint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              onChanged: (v) => setState(() => _query = v),
              cursorColor: AppColors.accentStrong,
              style: AppText.ui(size: 14, weight: FontWeight.w500),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: "Search ${_firstName(name)}'s exercises",
                hintStyle: AppText.ui(
                    size: 14, weight: FontWeight.w500, color: AppColors.faint),
              ),
            ),
          ),
          if (has)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _clearSearch,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ArcIcon('x', size: 16, color: AppColors.faint),
              ),
            ),
        ],
      ),
    );
  }

  void _clearSearch() {
    _searchCtl.clear();
    _searchFocus.unfocus();
    setState(() => _query = '');
  }

  static String _firstName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'their';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  List<Widget> _resultRows(
      List<Exercise> results, Map<String, ExerciseRecord> records) {
    final shown = results.take(8).toList();
    final out = <Widget>[const SizedBox(height: 6)];
    for (var i = 0; i < shown.length; i++) {
      final ex = shown[i];
      out.add(_resultRow(ex, records[ex.id]!));
      if (i != shown.length - 1) {
        out.add(Container(height: 1, color: AppColors.line));
      }
    }
    return out;
  }

  Widget _resultRow(Exercise ex, ExerciseRecord rec) {
    final isBw = ex.isBodyweight;
    return PressScale(
      scale: 0.99,
      onTap: () {
        _searchCtl.clear();
        _searchFocus.unfocus();
        setState(() {
          _sel = ex.id;
          _query = '';
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            MuscleDot(ex.muscle),
            const SizedBox(width: 10),
            Expanded(
              child: Text(ex.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui(size: 14.5, weight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Text(
              isBw
                  ? '${rec.best!.reps} reps'
                  : '${ArcData.fmtScore(rec.best!.score)} kg',
              style: AppText.mono(
                  size: 13, weight: FontWeight.w600, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectedProgress(ExerciseRecord selRec, List<RecordPoint> selHist,
      bool selBw, num selDelta) {
    final ex = selRec.ex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Sheets.openCompanionPR(context, selRec),
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MuscleDot(ex.muscle),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(ex.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui(size: 15.5, weight: FontWeight.w700)),
                ),
                ArcIcon('chevR', size: 18, color: AppColors.faint),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                            selBw
                                ? '${selRec.best!.reps}'
                                : ArcData.fmtScore(selRec.best!.score),
                            style: AppText.mono(
                                size: 34, weight: FontWeight.w700, height: 1)),
                        const SizedBox(width: 8),
                        Text(selBw ? 'best reps' : 'kg est. 1RM',
                            style: AppText.ui(
                                size: 14,
                                weight: FontWeight.w600,
                                color: AppColors.muted)),
                      ],
                    ),
                  ),
                ),
                if (selDelta > 0) ...[
                  const SizedBox(width: 8),
                  ArcIcon('arrowUp', size: 13, color: AppColors.up),
                  const SizedBox(width: 3),
                  Text('+${ArcData.fmtScore(selDelta)}',
                      style: AppText.ui(
                          size: 13,
                          weight: FontWeight.w700,
                          color: AppColors.up)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            ProgressChart(
              points: [
                for (final h in selHist)
                  ProgressPoint(ArcData.parseISO(h.date), h.score),
              ],
              unit: selBw ? 'reps' : 'kg',
              height: 150,
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(String name) => ArcCard(
        padding: const EdgeInsets.fromLTRB(20, 30, 20, 26),
        child: Column(
          children: [
            ArcIcon('people', size: 40, color: AppColors.faint),
            const SizedBox(height: 14),
            Text('Nothing synced yet',
                style: AppText.ui(size: 18, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              "When $name logs workouts and syncs, their progress shows up here. "
              'Pull to sync from the Companions screen.',
              textAlign: TextAlign.center,
              style:
                  AppText.ui(size: 13.5, height: 1.4, color: AppColors.muted),
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
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(_initials(data.companion.displayName),
              style: AppText.ui(
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
                style: AppText.ui(size: 14, weight: FontWeight.w600),
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

    return PressScale(
      onTap: () => Sheets.openCompanionPR(context, r),
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
                MuscleDot(r.ex.muscle),
                if (isNew) const Tag('New'),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                      isBw ? '${r.best!.reps}' : ArcData.fmtScore(r.best!.score),
                      style: AppText.mono(
                          size: 30, weight: FontWeight.w700, height: 1)),
                  const SizedBox(width: 4),
                  Text(isBw ? 'reps' : 'kg',
                      style: AppText.ui(
                          size: 13,
                          weight: FontWeight.w600,
                          color: AppColors.muted)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(r.ex.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(size: 13.5, weight: FontWeight.w600)),
            const SizedBox(height: 6),
            Spark(
                data: r.history.map((h) => h.score).toList(),
                width: 130,
                height: 26),
            const SizedBox(height: 6),
            Text(
              '${isBw ? '${r.best!.reps} reps' : '${fmtW(r.best!.weight)} × ${r.best!.reps}'} · ${ArcData.relDate(r.best!.date)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui(
                  size: 11.5, weight: FontWeight.w500, color: AppColors.faint),
            ),
          ],
        ),
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
    final grp = ArcData.sessionGroup(session, data.exById);
    final names = session.entries
        .map((e) => data.exById(e.exerciseId)?.name)
        .where((n) => n != null)
        .join(' · ');
    final dt = ArcData.parseISO(session.date);

    return ArcCard(
      onTap: () => Sheets.openCompanionDay(context, session, data),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          DateChip(date: dt),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GroupDot(grp),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(session.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.ui(size: 15.5, weight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(names,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(size: 12.5, color: AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(ArcData.relDate(session.date),
              style: AppText.ui(
                  size: 10.5, weight: FontWeight.w600, color: AppColors.faint)),
        ],
      ),
    );
  }
}
