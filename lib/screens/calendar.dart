import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late int _y;
  late int _m;

  @override
  void initState() {
    super.initState();
    _y = ArcData.today.year;
    _m = ArcData.today.month; // 1-12
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final today = ArcData.today;

    final first = DateTime(_y, _m, 1);
    final startWd = ArcData.jsWeekday(first); // Sun=0
    final daysInMonth = DateTime(_y, _m + 1, 0).day;

    final cells = <int?>[];
    for (var i = 0; i < startWd; i++) {
      cells.add(null);
    }
    for (var d = 1; d <= daysInMonth; d++) {
      cells.add(d);
    }

    final monthSessions = store.sessions.where((s) {
      final dt = ArcData.parseISO(s.date);
      return dt.year == _y && dt.month == _m;
    }).toList();
    final monthSets = monthSessions.fold<int>(
        0, (a, s) => a + s.entries.fold<int>(0, (x, e) => x + e.sets.length));

    final atCurrent = _y == today.year && _m == today.month;

    void prev() => setState(() {
          if (_m == 1) {
            _y--;
            _m = 12;
          } else {
            _m--;
          }
        });
    void next() {
      final ny = _m == 12 ? _y + 1 : _y;
      final nm = _m == 12 ? 1 : _m + 1;
      if (!DateTime(ny, nm, 1).isAfter(DateTime(today.year, today.month, 1))) {
        setState(() {
          _y = ny;
          _m = nm;
        });
      }
    }

    Widget navBtn(String icon, VoidCallback onTap, {bool dim = false}) => Opacity(
          opacity: dim ? 0.3 : 1,
          child: GestureDetector(
            onTap: dim ? null : onTap,
            child: Container(
              width: 36,
              height: 36,
              decoration:
                  BoxDecoration(color: AppColors.surface2, shape: BoxShape.circle),
              child: Icon(ArcIcons.byName(icon), size: 18, color: AppColors.ink),
            ),
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
      children: [
        Text('History',
            style: AppText.ui(
                size: titleStyleSize, weight: FontWeight.w700, letterSpacing: -0.96)),
        const SizedBox(height: 16),
        Row(
          children: [
            StatTile(
                label: 'Workouts',
                value: '${monthSessions.length}',
                sub: 'this month'),
            const SizedBox(width: 10),
            StatTile(
                label: 'Total sets', value: '$monthSets', sub: 'this month'),
          ],
        ),
        const SizedBox(height: 18),
        ArcCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  navBtn('chevL', prev),
                  Text('${ArcData.monthsLong[_m - 1]} $_y',
                      style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
                  navBtn('chevR', next, dim: atCurrent),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                    Expanded(
                      child: Center(
                        child: Text(d,
                            style: AppText.ui(
                                size: 11,
                                weight: FontWeight.w700,
                                color: AppColors.faint)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                  // Taller than wide. Seven columns fix the width, and the dots
                  // stack two to a row, so the space a day needs is vertical:
                  // at 1:1 a three-row cluster had to shrink to a speck to fit
                  // under the numeral.
                  childAspectRatio: 0.76,
                ),
                itemCount: cells.length,
                itemBuilder: (context, i) {
                  final d = cells[i];
                  if (d == null) return const SizedBox.shrink();
                  final dt = DateTime(_y, _m, d);
                  final iso = ArcData.iso(dt);
                  final ses = store.sessionForDate(iso);
                  final isToday = iso == ArcData.iso(today);
                  final future = dt.isAfter(today);
                  final muscles = ses == null
                      ? const <Muscle>[]
                      : ArcData.sessionMuscles(ses, store.exById);
                  // Only for a session whose exercises this device can't
                  // resolve: the coarse region, read off the title, so the day
                  // still carries a dot rather than passing for a rest day.
                  final fallback = ses == null || muscles.isNotEmpty
                      ? null
                      : ArcData.sessionGroup(ses, store.exById);
                  return Semantics(
                    button: !future,
                    label: _dayLabel(
                        iso: iso,
                        isToday: isToday,
                        future: future,
                        session: ses,
                        muscles: muscles,
                        fallbackRegion: fallback),
                    onTap: future ? null : () => Sheets.openDay(context, iso),
                    child: ExcludeSemantics(
                      child: Opacity(
                        opacity: future ? 0.32 : 1,
                        child: GestureDetector(
                          onTap:
                              future ? null : () => Sheets.openDay(context, iso),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            decoration: BoxDecoration(
                              color: ses != null
                                  ? AppColors.surface2
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isToday
                                    ? AppColors.accent
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            // The numeral sits at a fixed height and the dots
                            // take everything under it, so a day that stacks
                            // three rows of them never pushes its number off
                            // the line its whole week is reading on.
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
                              child: Column(
                                children: [
                                  Text('$d',
                                      style: AppText.mono(
                                          size: 13,
                                          weight: ses != null
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: ses != null
                                              ? AppColors.ink
                                              : AppColors.muted)),
                                  const SizedBox(height: 2),
                                  Expanded(
                                    child: _DayDots(
                                        muscles: muscles,
                                        fallbackRegion: fallback),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// What a day cell announces, in place of a number and a colour.
///
/// The grid is thirty-odd cells of bare numerals; a screen reader walking it
/// hears "4", "5", "6" and never learns which of them were training days, since
/// that is carried by a dot with no text at all. So the cell speaks for itself:
/// the date, then the workout and the groups it trained, in the same words the
/// day sheet uses when it opens.
String _dayLabel({
  required String iso,
  required bool isToday,
  required bool future,
  required Session? session,
  required List<Muscle> muscles,
  required String? fallbackRegion,
}) {
  final date = isToday ? 'Today' : ArcData.fmtDate(iso, 'long');
  // A day that hasn't arrived is not a rest day — it is nothing yet, and the
  // cell is dimmed and inert to say so.
  if (future) return date;
  if (session == null) return '$date, rest day';
  final groups = muscles.isNotEmpty
      ? muscles.map((m) => m.label).join(', ')
      : (fallbackRegion ?? '');
  return [date, session.displayTitle, if (groups.isNotEmpty) groups].join(', ');
}

/// The colour signature of one day: a dot per muscle group the session trained.
///
/// The fine tier, not the coarse one, and no key under the grid to decode it.
/// These are the colours the user assigned in the palette and reads all day on
/// exercise rows and record cards — a month of them is a month of the same
/// vocabulary, so the calendar has nothing of its own left to teach. What a
/// legend could never say is the part that now shows: a session is rarely one
/// thing, and "chest and triceps" reads off the grid as two dots rather than
/// collapsing into whichever group happened to have more lifts.
///
/// Two to a row, wrapping downward — a pair, then a pair under it, an odd last
/// dot centred beneath its row. Seven columns fix how wide a day can be, so
/// laying groups out along that axis is what forced them to shrink; stacking
/// spends the axis the cell can actually afford, and holds every dot at the same
/// size whether a day trained one group or six.
///
/// The cluster still scales as one unit if a day out-runs even that — the
/// unusual session that touches nine or ten groups — rather than dropping any.
/// Nothing here is allowed to overflow the cell it sits in.
class _DayDots extends StatelessWidget {
  const _DayDots({required this.muscles, this.fallbackRegion});

  final List<Muscle> muscles;

  /// Drawn only when [muscles] is empty on a day that does hold a session —
  /// exercises this device hasn't synced. The coarse region is all that is
  /// knowable there, and one region dot is closer to the truth than no dot.
  final String? fallbackRegion;

  static const _size = 6.0;

  /// Loose enough that a pair reads as two things rather than a dash. The rows
  /// sit tighter than the columns so the cluster reads down the cell.
  static const _gap = 3.0;
  static const _rowGap = 2.0;

  @override
  Widget build(BuildContext context) {
    final dots = muscles.isNotEmpty
        ? [for (final m in muscles) MuscleDot(m, size: _size)]
        : [
            if (fallbackRegion != null) GroupDot(fallbackRegion!, size: _size),
          ];
    if (dots.isEmpty) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < dots.length; i += 2) ...[
            if (i != 0) const SizedBox(height: _rowGap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                dots[i],
                if (i + 1 < dots.length) ...[
                  const SizedBox(width: _gap),
                  dots[i + 1],
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
