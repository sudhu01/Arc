import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/cardio.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/charts.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

class PRDetailSheet extends StatelessWidget {
  /// Exercise to look up in the user's own store. Null when [record] is given.
  final String? exId;

  /// A record handed in directly — a companion's, which lives outside the
  /// store. Read-only: the "Log" action is dropped.
  final ExerciseRecord? record;

  const PRDetailSheet({super.key, required String this.exId}) : record = null;

  /// Read-only view of a record that isn't the user's own (companion progress).
  const PRDetailSheet.forRecord({
    super.key,
    required ExerciseRecord this.record,
  }) : exId = null;

  @override
  Widget build(BuildContext context) {
    final store = record == null ? context.watch<ArcStore>() : null;
    final rec = record ?? store!.records[exId];
    if (rec == null || rec.best == null) return const SizedBox.shrink();
    final ex = rec.ex;
    final isBw = ex.isBodyweight;
    final isCardio = ex.isCardio;
    final kind = ex.cardio;
    final hist = rec.history;
    final best = rec.best!;

    // Benchmark bests need the raw sessions, which only the store has — a
    // companion's record arrives without them, so their sheet shows the trend
    // and the log and skips this section rather than showing an empty one.
    final marks = store == null
        ? const <({Benchmark mark, RecordPoint point})>[]
        : ArcData.benchmarkBests(exId!, store.sessions, ex);

    /// Seconds per kilometre — what the cardio chart plots.
    ///
    /// Lower is better, so the line falls as the runner improves. That is the
    /// right way round: it is what every running app draws, and it is the shape
    /// a pace *is*. The delta beside the header flips to match, so a falling
    /// line still reads as the win it is.
    double paceOf(RecordPoint h) =>
        (h.dist ?? 0) <= 0 || (h.secs ?? 0) <= 0
            ? 0
            : h.secs! / (h.dist! / 1000);
    double rateOf(RecordPoint h) =>
        (h.secs ?? 0) <= 0 ? 0 : (h.dist ?? 0) / (h.secs! / 60);
    final maxWeight = hist.isEmpty
        ? 0.0
        : hist.map((h) => h.weight).reduce((a, b) => a > b ? a : b);
    final totalSets = hist.fold<int>(0, (a, h) => a + h.sets);
    final totalCardioSecs = hist.fold<int>(0, (a, h) => a + (h.totalSecs ?? 0));
    final furthest = hist.isEmpty
        ? 0.0
        : hist.map((h) => h.dist ?? 0).fold<double>(0, (a, b) => a > b ? a : b);
    // Gain mirrors the chart below: reps for bodyweight, max weight otherwise.
    final num gain = hist.length > 1
        ? (isBw
            ? hist.last.reps - hist.first.reps
            : hist.last.maxWeight - hist.first.maxWeight)
        : 0;

    // Improvement over the whole history, in the direction that counts: pace
    // dropping, or floors-per-minute rising.
    final double cardioGain = !isCardio || hist.length < 2
        ? 0
        : kind.countsFloors
            ? rateOf(hist.last) - rateOf(hist.first)
            : paceOf(hist.first) - paceOf(hist.last);

    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The sheet's own title row supplies the gap above a first element;
        // this tops it up to the 16 everything below the hero is spaced on.
        const SizedBox(height: 6),

        // hero number
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: AppRadii.rLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isCardio
                    ? (kind.countsFloors ? 'BEST RATE' : 'BEST PACE')
                    : isBw
                        ? 'BEST SET'
                        : 'ESTIMATED 1RM',
                style: AppText.ui(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: AppColors.accentStrong,
                  letterSpacing: 0.75,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    isCardio
                        ? bestCardioValue(best, kind)
                        : isBw
                            ? '${best.reps}'
                            : ArcData.fmtScore(best.score),
                    style: AppText.mono(size: 52, weight: FontWeight.w700, height: 1),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      isCardio
                          ? (kind.countsFloors ? 'floors/min' : '/km')
                          : isBw
                              ? 'reps'
                              : 'kg',
                      style: AppText.ui(
                          size: 18,
                          weight: FontWeight.w700,
                          color: AppColors.accentStrong)),
                ],
              ),
              // The distance that earned it. The best pace is whichever block
              // ran quickest, which is usually the shortest — without this the
              // hero could be a two-minute burst wearing a 5 km's clothes.
              if (isCardio && bestCardioContext(best, kind).isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'over ${bestCardioContext(best, kind)}'
                  '${(best.level ?? 0) > 0 && kind.hasModifier ? ' · ${cardioSetLine(null, null, best.level, kind)}' : ''}',
                  style: AppText.ui(
                      size: 13,
                      weight: FontWeight.w600,
                      color: AppColors.accentStrong),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // trend chart
        Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadii.rLg,
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                      isCardio
                          ? (kind.countsFloors
                              ? 'Floors per minute'
                              : 'Pace per session')
                          : isBw
                              ? 'Reps over time'
                              : 'Max weight per session',
                      style: AppText.ui(size: 13, weight: FontWeight.w600)),
                  if (isCardio && cardioGain > 0)
                    Row(
                      children: [
                        // A faster pace is a *smaller* number, so the arrow
                        // points down while the colour still says "good". The
                        // glyph follows the number, the colour follows the
                        // meaning, and a runner reads both correctly.
                        ArcIcon(kind.countsFloors ? 'arrowUp' : 'arrowDown',
                            size: 13, color: AppColors.up),
                        const SizedBox(width: 3),
                        Text(
                            kind.countsFloors
                                ? '+${cardioGain.toStringAsFixed(1)} /min'
                                : '−${formatDuration(cardioGain.round())} /km',
                            style: AppText.ui(
                                size: 12.5,
                                weight: FontWeight.w700,
                                color: AppColors.up)),
                      ],
                    )
                  else if (!isCardio && gain > 0)
                    Row(
                      children: [
                        ArcIcon('arrowUp', size: 13, color: AppColors.up),
                        const SizedBox(width: 3),
                        Text('+${isBw ? gain : fmtW(gain.toDouble())} ${isBw ? 'reps' : 'kg'}',
                            style: AppText.ui(
                                size: 12.5,
                                weight: FontWeight.w700,
                                color: AppColors.up)),
                      ],
                    ),
                ],
              ),
              ProgressChart(
                points: [
                  for (final h in hist)
                    ProgressPoint(
                        ArcData.parseISO(h.date),
                        isCardio
                            ? (kind.countsFloors ? rateOf(h) : paceOf(h))
                            : isBw
                                ? h.reps.toDouble()
                                : h.maxWeight),
                ],
                unit: isCardio
                    ? (kind.countsFloors ? 'floors/min' : 'min/km')
                    : isBw
                        ? 'reps'
                        : 'kg',
                // Without this the pace axis reads "272" and "290" — seconds,
                // which is not a unit anybody paces in.
                formatValue: isCardio && !kind.countsFloors
                    ? (v) => formatDuration(v.round())
                    : null,
                height: 150,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // stats row
        Row(
          children: [
            if (isCardio) ...[
              StatTile(
                  label: 'Total time',
                  value: '${(totalCardioSecs / 60).round()}',
                  unit: 'min'),
              const SizedBox(width: 10),
              StatTile(label: 'Sessions', value: '${hist.length}'),
              const SizedBox(width: 10),
              StatTile(
                  label: 'Furthest',
                  value: formatDistance(furthest, kind).$1,
                  unit: formatDistance(furthest, kind).$2),
            ] else ...[
              if (!isBw) ...[
                StatTile(
                    label: 'Top weight', value: fmtW(maxWeight), unit: 'kg'),
                const SizedBox(width: 10),
              ],
              StatTile(label: 'Sessions', value: '${hist.length}'),
              const SizedBox(width: 10),
              StatTile(label: 'Total sets', value: '$totalSets'),
            ],
          ],
        ),
        const SizedBox(height: 16),

        // Best efforts at the standard distances.
        //
        // The pace above is won by whichever block ran quickest, and that is
        // almost always the shortest one — a real answer to "how fast am I",
        // but not to "am I getting faster over the distances I actually run".
        // These are: each one is a plain fact about a distance the user has
        // covered, needs no formula anyone has to trust, and is directly
        // comparable to the same number six months from now.
        if (marks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Text('BEST EFFORTS',
                style: AppText.ui(
                    size: 13,
                    weight: FontWeight.w700,
                    color: AppColors.muted,
                    letterSpacing: 0.5)),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rLg,
              border: Border.all(color: AppColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < marks.length; i++)
                  _BenchmarkRow(
                    label: marks[i].mark.label,
                    time: formatDuration(marks[i].point.secs!),
                    pace: formatPace(
                        marks[i].mark.metres, marks[i].point.secs!),
                    date: marks[i].point.date,
                    showDivider: i != marks.length - 1,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // progression log
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
          child: Text('PROGRESSION',
              style: AppText.ui(
                  size: 13,
                  weight: FontWeight.w700,
                  color: AppColors.muted,
                  letterSpacing: 0.5)),
        ),
        ClipRRect(
          borderRadius: AppRadii.rMd,
          child: Column(
            children: [
              for (var i = hist.length - 1; i >= 0; i--)
                _ProgressRow(
                  point: hist[i],
                  isBw: isBw,
                  isPR: hist[i].score == best.score && hist[i].date == best.date,
                  showDivider: i != 0,
                  kind: isCardio ? kind : null,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (exId != null)
          ArcButton(
            label: 'Log ${ex.name}',
            icon: 'plus',
            full: true,
            onTap: () {
              Navigator.of(context).maybePop();
              Future.delayed(const Duration(milliseconds: 180), () {
                if (context.mounted) {
                  Sheets.openLog(context, prefillExId: exId);
                }
              });
            },
          ),
      ],
    );
  }
}

/// One benchmark distance and the best time set over it.
///
/// The time leads because that is the record; the pace follows because that is
/// how it compares to every other distance on the list.
class _BenchmarkRow extends StatelessWidget {
  final String label;
  final String time;
  final String pace;
  final String date;
  final bool showDivider;

  const _BenchmarkRow({
    required this.label,
    required this.time,
    required this.pace,
    required this.date,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, $time, $pace per kilometre, ${ArcData.relDate(date)}',
      excludeSemantics: true,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Text(label,
                      style: AppText.ui(size: 13.5, weight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Text(time,
                    style: AppText.mono(size: 17, weight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text('$pace /km',
                    style: AppText.ui(
                        size: 12.5,
                        weight: FontWeight.w500,
                        color: AppColors.muted)),
                const Spacer(),
                Text(ArcData.relDate(date),
                    style: AppText.ui(
                        size: 12,
                        weight: FontWeight.w500,
                        color: AppColors.faint)),
              ],
            ),
          ),
          if (showDivider) Container(height: 1, color: AppColors.line),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final RecordPoint point;
  final bool isBw;
  final bool isPR;
  final bool showDivider;

  /// Null on a strength lift. Present makes the row read the cardio way.
  final CardioKind? kind;

  const _ProgressRow({
    required this.point,
    required this.isBw,
    required this.isPR,
    required this.showDivider,
    this.kind,
  });

  @override
  Widget build(BuildContext context) {
    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(ArcData.fmtDate(point.date),
                      style: AppText.ui(
                          size: 13.5,
                          weight: FontWeight.w500,
                          color: AppColors.muted)),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    kind != null
                        ? cardioSetLine(
                            point.secs, point.dist, point.level, kind!)
                        : isBw
                            ? '${point.reps} reps'
                            : '${fmtW(point.weight)} × ${point.reps}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(size: 14.5, weight: FontWeight.w600),
                  ),
                ),
                if (isPR) ...[
                  const SizedBox(width: 8),
                  ArcIcon('medal', size: 15, color: AppColors.accentStrong),
                ],
                const Spacer(),
                if (kind != null)
                  Text(
                      '${formatRate(point.dist ?? 0, point.secs ?? 0, kind!).$1}'
                      '${kind!.countsFloors ? '' : ' /km'}',
                      style: AppText.mono(
                          size: 13, weight: FontWeight.w500, color: AppColors.faint))
                else if (!isBw)
                  Text('${ArcData.fmtScore(point.score)} 1RM',
                      style: AppText.mono(
                          size: 13, weight: FontWeight.w500, color: AppColors.faint)),
              ],
            ),
          ),
          if (showDivider) Container(height: 1, color: AppColors.line),
        ],
      ),
    );
  }
}
