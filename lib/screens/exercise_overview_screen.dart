import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../sheets/pr_detail_sheet.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';

/// Exercise history and progression, for the user's own or a companion's lift.
class ExerciseOverviewScreen extends StatelessWidget {
  final String? exId;
  final ExerciseRecord? record;

  const ExerciseOverviewScreen({super.key, required String this.exId})
    : record = null;

  const ExerciseOverviewScreen.forRecord({
    super.key,
    required ExerciseRecord this.record,
  }) : exId = null;

  @override
  Widget build(BuildContext context) {
    final store = record == null ? context.watch<ArcStore>() : null;
    final current = record ?? store!.records[exId];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: 'Back',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).maybePop(),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: ArcIcon(
                            'chevL',
                            size: 28,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      current?.ex.name ?? 'Exercise',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui(
                        size: 21,
                        weight: FontWeight.w700,
                        letterSpacing: -0.21,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: current == null || current.best == null
                        ? Text(
                            'No progression for this exercise yet.',
                            style: AppText.ui(size: 14, color: AppColors.muted),
                          )
                        : record == null
                        ? PRDetailSheet(exId: exId!)
                        : PRDetailSheet.forRecord(record: record!),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
