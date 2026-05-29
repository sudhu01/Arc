import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../widgets/sheet.dart';
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

  static Future<void> openDay(BuildContext context, String date) {
    return showArcSheet(
      context: context,
      title: ArcData.fmtDate(date, 'long'),
      builder: (_) => DayDetailSheet(date: date),
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

  static Future<void> openAddExercise(BuildContext context) {
    return showArcSheet(
      context: context,
      builder: (_) => const AddExerciseSheet(),
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
