import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/record_query.dart';
import '../data/store.dart';
import '../screens/exercise_overview_screen.dart';
import '../screens/workout_screen.dart';
import '../widgets/sheet.dart';
import 'appearance_sheet.dart';
import 'log_sheet.dart';
import 'add_exercise_sheet.dart';
import 'companion_progress_sheet.dart';
import 'companion_sheet.dart';
import 'muscle_colors_sheet.dart';
import 'muscle_review_sheet.dart';
import 'muscle_sheet.dart';
import 'notes_sheet.dart';
import 'records_filter_sheet.dart';
import 'share_workout_sheet.dart';

/// Central entry points for Arc's overlay sheets. Screens call these.
class Sheets {
  Sheets._();

  static Future<void> openPR(BuildContext context, String exId) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ExerciseOverviewScreen(exId: exId),
      ),
    );
  }

  /// Same screen as [openPR], for a record that isn't in the local store
  /// (a companion's). Read-only — no logging from here.
  static Future<void> openCompanionPR(
      BuildContext context, ExerciseRecord record) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ExerciseOverviewScreen.forRecord(record: record),
      ),
    );
  }

  static Future<void> openDay(BuildContext context, String date) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => WorkoutScreen(date: date)),
    );
  }

  /// Same screen as [openDay], for a companion's workout — read-only.
  static Future<void> openCompanionDay(
      BuildContext context, Session session, CompanionData data) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkoutScreen.forCompanion(session: session, data: data),
      ),
    );
  }

  /// What the user wrote about a workout. [readOnly] for a companion's.
  static Future<void> openNotes(
    BuildContext context, {
    required Session ses,
    bool readOnly = false,
  }) {
    return showArcSheet(
      context: context,
      full: true,
      scrollable: false,
      builder: (_) => NotesSheet(session: ses, readOnly: readOnly),
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
