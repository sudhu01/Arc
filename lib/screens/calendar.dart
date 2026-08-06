import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
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
                  childAspectRatio: 1,
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
                  final grp =
                      ses == null ? null : ArcData.groupFromTitle(ses.title);
                  return Opacity(
                    opacity: future ? 0.32 : 1,
                    child: GestureDetector(
                      onTap: future ? null : () => Sheets.openDay(context, iso),
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
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
                            const SizedBox(height: 3),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ses != null
                                    ? AppColors.group(grp!)
                                    : Colors.transparent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final g in ArcData.groups) ...[
              GroupDot(g),
              const SizedBox(width: 6),
              Text(g,
                  style: AppText.ui(
                      size: 12, weight: FontWeight.w600, color: AppColors.muted)),
              const SizedBox(width: 16),
            ],
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
