import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sheets/day_detail_sheet.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';

/// A dated workout has enough content and actions to occupy its own route.
class WorkoutScreen extends StatelessWidget {
  final String? date;
  final Session? session;
  final CompanionData? data;

  const WorkoutScreen({super.key, required String this.date})
    : session = null,
      data = null;

  const WorkoutScreen.forCompanion({
    super.key,
    required Session this.session,
    required CompanionData this.data,
  }) : date = null;

  @override
  Widget build(BuildContext context) {
    final store = session == null ? context.watch<ArcStore>() : null;
    final workout = session ?? store!.sessionForDate(date!);
    final workoutDate = date ?? session!.date;
    Exercise? exById(String id) =>
        data != null ? data!.exById(id) : store!.exById(id);

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
                    label: 'Back to workouts',
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
                      ArcData.fmtDate(workoutDate, 'long'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui(
                        size: 17.5,
                        weight: FontWeight.w700,
                        letterSpacing: -0.21,
                      ),
                    ),
                  ),
                  if (workout != null) ...[
                    if (!kIsWeb)
                      SheetIconButton(
                        icon: 'share',
                        size: 34,
                        semanticLabel: 'Share workout as an image',
                        onTap: () => Sheets.openShareWorkout(
                          context,
                          ses: workout,
                          exById: exById,
                        ),
                      ),
                    if (!kIsWeb) const SizedBox(width: 10),
                    CopyIconButton(
                      size: 44,
                      visualSize: 34,
                      semanticLabel: 'Copy workout',
                      text: () => workoutAsText(ses: workout, exById: exById),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: data == null
                        ? DayDetailSheet(date: date!)
                        : DayDetailSheet.forCompanion(
                            session: session!,
                            data: data!,
                          ),
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
