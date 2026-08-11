import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/record_query.dart';
import '../data/store.dart';
import '../widgets/sheet.dart';
import '../widgets/ui.dart';
import 'appearance_sheet.dart';
import 'pr_detail_sheet.dart';
import 'day_detail_sheet.dart';
import 'log_sheet.dart';
import 'add_exercise_sheet.dart';
import 'companion_progress_sheet.dart';
import 'companion_sheet.dart';
import 'muscle_colors_sheet.dart';
import 'muscle_review_sheet.dart';
import 'muscle_sheet.dart';
import 'records_filter_sheet.dart';
import 'share_workout_sheet.dart';

/// Central entry points for Arc's overlay sheets. Screens call these.
class Sheets {
  Sheets._();

  static Future<void> openPR(BuildContext context, String exId) {
    final name = context.read<ArcStore>().exById(exId)?.name ?? '';
    return showArcSheet(
      context: context,
      full: true,
      title: name,
      builder: (_) => PRDetailSheet(exId: exId),
    );
  }

  /// Same overlay as [openPR], for a record that isn't in the local store
  /// (a companion's). Read-only — no logging from here.
  static Future<void> openCompanionPR(
      BuildContext context, ExerciseRecord record) {
    return showArcSheet(
      context: context,
      full: true,
      title: record.ex.name,
      builder: (_) => PRDetailSheet.forRecord(record: record),
    );
  }

  static Future<void> openDay(BuildContext context, String date) {
    return showArcSheet(
      context: context,
      title: ArcData.fmtDate(date, 'long'),
      titleAction: (ctx) {
        // watched so the buttons go away with the workout on a rest day
        final store = ctx.watch<ArcStore>();
        final ses = store.sessionForDate(date);
        if (ses == null) return const SizedBox.shrink();
        return _dayActions(ctx, ses: ses, exById: store.exById);
      },
      builder: (_) => DayDetailSheet(date: date),
    );
  }

  /// Same overlay as [openDay], for a companion's workout — read-only.
  static Future<void> openCompanionDay(
      BuildContext context, Session session, CompanionData data) {
    return showArcSheet(
      context: context,
      title: ArcData.fmtDate(session.date, 'long'),
      titleAction: (ctx) =>
          _dayActions(ctx, ses: session, exById: data.exById),
      builder: (_) => DayDetailSheet.forCompanion(session: session, data: data),
    );
  }

  /// The pair of controls on a day sheet's title row: the workout as a graphic,
  /// and the workout as text. Shared by the user's own day and a companion's,
  /// since both take the same two things away from the same overlay.
  static Widget _dayActions(
    BuildContext context, {
    required Session ses,
    required Exercise? Function(String) exById,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Web has no share sheet to hand a file to, and a control that can't
        // do its job shouldn't be on screen.
        if (!kIsWeb) ...[
          SheetIconButton(
            icon: 'share',
            semanticLabel: 'Share workout as an image',
            onTap: () => openShareWorkout(context, ses: ses, exById: exById),
          ),
          // 3, not 8 — the button carries 5px of tap slop either side, so this
          // lands on the same visual gap as the one before the close button.
          const SizedBox(width: 3),
        ],
        CopyIconButton(
          semanticLabel: 'Copy workout',
          text: () => workoutAsText(ses: ses, exById: exById),
        ),
      ],
    );
  }

  /// Preview of the workout as a shareable graphic.
  static Future<void> openShareWorkout(
    BuildContext context, {
    required Session ses,
    required Exercise? Function(String) exById,
  }) {
    return showArcSheet(
      context: context,
      title: 'Share workout',
      builder: (_) => ShareWorkoutSheet(session: ses, exById: exById),
    );
  }

  static Future<void> openLog(
    BuildContext context, {
    String? date,
    String? prefillExId,
  }) {
    return showArcSheet(
      context: context,
      full: true,
      scrollable: false,
      builder: (_) => LogSheet(date: date, prefillExId: prefillExId),
    );
  }

  static Future<void> openAddExercise(BuildContext context, {Muscle? muscle}) {
    return showArcSheet(
      context: context,
      builder: (_) => AddExerciseSheet(initialMuscle: muscle),
    );
  }

  /// Everything filed under one muscle group. Opened by tapping the body, or a
  /// section header in the list.
  static Future<void> openMuscle(BuildContext context, Muscle muscle) {
    return showArcSheet(
      context: context,
      title: muscle.label,
      builder: (_) => MuscleSheet(muscle: muscle),
    );
  }

  /// How the Records list is ordered and narrowed.
  ///
  /// Applies live rather than on dismiss — [onChanged] fires on every tap — so
  /// the list is already correct behind the sheet when it closes. The query
  /// lives in a notifier here rather than inside the sheet because the Reset
  /// control sits on the title row, outside the sheet body's subtree, and the
  /// two have to agree.
  static Future<void> openRecordsFilter(
    BuildContext context, {
    required RecordQuery query,
    required ValueChanged<RecordQuery> onChanged,
  }) async {
    final notifier = ValueNotifier(query);
    void push() => onChanged(notifier.value);
    notifier.addListener(push);
    try {
      await showArcSheet(
        context: context,
        title: 'Sort & filter',
        titleAction: (_) => ValueListenableBuilder<RecordQuery>(
          valueListenable: notifier,
          builder: (_, q, _) => RecordsFilterReset(
            enabled: !q.isDefault,
            onTap: () => notifier.value = RecordQuery.initial,
          ),
        ),
        builder: (_) => RecordsFilterSheet(notifier: notifier),
      );
    } finally {
      notifier.removeListener(push);
      notifier.dispose();
    }
  }

  /// The thirteen group colours, repaintable one hue at a time.
  static Future<void> openMuscleColors(BuildContext context) {
    return showArcSheet(
      context: context,
      title: 'Group colors',
      titleAction: (_) => const MuscleColorsResetAll(),
      builder: (_) => const MuscleColorsSheet(),
    );
  }

  /// Bulk re-sort for groups Arc guessed during the muscle-taxonomy upgrade.
  static Future<void> openMuscleReview(BuildContext context) {
    return showArcSheet(
      context: context,
      title: 'Check muscle groups',
      builder: (_) => const MuscleReviewSheet(),
    );
  }

  static Future<void> openAppearance(BuildContext context) {
    return showArcSheet(
      context: context,
      title: 'Appearance',
      builder: (_) => const AppearanceSheet(),
    );
  }

  static Future<void> openCompanions(BuildContext context) {
    // Anyone who paired before companion alerts existed never met the prompt
    // that fires at pairing. This is the moment to make it: they are looking
    // at the people the alerts are about, which is the context a bare system
    // dialog cannot supply for itself. No-ops once permission is granted, and
    // for anyone with nobody to hear about yet.
    unawaited(context.read<ArcStore>().ensureAlertPermission());
    return showArcSheet(
      context: context,
      title: 'Companions',
      builder: (_) => const CompanionSheet(),
    );
  }

  /// A companion's progress, opened by public id.
  ///
  /// The route a notification tap takes: all it carries is who the alert was
  /// about, and this is where "Alice has a new PR record" leads when you want
  /// to see the lift behind it. Silently does nothing for a companion who has
  /// since been removed — a stale alert must not open an error.
  static Future<void> openCompanionProgress(
      BuildContext context, String publicId) async {
    final data = await context.read<ArcStore>().loadCompanionData(publicId);
    if (data == null || !context.mounted) return;
    await showArcSheet(
      context: context,
      full: true,
      title: data.companion.displayName,
      builder: (_) => CompanionProgressSheet(data: data),
    );
  }
}
