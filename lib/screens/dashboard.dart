import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/cardio.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../timer/timer_bar.dart';
import '../timer/timer_controller.dart';
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

  /// Which conditioning exercise the card below is showing. Null follows the
  /// most recently trained one, which is right until the user says otherwise.
  String? _cardioSel;
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
    //
    // Conditioning is not in here. Its score is a speed in metres per second,
    // and a card headed "Strength progress" that offered to plot one against a
    // column labelled "kg est. 1RM" would be quoting the right number under the
    // wrong name. It gets its own card below.
    final logged = exercises
        .where((e) =>
            !e.isCardio && (records[e.id]?.history.isNotEmpty ?? false))
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

    // Conditioning, most recently trained first — the machine you were on
    // yesterday is the one you want to see when you open Arc today.
    final cardioLogged = exercises
        .where((e) => e.isCardio && (records[e.id]?.history.isNotEmpty ?? false))
        .toList()
      ..sort((a, b) => records[b.id]!.history.last.date
          .compareTo(records[a.id]!.history.last.date));
    final cardioSel =
        cardioLogged.any((e) => e.id == _cardioSel) ? _cardioSel : null;
    final cardioEx = cardioLogged.isEmpty
        ? null
        : cardioLogged.firstWhere((e) => e.id == cardioSel,
            orElse: () => cardioLogged.first);

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
            const _TimerButton(),
            const SizedBox(width: 8),
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
            // Conditioning rides the sets tile's sub line rather than taking a
            // third tile. `StatTile`'s value is mono 22 with no `FittedBox`, so
            // three across would crowd at large text scale — and the user who
            // has never logged a run never sees the line at all.
            StatTile(
                label: 'This week',
                value: '${stats.setsThisWeek}',
                unit: 'sets',
                sub: stats.cardioSecsThisWeek > 0
                    ? '+ ${(stats.cardioSecsThisWeek / 60).round()} min conditioning'
                    : null),
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
        if (cardioEx != null) ...[
          const SizedBox(height: 16),
          _cardioCard(context, cardioEx, cardioLogged, records[cardioEx.id]!),
        ],
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

  /// Conditioning, as its own card beside Strength progress.
  ///
  /// No search field: a lifting library runs to dozens of exercises, a cardio
  /// one to the two or three machines the gym has. Naming them outright is
  /// faster than typing, and it doubles as the list of what is being tracked.
  ///
  /// The chart plots **pace**, so it falls as the runner gets faster. That is
  /// the right way round — it is the shape a pace is, and the delta beside it
  /// flips its arrow to match so a falling line still reads as the win it is.
  Widget _cardioCard(
    BuildContext context,
    Exercise ex,
    List<Exercise> all,
    ExerciseRecord rec,
  ) {
    final kind = ex.cardio;
    final hist = rec.history;
    final floors = kind.countsFloors;

    double value(RecordPoint h) => floors
        ? ((h.secs ?? 0) <= 0 ? 0 : (h.dist ?? 0) / (h.secs! / 60))
        : ((h.dist ?? 0) <= 0 || (h.secs ?? 0) <= 0
            ? 0
            : h.secs! / (h.dist! / 1000));

    final delta = hist.length < 2
        ? 0.0
        : floors
            ? value(hist.last) - value(hist[hist.length - 2])
            : value(hist[hist.length - 2]) - value(hist.last);

    return ArcCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      onTap: () => Sheets.openPR(context, ex.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ArcIcon('run', size: 17, color: AppColors.accentStrong),
              const SizedBox(width: 7),
              Text('Conditioning',
                  style: AppText.ui(size: 15, weight: FontWeight.w700)),
              const Spacer(),
              ArcIcon('chevR', size: 18, color: AppColors.faint),
            ],
          ),
          // Only worth drawing when there is a choice to make.
          if (all.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in all)
                  _CardioPill(
                    label: c.name,
                    selected: c.id == ex.id,
                    onTap: () => setState(() => _cardioSel = c.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
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
                      Text(bestCardioValue(rec.best!, kind),
                          style: AppText.mono(
                              size: 34, weight: FontWeight.w700, height: 1)),
                      const SizedBox(width: 8),
                      Text(floors ? 'floors/min best' : 'best /km',
                          style: AppText.ui(
                              size: 14,
                              weight: FontWeight.w600,
                              color: AppColors.muted)),
                    ],
                  ),
                ),
              ),
              if (delta > 0) ...[
                const SizedBox(width: 8),
                ArcIcon(floors ? 'arrowUp' : 'arrowDown',
                    size: 13, color: AppColors.up),
                const SizedBox(width: 3),
                Text(
                    floors
                        ? '+${delta.toStringAsFixed(1)}'
                        : '−${formatDuration(delta.round())}',
                    style: AppText.ui(
                        size: 13, weight: FontWeight.w700, color: AppColors.up)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            label: '${ex.name} pace over ${hist.length} '
                '${hist.length == 1 ? 'session' : 'sessions'}. '
                'Best ${bestCardioValue(rec.best!, kind)}'
                '${floors ? ' floors per minute' : ' per kilometre'}'
                '${delta > 0 ? ', improving' : ''}.',
            excludeSemantics: true,
            child: ProgressChart(
              points: [
                for (final h in hist)
                  ProgressPoint(ArcData.parseISO(h.date), value(h)),
              ],
              unit: floors ? 'floors/min' : 'min/km',
              formatValue:
                  floors ? null : (v) => formatDuration(v.round()),
              height: 140,
            ),
          ),
        ],
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

/// Opens the rest timer.
///
/// Wears the accent while a rest is running, so the header answers "is my timer
/// going?" without the user opening anything. When one *is* running the bar is
/// already on screen above this and is the faster target — this is the way in
/// when nothing is running, which is the only time it needs to be found.
class _TimerButton extends StatelessWidget {
  const _TimerButton();

  @override
  Widget build(BuildContext context) {
    final active = context.select<TimerController, bool>((t) => t.isActive);
    return _HeaderButton(
      icon: ArcIcons.byName('timer', filled: active),
      tooltip: active ? 'Rest running' : 'Rest timer',
      iconColor: active ? AppColors.accentStrong : null,
      onTap: () => openTimer(context),
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
    // Every group the session trained, not just the dominant one — a workout
    // is rarely one thing, and the row has the vertical room to say so.
    final muscles = ArcData.sessionMuscles(ses, store.exById);
    final fallback =
        muscles.isEmpty ? ArcData.sessionGroup(ses, store.exById) : null;
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
                    MuscleDots(muscles: muscles, fallbackRegion: fallback),
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

/// One machine, as a selectable pill on the Conditioning card.
///
/// Selected fills with ink rather than the accent — the same rule the muscle
/// picker and the records filter follow. On a card whose point is the number
/// and the trend line, a wall of volt would be the loudest thing on it and the
/// least informative.
class _CardioPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CardioPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            // The 44 floor everything tappable in Arc holds to.
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: selected ? AppColors.ink : AppColors.surface2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: selected ? AppColors.ink : AppColors.line),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui(
                size: 13.5,
                weight: FontWeight.w600,
                color: selected ? AppColors.surface : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
