import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/record_query.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';

/// Every lift's best, ranked.
///
/// The screen used to split on the four movement patterns, back when that was
/// the only tier Arc had. Now that a lift is filed under one of thirteen muscle
/// groups, four buttons across the top can neither name what the user is
/// looking at nor narrow it usefully — so the whole question moved into one
/// control beside the title, and the answer moved into a strip of chips that
/// says out loud what is being hidden.
class Records extends StatefulWidget {
  const Records({super.key});

  @override
  State<Records> createState() => _RecordsState();
}

class _RecordsState extends State<Records> {
  RecordQuery _query = RecordQuery.initial;

  void _apply(RecordQuery next) => setState(() => _query = next);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();

    final all = [
      for (final e in store.exercises)
        if (store.records[e.id]?.best != null) store.records[e.id]!,
    ];
    final list = _query.apply(all);
    final grouped = _query.sort == RecordSort.muscle;

    final perGroup = <Muscle, int>{};
    if (grouped) {
      for (final r in list) {
        perGroup[r.ex.muscle] = (perGroup[r.ex.muscle] ?? 0) + 1;
      }
    }

    Muscle? lastGroup;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      children: [
        Row(
          children: [
            // Flexible so the title ellipsizes rather than shoving the control
            // off the row at large system text scales.
            Flexible(
              child: Text('Records',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui(
                      size: titleStyleSize,
                      weight: FontWeight.w700,
                      letterSpacing: -0.96)),
            ),
            const SizedBox(width: 8),
            _SortButton(
              query: _query,
              onTap: () => Sheets.openRecordsFilter(
                context,
                query: _query,
                onChanged: _apply,
              ),
            ),
          ],
        ),

        // Nothing between the title and the records until the user narrows
        // them — the default view is the whole list, and it should not have to
        // announce that.
        if (_query.isDefault)
          const SizedBox(height: 14)
        else ...[
          const SizedBox(height: 10),
          _ActiveQuery(
            query: _query,
            onChanged: _apply,
            onEdit: () => Sheets.openRecordsFilter(
              context,
              query: _query,
              onChanged: _apply,
            ),
          ),
          const SizedBox(height: 16),
        ],

        if (all.isEmpty)
          const _RecordsEmpty()
        else if (list.isEmpty)
          _NoMatches(
            hidden: all.length,
            onClear: () => _apply(_query.withoutFilters),
          )
        else
          for (final r in list) ...[
            if (grouped && r.ex.muscle != lastGroup) ...[
              if (r != list.first) const SizedBox(height: 14),
              _GroupHeader(
                muscle: lastGroup = r.ex.muscle,
                count: perGroup[r.ex.muscle]!,
              ),
              const SizedBox(height: 9),
            ],
            _RecordRow(rec: r),
            const SizedBox(height: 10),
          ],

        const SizedBox(height: 8),
      ],
    );
  }
}

/// Opens the sort/filter sheet, and reports its state while closed.
///
/// The bars lean the way the list is ranked and the square fills with accent
/// once anything is narrowed, so the control shows the setting it opens — the
/// same job the palette button does on Exercises. What exactly is narrowed is
/// the chip strip's business; a 34px square can say "filtered", not "how".
class _SortButton extends StatelessWidget {
  final RecordQuery query;
  final VoidCallback onTap;

  const _SortButton({required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = !query.isDefault;

    void open() {
      HapticFeedback.selectionClick();
      onTap();
    }

    return Semantics(
      button: true,
      label: active ? 'Sort and filter records, active' : 'Sort and filter records',
      // ExcludeSemantics below drops the gesture detector's own action, so
      // without this the button announces as one that cannot be pressed.
      onTap: open,
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'Sort & filter',
          child: PressScale(
            onTap: open,
            borderRadius: AppRadii.rMd,
            // The 34px square matches the palette button on Exercises; the 44px
            // box around it is the tap target PRODUCT requires, which the
            // visual can't supply on its own.
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: AnimatedContainer(
                  duration: Duration(
                      milliseconds:
                          MediaQuery.disableAnimationsOf(context) ? 0 : 180),
                  curve: Curves.easeOut,
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? AppColors.accentSoft : AppColors.surface2,
                    borderRadius: AppRadii.rMd,
                  ),
                  child: SortBars(
                    reversed: query.reversed,
                    size: 17,
                    color: active ? AppColors.accentStrong : AppColors.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the list is currently doing, as chips you can undo one at a time.
///
/// A filter you cannot see is a bug report waiting to happen — the user comes
/// back to Records a week later, finds four lifts, and concludes Arc lost the
/// rest. So every narrowing states itself here, and every chip carries the way
/// out of it.
class _ActiveQuery extends StatelessWidget {
  final RecordQuery query;
  final ValueChanged<RecordQuery> onChanged;
  final VoidCallback onEdit;

  const _ActiveQuery({
    required this.query,
    required this.onChanged,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];

    final sortIsDefault =
        query.sort == RecordSort.best && !query.reversed;
    if (!sortIsDefault) {
      final (natural, flipped) = query.sort.orderLabels;
      chips.add(_Chip(
        label: '${query.sort.label} · ${query.reversed ? flipped : natural}',
        leading: SortBars(
            reversed: query.reversed, size: 13, color: AppColors.muted),
        semanticLabel:
            'Sorted by ${query.sort.label}, ${query.reversed ? flipped : natural}. '
            'Edit sort and filters',
        onTap: onEdit,
      ));
    }

    if (query.unit != RecordUnit.all) {
      chips.add(_Chip(
        label: query.unit.label,
        semanticLabel: '${query.unit.label} lifts only. Remove filter',
        onRemove: () => onChanged(query.copyWith(unit: RecordUnit.all)),
      ));
    }

    if (query.newOnly) {
      chips.add(_Chip(
        label: 'New records',
        semanticLabel: 'New records only. Remove filter',
        onRemove: () => onChanged(query.copyWith(newOnly: false)),
      ));
    }

    // Past three groups the names stop being readable at a glance and start
    // being a second list above the list — so they collapse into their dots
    // and a count, and the sheet stays the place to see them all.
    final muscles = [
      for (final m in Muscle.values)
        if (query.muscles.contains(m)) m,
    ];
    if (muscles.length > 3) {
      chips.add(_Chip(
        label: '${muscles.length} groups',
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in muscles.take(3)) ...[
              MuscleDot(m, size: 8),
              const SizedBox(width: 3),
            ],
          ],
        ),
        semanticLabel:
            '${muscles.length} muscle groups: ${muscles.map((m) => m.label).join(', ')}. '
            'Edit sort and filters',
        onTap: onEdit,
      ));
    } else {
      for (final m in muscles) {
        chips.add(_Chip(
          label: m.label,
          leading: MuscleDot(m, size: 8),
          semanticLabel: '${m.label} only. Remove filter',
          onRemove: () => onChanged(query.toggleMuscle(m)),
        ));
      }
    }

    // One chip is its own reset — a second control to undo a single thing is
    // clutter.
    if (chips.length > 1) {
      chips.add(_Chip(
        label: 'Reset',
        ghost: true,
        semanticLabel: 'Reset sort and filters',
        onTap: () => onChanged(RecordQuery.initial),
      ));
    }

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }
}

/// One line of the active query. Carries an × when it names something being
/// hidden, and opens the sheet when it names something too big to undo in one
/// tap.
class _Chip extends StatelessWidget {
  final String label;
  final String semanticLabel;
  final Widget? leading;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool ghost;

  const _Chip({
    required this.label,
    required this.semanticLabel,
    this.leading,
    this.onRemove,
    this.onTap,
    this.ghost = false,
  });

  @override
  Widget build(BuildContext context) {
    void fire() {
      HapticFeedback.selectionClick();
      (onRemove ?? onTap)!();
    }

    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: fire,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: fire,
          child: Container(
            // 44 is the floor everything tappable in Arc holds to.
            constraints: const BoxConstraints(minHeight: 44),
            padding: EdgeInsets.only(left: 13, right: onRemove != null ? 9 : 13),
            decoration: BoxDecoration(
              color: ghost ? Colors.transparent : AppColors.surface2,
              borderRadius: BorderRadius.circular(999),
              border: ghost ? Border.all(color: AppColors.line) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: ghost ? AppColors.muted : AppColors.ink,
                    ),
                  ),
                ),
                if (onRemove != null) ...[
                  const SizedBox(width: 5),
                  Icon(Icons.close_rounded, size: 15, color: AppColors.faint),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Names the run of records below it when the list is ranked by group — thirteen
/// coloured dots down a list read as decoration; a header reads as an index.
class _GroupHeader extends StatelessWidget {
  final Muscle muscle;
  final int count;

  const _GroupHeader({required this.muscle, required this.count});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: '${muscle.label}, $count records',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(left: 2, right: 2),
          child: Row(
            children: [
              MuscleDot(muscle),
              const SizedBox(width: 8),
              Flexible(
                child: Text(muscle.label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(
                        size: 12.5,
                        weight: FontWeight.w700,
                        color: AppColors.muted,
                        letterSpacing: 0.5)),
              ),
              const SizedBox(width: 8),
              Text('$count',
                  style: AppText.mono(
                      size: 12.5,
                      weight: FontWeight.w600,
                      color: AppColors.faint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  final ExerciseRecord rec;
  const _RecordRow({required this.rec});

  @override
  Widget build(BuildContext context) {
    final ex = rec.ex;
    final isBw = ex.isBodyweight;
    final best = rec.best!;
    final isNew = ArcData.isNewRecord(best.date);
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
                    MuscleDot(ex.muscle),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(ex.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.ui(size: 16, weight: FontWeight.w700)),
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
                  style: AppText.ui(
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
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(isBw ? '${best.reps}' : ArcData.fmtScore(best.score),
                      style: AppText.mono(
                          size: 22, weight: FontWeight.w700, height: 1)),
                ),
                const SizedBox(height: 1),
                Text(isBw ? 'reps' : 'est. 1RM',
                    style: AppText.ui(
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

/// Before the first set is logged. Says what Records will hold, so the screen
/// reads as waiting rather than broken.
class _RecordsEmpty extends StatelessWidget {
  const _RecordsEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 32),
      decoration: BoxDecoration(
        borderRadius: AppRadii.rLg,
        border: Border.all(color: AppColors.cardLine),
      ),
      child: Column(
        children: [
          Text('No records yet.',
              style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Log a set and the first one lands here. Arc keeps each lift\'s best '
            'estimated 1RM and tells you the day you beat it.',
            textAlign: TextAlign.center,
            style: AppText.ui(
                size: 13.5,
                height: 1.5,
                weight: FontWeight.w500,
                color: AppColors.faint),
          ),
          const SizedBox(height: 18),
          ArcButton(
            label: 'Log a workout',
            icon: 'plus',
            onTap: () => Sheets.openLog(context),
          ),
        ],
      ),
    );
  }
}

/// Filters that match nothing. Names the number being withheld, so the user
/// knows the records are still there.
class _NoMatches extends StatelessWidget {
  final int hidden;
  final VoidCallback onClear;

  const _NoMatches({required this.hidden, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        children: [
          Text('Nothing matches these filters.',
              textAlign: TextAlign.center,
              style: AppText.ui(size: 15, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            hidden == 1 ? '1 record is hidden.' : 'All $hidden records are hidden.',
            textAlign: TextAlign.center,
            style: AppText.ui(
                size: 13, weight: FontWeight.w500, color: AppColors.faint),
          ),
          const SizedBox(height: 16),
          ArcButton(
            label: 'Clear filters',
            variant: BtnVariant.soft,
            size: BtnSize.sm,
            onTap: onClear,
          ),
        ],
      ),
    );
  }
}
