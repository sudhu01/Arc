import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
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
    final store = context.watch<ArcStore>();
    final records = store.records;
    final exercises = store.exercises;
    final sessions = store.sessions;
    final stats = store.stats;

    final hour = DateTime.now().hour;
    final greet =
        hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
    final rawName = store.identity.displayName?.trim() ?? '';
    final name = rawName.isEmpty ? 'there' : rawName;

    // Exercises the user has actually logged, ranked so the heaviest 1RM
    // surfaces first; bodyweight lifts (no 1RM) sort to the back.
    final logged = exercises
        .where((e) => records[e.id]?.history.isNotEmpty ?? false)
        .toList()
      ..sort((a, b) {
        final byUnit =
            (a.isBodyweight ? 1 : 0).compareTo(b.isBodyweight ? 1 : 0);
        if (byUnit != 0) return byUnit;
        return (records[b.id]!.best?.score ?? 0.0)
            .compareTo(records[a.id]!.best?.score ?? 0.0);
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

    // recent PRs
    final prList = exercises
        .map((e) => records[e.id])
        .where((r) => r != null && r.best != null)
        .toList()
      ..sort((a, b) => b!.best!.date.compareTo(a!.best!.date));
    final prShown = prList.take(5).toList();
    final recent = sessions.take(4).toList();

    return ListView(
      // The shell is re-keyed (and so recreated) on every theme and accent
      // change; this restores the scroll offset across that rebuild.
      key: const PageStorageKey('dashboard'),
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
                      style: AppText.ui(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: AppColors.muted)),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    style: AppText.ui(
                        size: 30,
                        weight: FontWeight.w700,
                        letterSpacing: -0.9,
                        height: 1.05),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const _AppearanceButton(),
            const SizedBox(width: 8),
            _HeaderButton(
              icon: Icons.people_outline_rounded,
              tooltip: 'Companions',
              onTap: () => Sheets.openCompanions(context),
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
                label: 'This week', value: '${stats.setsThisWeek}', unit: 'sets'),
          ],
        ),
        const SizedBox(height: 24),

        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 56, 0, 24),
            child: Column(
              children: [
                ArcIcon('dumbbell', size: 40, color: AppColors.faint),
                const SizedBox(height: 14),
                Text('No workouts yet',
                    style: AppText.ui(size: 18, weight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  'Log your first workout to start tracking progress, '
                  'records, and weekly stats.',
                  textAlign: TextAlign.center,
                  style: AppText.ui(
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
        // strength progress — searchable 1RM over time
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
              _searchField(),
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
                _selectedProgress(
                    context, sel!, selRec, selHist, selBw, selDelta)
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 20, 2, 6),
                  child: Text('Log a weighted set to start tracking your 1RM.',
                      style: AppText.ui(
                          size: 13,
                          weight: FontWeight.w500,
                          color: AppColors.muted)),
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
              final isNew = ArcData.isNewRecord(r.best!.date);
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
                                isBw
                                    ? '${r.best!.reps}'
                                    : ArcData.fmtScore(r.best!.score),
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
                          style:
                              AppText.ui(size: 13.5, weight: FontWeight.w600)),
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
                        style: AppText.ui(
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

  Widget _searchField() {
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
                hintText: 'Search your exercises',
                hintStyle: AppText.ui(
                    size: 14, weight: FontWeight.w500, color: AppColors.faint),
              ),
            ),
          ),
          if (has)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _searchCtl.clear();
                _searchFocus.unfocus();
                setState(() => _query = '');
              },
              child: Padding(
                padding: EdgeInsets.only(left: 6),
                child: ArcIcon('x', size: 16, color: AppColors.faint),
              ),
            ),
        ],
      ),
    );
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

  Widget _selectedProgress(BuildContext context, String sel,
      ExerciseRecord selRec, List<RecordPoint> selHist, bool selBw, num selDelta) {
    final ex = selRec.ex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Sheets.openPR(context, sel),
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
                          size: 13, weight: FontWeight.w700, color: AppColors.up)),
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
}

/// Square icon button in the dashboard header, styled as a small card.
class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? iconColor;

  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.onLongPress,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      // A tooltip claims long-press on touch platforms, which would fight a
      // button that binds its own. Buttons with a long-press keep the tooltip
      // for its semantics and hover, but not its gesture.
      triggerMode: onLongPress != null ? TooltipTriggerMode.manual : null,
      child: PressScale(
        onTap: onTap,
        onLongPress: onLongPress,
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
          child: Icon(icon, size: 22, color: iconColor ?? AppColors.ink),
        ),
      ),
    );
  }
}

/// Opens the Appearance sheet — light/dark plus the accent picker.
///
/// The glyph reports the active mode and is drawn in the active accent, so the
/// control previews the setting it opens. It uses `accentStrong` rather than
/// `accent`: at 22px the light theme's bright fill sits near 1.35:1 on the
/// button's white surface and would all but disappear.
///
/// Long-press still flips light/dark outright. Moving the toggle into a sheet
/// costs the old one-tap path, and that path is worth keeping for a user
/// standing in a gym.
class _AppearanceButton extends StatelessWidget {
  const _AppearanceButton();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final dark = theme.isDark;
    return _HeaderButton(
      icon: dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
      tooltip: 'Appearance',
      iconColor: AppColors.accentStrong,
      onTap: () {
        HapticFeedback.selectionClick();
        Sheets.openAppearance(context);
      },
      onLongPress: () {
        HapticFeedback.selectionClick();
        theme.toggle();
      },
    );
  }
}

class _RecentRow extends StatelessWidget {
  final dynamic ses;
  const _RecentRow({required this.ses});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    final grp = ArcData.sessionGroup(ses, store.exById);
    final names = ses.entries
        .map((e) => store.exById(e.exerciseId)?.name)
        .where((n) => n != null)
        .join(' · ');
    final d = ArcData.parseISO(ses.date);

    return ArcCard(
      onTap: () => Sheets.openDay(context, ses.date),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          DateChip(date: d),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GroupDot(grp),
                    const SizedBox(width: 7),
                    // A workout the user named can run long; it ellipsizes here
                    // rather than shoving the date out of the row.
                    Expanded(
                      child: Text(ses.displayTitle,
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
          Text(ArcData.relDate(ses.date),
              style: AppText.ui(
                  size: 10.5, weight: FontWeight.w600, color: AppColors.faint)),
        ],
      ),
    );
  }
}
