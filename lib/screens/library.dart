import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../body/body_view.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../sheets/add_exercise_sheet.dart' show ArcTextField;
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/exercise_row.dart';
import '../widgets/ui.dart';

/// Where exercises live. Two ways in, and they are peers rather than a feature
/// and its fallback:
///
/// **Body** is anatomy as navigation — spin the figure, tap what you trained.
/// It is also the only place the last fortnight's volume is visible as a shape
/// rather than a number.
///
/// **List** is the fast path: search, muscle-grouped sections, no waiting on a
/// renderer. It is what works mid-set with wet hands, and it is where the
/// screen lands by itself if the body can't start.
enum LibraryMode { body, list }

class Library extends StatefulWidget {
  /// Whether this tab is the one currently on screen. Forwarded to [BodyView],
  /// which stops its renderer when it isn't — a WebView keeps running whatever
  /// is inside it long after Flutter has stopped painting it.
  final bool visible;

  const Library({super.key, this.visible = true});

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  /// Web has no WebView to host the renderer, so the mode toggle isn't offered
  /// there at all — a control that can't do its job shouldn't be on screen.
  LibraryMode _mode = kIsWeb ? LibraryMode.list : LibraryMode.body;
  String _query = '';
  bool _reviewDismissed = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final unconfirmed = store.unconfirmedMuscleCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Exercises',
                      style: AppText.ui(
                          size: titleStyleSize,
                          weight: FontWeight.w700,
                          letterSpacing: -0.96)),
                  ArcButton(
                    label: 'New',
                    icon: 'plus',
                    size: BtnSize.sm,
                    variant: BtnVariant.soft,
                    onTap: () => Sheets.openAddExercise(context),
                  ),
                ],
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 16),
                Segmented(
                  options: const [
                    SegOption('body', 'Body'),
                    SegOption('list', 'List'),
                  ],
                  value: _mode == LibraryMode.body ? 'body' : 'list',
                  onChanged: (v) => setState(() => _mode =
                      v == 'body' ? LibraryMode.body : LibraryMode.list),
                ),
              ],
              if (unconfirmed > 0 && !_reviewDismissed) ...[
                const SizedBox(height: 14),
                _ReviewCard(
                  count: unconfirmed,
                  onDismiss: () => setState(() => _reviewDismissed = true),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _mode == LibraryMode.body
              ? BodyView(
                  visible: widget.visible,
                  onUnavailable: () {
                    if (mounted) setState(() => _mode = LibraryMode.list);
                  },
                )
              : _ListMode(
                  store: store,
                  query: _query,
                  controller: _searchController,
                  onQuery: (v) => setState(() => _query = v),
                ),
        ),
      ],
    );
  }
}

/// The library as a searchable, muscle-sectioned list.
class _ListMode extends StatelessWidget {
  final ArcStore store;
  final String query;
  final TextEditingController controller;
  final ValueChanged<String> onQuery;

  const _ListMode({
    required this.store,
    required this.query,
    required this.controller,
    required this.onQuery,
  });

  @override
  Widget build(BuildContext context) {
    final trainCount = <String, int>{};
    for (final s in store.sessions) {
      for (final e in s.entries) {
        trainCount[e.exerciseId] = (trainCount[e.exerciseId] ?? 0) + 1;
      }
    }

    final q = query.trim().toLowerCase();
    final matches = store.exercises.where((e) {
      if (q.isEmpty) return true;
      // Searching "chest" should find the chest lifts even when none of them
      // has the word in its name.
      return e.name.toLowerCase().contains(q) ||
          e.muscle.label.toLowerCase().contains(q);
    }).toList();

    final byMuscle = <Muscle, List<Exercise>>{};
    for (final e in matches) {
      (byMuscle[e.muscle] ??= []).add(e);
    }
    final sections = Muscle.values.where((m) => byMuscle[m] != null).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      children: [
        ArcTextField(
          controller: controller,
          hint: 'Search exercises',
          plain: true,
          prefix: ArcIcon('search', size: 18, color: AppColors.faint),
          onChanged: onQuery,
        ),
        const SizedBox(height: 16),
        if (store.exercises.isEmpty)
          const _LibraryEmpty()
        else if (sections.isEmpty)
          _NoMatches(query: query)
        else
          for (final m in sections) ...[
            _SectionHeader(
              muscle: m,
              count: byMuscle[m]!.length,
              onTap: () => Sheets.openMuscle(context, m),
            ),
            ExerciseGroupCard(rows: [
              for (final e in byMuscle[m]!)
                ExerciseRow(
                  exercise: e,
                  trained: trainCount[e.id] ?? 0,
                  best: store.records[e.id]?.best,
                  showMuscle: false,
                ),
            ]),
            const SizedBox(height: 18),
          ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final Muscle muscle;
  final int count;
  final VoidCallback onTap;

  const _SectionHeader(
      {required this.muscle, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${muscle.label}, $count exercises',
      // ExcludeSemantics drops the child's tap action, so the node needs its
      // own or it announces as a button and does nothing. This is also the
      // route a screen reader takes to the groups on the body's far side,
      // which it has no way to spin into view.
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.only(left: 2, right: 2),
            child: Row(
              children: [
                GroupDot(muscle.region),
                const SizedBox(width: 8),
                Text(muscle.label.toUpperCase(),
                    style: AppText.ui(
                        size: 12.5,
                        weight: FontWeight.w700,
                        color: AppColors.muted,
                        letterSpacing: 0.5)),
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
      ),
    );
  }
}

/// Offers the bulk re-sort after an upgrade. Dismissable, and gone for good
/// once every group is settled — an upgrade notice that outlives the upgrade is
/// just clutter.
class _ReviewCard extends StatelessWidget {
  final int count;
  final VoidCallback onDismiss;

  const _ReviewCard({required this.count, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.accentLine),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count exercise${count == 1 ? '' : 's'} '
                  '${count == 1 ? 'needs' : 'need'} a muscle group',
                  style: AppText.ui(size: 14.5, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Arc guessed from the names. Check its work.',
                  style: AppText.ui(
                      size: 12.5,
                      weight: FontWeight.w500,
                      color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ArcButton(
            label: 'Sort',
            size: BtnSize.sm,
            onTap: () => Sheets.openMuscleReview(context),
          ),
          const SizedBox(width: 4),
          SheetIconButton(
            icon: 'x',
            semanticLabel: 'Dismiss',
            onTap: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty();

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
          Text('No exercises yet.',
              style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Add the lifts you actually do. Arc files each one under a muscle '
            'group and starts tracking its estimated 1RM from the first set.',
            textAlign: TextAlign.center,
            style: AppText.ui(
                size: 13.5,
                height: 1.5,
                weight: FontWeight.w500,
                color: AppColors.faint),
          ),
          const SizedBox(height: 18),
          ArcButton(
            label: 'Add your first exercise',
            icon: 'plus',
            onTap: () => Sheets.openAddExercise(context),
          ),
        ],
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: Column(
        children: [
          Text('Nothing matches "${query.trim()}".',
              textAlign: TextAlign.center,
              style: AppText.ui(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 14),
          ArcButton(
            label: 'Create "${query.trim()}"',
            icon: 'plus',
            variant: BtnVariant.soft,
            size: BtnSize.sm,
            onTap: () => Sheets.openAddExercise(context),
          ),
        ],
      ),
    );
  }
}
