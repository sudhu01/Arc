import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../widgets/sheet.dart';
import '../widgets/ui.dart';
import 'appearance_sheet.dart';
import 'pr_detail_sheet.dart';
import 'day_detail_sheet.dart';
import 'log_sheet.dart';
import 'add_exercise_sheet.dart';
import 'companion_sheet.dart';

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
        // watched so the button goes away with the workout on a rest day
        final store = ctx.watch<ArcStore>();
        final ses = store.sessionForDate(date);
        if (ses == null) return const SizedBox.shrink();
        return CopyIconButton(
          semanticLabel: 'Copy workout',
          text: () => workoutAsText(ses: ses, exById: store.exById),
        );
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
      titleAction: (_) => CopyIconButton(
        semanticLabel: 'Copy workout',
        text: () => workoutAsText(ses: session, exById: data.exById),
      ),
      builder: (_) => DayDetailSheet.forCompanion(session: session, data: data),
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

  static Future<void> openAddExercise(BuildContext context,
      {String group = 'Push'}) {
    return showArcSheet(
      context: context,
      builder: (_) => AddExerciseSheet(initialGroup: group),
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
    return showArcSheet(
      context: context,
      title: 'Companions',
      builder: (_) => const CompanionSheet(),
    );
  }
}
