import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/arc_data.dart';
import '../data/muscle.dart';
import '../data/record_query.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/muscle_picker.dart';
import '../widgets/ui.dart';

/// Everything that decides which records the list shows, and in what order.
///
/// Commits live, like the Appearance sheet: there is no Apply, because a filter
/// you have to submit is a filter you cannot feel out. What the sheet covers,
/// the running count at the bottom reports — that line is the feedback the list
/// underneath would give if the sheet were not sitting on top of it.
///
/// The query lives in a notifier owned by the opener rather than in this
/// widget, so the Reset control up on the title row — which is built outside
/// this subtree — reads the same state the body writes.
class RecordsFilterSheet extends StatelessWidget {
  final ValueNotifier<RecordQuery> notifier;

  const RecordsFilterSheet({super.key, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();

    // Every exercise that has a record at all — the denominator, and the set
    // the group pills are checked against.
    final all = [
      for (final e in store.exercises)
        if (store.records[e.id]?.best != null) store.records[e.id]!,
    ];

    // A group nobody has a record in is shown but inert: it can only ever empty
    // the list, and finding that out costs a tap and a re-open.
    final empty = {
      for (final m in Muscle.values)
        if (!all.any((r) => r.ex.muscle == m)) m,
    };

    return ValueListenableBuilder<RecordQuery>(
      valueListenable: notifier,
      builder: (context, q, _) {
        void set(RecordQuery next) {
          if (next == q) return;
          HapticFeedback.selectionClick();
          notifier.value = next;
        }

        final (natural, flipped) = q.sort.orderLabels;
        final shown = q.apply(all).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _label('Sort by'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in RecordSort.values)
                  _ChoicePill(
                    label: s.label,
                    selected: q.sort == s,
                    onTap: () => set(q.copyWith(sort: s)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Segmented(
              options: [
                SegOption('natural', natural),
                SegOption('flipped', flipped),
              ],
              value: q.reversed ? 'flipped' : 'natural',
              onChanged: (v) => set(q.copyWith(reversed: v == 'flipped')),
            ),
            const SizedBox(height: 9),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                q.sort.note,
                style: AppText.ui(
                    size: 12.5,
                    height: 1.4,
                    weight: FontWeight.w500,
                    color: AppColors.faint),
              ),
            ),
            const SizedBox(height: 26),

            _label('Show'),
            Segmented(
              options: [
                for (final u in RecordUnit.values) SegOption(u.name, u.label),
              ],
              value: q.unit.name,
              onChanged: (v) => set(q.copyWith(
                  unit: RecordUnit.values.firstWhere((u) => u.name == v))),
            ),
            const SizedBox(height: 8),
            ArcSwitchRow(
              label: 'New records only',
              sub: 'Set in the last ${ArcData.newRecordDays} days — the same '
                  'window that earns a row its NEW tag.',
              value: q.newOnly,
              onChanged: (v) => set(q.copyWith(newOnly: v)),
            ),
            const SizedBox(height: 22),

            Row(
              children: [
                Expanded(
                  child: _label(q.muscles.isEmpty
                      ? 'Muscle groups'
                      : 'Muscle groups · ${q.muscles.length}'),
                ),
                if (q.muscles.isNotEmpty)
                  _TextAction(
                    label: 'All groups',
                    semanticLabel: 'Show every muscle group',
                    onTap: () => set(q.copyWith(muscles: const {})),
                  ),
              ],
            ),
            MusclePicker(
              selected: q.muscles,
              disabled: empty,
              onTap: (m) => set(q.toggleMuscle(m)),
            ),
            const SizedBox(height: 24),

            _Count(
              shown: shown,
              total: all.length,
              onClear: () => set(q.withoutFilters),
            ),
          ],
        );
      },
    );
  }
}

/// Returns the list to every record, strongest first. Sits on the sheet's title
/// row and appears only once there is something to undo.
class RecordsFilterReset extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const RecordsFilterReset({
    super.key,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      // 44 tall minimum per PRODUCT's touch-target floor; the pill itself is
      // smaller, and the constraint supplies the rest of the target.
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('Reset',
            style: AppText.ui(
                size: 13, weight: FontWeight.w600, color: AppColors.muted)),
      ),
    );

    // Reserved rather than removed: the title row keeps its height at every
    // text scale, so the sheet does not twitch the first time the user changes
    // something.
    if (!enabled) {
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: pill,
      );
    }

    return Semantics(
      button: true,
      label: 'Reset sort and filters',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: pill,
      ),
    );
  }
}

/// How much of the list survives the current query — the sheet's only feedback
/// while it covers the list it is filtering.
class _Count extends StatelessWidget {
  final int shown;
  final int total;
  final VoidCallback onClear;

  const _Count({
    required this.shown,
    required this.total,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (total == 0) return const SizedBox.shrink();

    if (shown == 0) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Nothing matches these filters.',
              style: AppText.ui(
                  size: 13, weight: FontWeight.w600, color: AppColors.muted),
            ),
          ),
          const SizedBox(width: 10),
          ArcButton(
            label: 'Clear filters',
            size: BtnSize.sm,
            variant: BtnVariant.soft,
            onTap: onClear,
          ),
        ],
      );
    }

    final figure = AppText.mono(size: 13.5, weight: FontWeight.w700);
    final word =
        AppText.ui(size: 13, weight: FontWeight.w500, color: AppColors.muted);

    return Text.rich(
      TextSpan(
        children: shown == total
            ? [
                TextSpan(text: '$total', style: figure),
                TextSpan(text: total == 1 ? ' record' : ' records', style: word),
              ]
            : [
                TextSpan(text: '$shown', style: figure),
                TextSpan(text: ' of ', style: word),
                TextSpan(text: '$total', style: figure),
                TextSpan(text: ' records', style: word),
              ],
      ),
      semanticsLabel: shown == total
          ? '$total records'
          : 'Showing $shown of $total records',
    );
  }
}

/// The pill vocabulary the muscle picker already speaks, for choices that are
/// not muscle groups: ink fill when chosen, never the accent — on this screen
/// the accent is spoken for by the records themselves.
class _ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoicePill({
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
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: Duration(
                milliseconds:
                    MediaQuery.disableAnimationsOf(context) ? 0 : 150),
            curve: Curves.easeOut,
            // Matches the muscle pills below it, which sit in the same sheet
            // and answer the same kind of question. Sized by a min-Row rather
            // than by `alignment`, which would make the pill swallow the whole
            // width the Wrap offers it.
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: selected ? AppColors.ink : AppColors.surface2,
              borderRadius: BorderRadius.circular(999),
              border:
                  Border.all(color: selected ? AppColors.ink : AppColors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppText.ui(
                    size: 14,
                    weight: FontWeight.w600,
                    color: selected ? AppColors.surface : AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Quiet inline action beside a section label.
class _TextAction extends StatelessWidget {
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  const _TextAction({
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(left: 12, bottom: 8),
            child: Text(label,
                style: AppText.ui(
                    size: 13,
                    weight: FontWeight.w600,
                    color: AppColors.accentStrong)),
          ),
        ),
      ),
    );
  }
}

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: AppText.ui(
          size: 11.5,
          weight: FontWeight.w700,
          color: AppColors.muted,
          letterSpacing: 0.5,
        ),
      ),
    );
