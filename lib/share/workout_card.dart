import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/arc_data.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import 'claw_pattern.dart';

/// How an exercise's sets are written on the card.
///
/// The card steps down this ladder only when it has to. Nothing is ever
/// dropped: every exercise in the session appears on every card, and the set
/// count survives all three rungs.
enum _Density {
  /// One chip per set, exactly as the day sheet shows them.
  detail,

  /// Runs of identical sets collapse into one chip — `100 × 8` `×3`. Lossless,
  /// and on a poster it reads better than three copies of the same numbers.
  grouped,

  /// One chip for the whole exercise: its top set and how many there were.
  summary,
}

/// A set chip, resolved to the strings it will draw so the fitter and the
/// renderer can never disagree about how wide it is.
typedef _Chip = ({String head, List<String> drops, String? tail});

typedef _Item = ({Exercise ex, Entry entry});

/// The workout as a poster: the same date, name, exercises, sets and weights
/// the day sheet shows, laid out for a 4:5 export.
///
/// This is the text of [workoutAsText] given a face. It reads the theme through
/// the usual statics (`AppColors`, `AppText`), so whatever palette and accent
/// hue the user is on is what leaves the app — which is why the graphic is
/// painted here rather than composed from a shipped image.
///
/// Laid out at a fixed [cardWidth] × [cardHeight] and captured at 3× for a
/// 1080×1350 JPEG. Fixed, not responsive: the export must not depend on the
/// phone it was made on.
///
/// **The whole workout always fits.** A fixed canvas plus an unbounded number
/// of exercises means something has to give, and it is never the exercise list:
/// [_Fitter] searches type scale, one or two columns, and the [_Density] ladder
/// for the largest setting the session fits in, and the header keeps its full
/// size throughout so the poster's identity doesn't shrink with a long workout.
class ShareWorkoutCard extends StatelessWidget {
  const ShareWorkoutCard({
    super.key,
    required this.session,
    required this.exById,
  });

  final Session session;
  final Exercise? Function(String) exById;

  static const cardWidth = 360.0;
  static const cardHeight = 450.0;

  /// Capture scale. 360 × 450 at 3× lands exactly on 1080 × 1350.
  static const pixelRatio = 3.0;

  // Geometry, shared by the renderer and the fitter so the two can't disagree
  // about what fits.
  static const _outerPad = 13.0;
  static const _innerPadX = 20.0;
  static const _innerPadTop = 20.0;
  static const _innerPadBottom = 14.0;

  /// The card is drawn with a hairline border, which eats a pixel off each
  /// edge of the box the content actually gets.
  static const _border = 1.0;

  static const _contentW =
      cardWidth - 2 * _outerPad - 2 * _border - 2 * _innerPadX;
  static const _contentH = cardHeight -
      2 * _outerPad -
      2 * _border -
      _innerPadTop -
      _innerPadBottom;

  /// The box the claw is painted into, and where the content sits inside it.
  /// Used to work out which parts of the motif end up under text.
  static const _innerW = cardWidth - 2 * _outerPad;
  static const _innerH = cardHeight - 2 * _outerPad;
  static const _contentLeft = _border + _innerPadX;
  static const _contentTop = _border + _innerPadTop;

  // Header stack: eyebrow, title, meta row, rule. Never scaled — a twelve-
  // exercise session gets a tighter list, not a smaller title.
  static const _eyebrowToTitle = 7.0;
  static const _titleToMeta = 8.0;
  static const _metaToRule = 15.0;
  static const _ruleH = 1.5;
  static const _ruleToList = 15.0;

  /// A hair of slack so sub-pixel rounding in a text layout can never be the
  /// difference between fitting and overflowing a fixed canvas.
  static const _slack = 4.0;

  /// Gap between the two columns. Structural, so it doesn't scale with the
  /// type — a hairline gutter would read as a wrapping accident.
  static const _gutter = 16.0;

  /// Tracked, but only lightly: the wide letter-spacing this carried was
  /// paying for all-caps, and mixed case doesn't need it.
  static TextStyle get _eyebrowLabelStyle => AppText.mono(
          size: 12.075, weight: FontWeight.w700, color: AppColors.muted)
      .copyWith(letterSpacing: 0.3);
  static TextStyle get _titleStyle => AppText.ui(
      size: 33, weight: FontWeight.w700, height: 1.02, letterSpacing: -1.1);
  static TextStyle get _metaStyle =>
      AppText.ui(size: 12, weight: FontWeight.w500, color: AppColors.muted);

  @override
  Widget build(BuildContext context) {
    final totalSets = session.entries.fold<int>(0, (a, e) => a + e.sets.length);
    final meta = '$totalSets ${totalSets == 1 ? 'set' : 'sets'}';

    final year = ArcData.parseISO(session.date).year;
    final eyebrow = '${ArcData.fmtDate(session.date, 'long')} $year';

    final items = <_Item>[
      for (final e in session.entries)
        if (exById(e.exerciseId) case final ex?) (ex: ex, entry: e),
    ];

    final eyebrowH = _textHeight(eyebrow, _eyebrowLabelStyle, _contentW);
    final titleH =
        _textHeight(session.displayTitle, _titleStyle, _contentW, maxLines: 2);
    final metaH = _textHeight(meta, _metaStyle, _contentW);
    final headerH = eyebrowH +
        _eyebrowToTitle +
        titleH +
        _titleToMeta +
        metaH +
        _metaToRule +
        _ruleH +
        _ruleToList;

    final fitter = _Fitter(items, _contentH - headerH - _slack);
    final plan = fitter.solve();

    return MediaQuery(
      // A user at 200% system text must not get a distorted export — the
      // artboard is a fixed canvas, unlike every other surface in Arc.
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          width: cardWidth,
          height: cardHeight,
          color: AppColors.bg,
          padding: const EdgeInsets.all(_outerPad),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rLg,
              border: Border.all(color: AppColors.cardLine),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                ClawBackdrop(
                  zones: _textZones(
                    fitter: fitter,
                    plan: plan,
                    eyebrow: eyebrow,
                    meta: meta,
                    eyebrowH: eyebrowH,
                    titleH: titleH,
                    headerH: headerH,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      _innerPadX, _innerPadTop, _innerPadX, _innerPadBottom),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(eyebrow, style: _eyebrowLabelStyle),
                      const SizedBox(height: _eyebrowToTitle),
                      Text(
                        session.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _titleStyle,
                      ),
                      const SizedBox(height: _titleToMeta),
                      Text(meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _metaStyle),
                      const SizedBox(height: _metaToRule),
                      const _AccentRule(),
                      const SizedBox(height: _ruleToList),
                      // Centred in whatever's left, so a two-exercise workout
                      // sits in the middle of the card instead of hanging off
                      // the rule with a third of the poster empty beneath it.
                      // A full card has nothing spare, so this is a no-op there.
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [_body(items, plan)],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The exercise list: one or two fixed-width columns, filled in reading order
  /// so a workout still runs top-to-bottom and then across.
  Widget _body(List<_Item> items, _ListPlan plan) {
    final colW = plan.columnWidth;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < plan.columns; c++) ...[
          if (c > 0) const SizedBox(width: _gutter),
          SizedBox(
            width: colW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final i in plan.indicesIn(c, items.length)) ...[
                  if (i != plan.firstIn(c))
                    SizedBox(height: _Fitter.entryGap * plan.scale),
                  _entry(items[i], plan.chips[i], plan, colW),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _entry(_Item item, List<_Chip> chips, _ListPlan plan, double colW) {
    final s = plan.scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.ex.name,
          maxLines: plan.nameMaxLines,
          overflow: TextOverflow.ellipsis,
          style: _Fitter.nameStyle(s),
        ),
        SizedBox(height: _Fitter.nameToChips * s),
        Wrap(
          spacing: _Fitter.chipGap * s,
          runSpacing: _Fitter.chipGap * s,
          children: [for (final c in chips) _chip(c, s, colW)],
        ),
      ],
    );
  }

  /// One chip. A drop chain stays inside a single chip, because it was one set;
  /// a run of identical sets carries its count in [_Chip.tail] rather than
  /// repeating itself.
  Widget _chip(_Chip c, double s, double colW) {
    return ConstrainedBox(
      // Belt and braces: the fitter has already rejected any plan whose chips
      // are wider than the column, so this never bites — but it means no
      // arithmetic slip can put a numeral over the edge of the card.
      constraints: BoxConstraints(maxWidth: colW),
      child: Container(
        height: _Fitter.chipH * s,
        padding: EdgeInsets.symmetric(horizontal: _Fitter.chipPadX * s),
        // No `alignment` here: it would make the chip expand to the full width
        // Wrap offers, and every set would land on its own line.
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadii.sm * s),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(c.head,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _Fitter.chipStyle(s)),
            ),
            for (final d in c.drops) ...[
              SizedBox(width: _Fitter.dropSegGap * s),
              Icon(ArcIcons.byName('chevR'),
                  size: _Fitter.dropIconW * s, color: AppColors.faint),
              SizedBox(width: _Fitter.dropGap * s),
              Text(d, style: _Fitter.dropStyle(s)),
            ],
            if (c.tail case final tail?) ...[
              SizedBox(width: _Fitter.tailGap * s),
              Text(tail, style: _Fitter.tailStyle(s)),
            ],
          ],
        ),
      ),
    );
  }

  // ── Where text lands on the motif ────────────────────────────────────
  // The claw is as bold as the text allows, and how much text there is and how
  // far right it reaches changes with the layout the fitter picked. Rather than
  // guess a safe ceiling once, the card hands the painter the exact spot each
  // run of text occupies and lets it solve for the strongest accent that still
  // clears WCAG at every one of them. Chips are excluded: they carry an opaque
  // fill, so no numeral is ever on a band.

  List<ClawTextZone> _textZones({
    required _Fitter fitter,
    required _ListPlan plan,
    required String eyebrow,
    required String meta,
    required double eyebrowH,
    required double titleH,
    required double headerH,
  }) {
    final titleTop = _contentTop + eyebrowH + _eyebrowToTitle;
    final metaTop = titleTop + titleH + _titleToMeta;
    final listTop = _contentTop + headerH;

    // The top-right corner of a run of text is the strongest point of the ramp
    // it touches, so each zone is measured there.
    ClawTextZone zone(double width, double top, Color color, double ratio) => (
          reach: _reach(_contentLeft + math.min(width, _contentW), top),
          color: color,
          ratio: ratio,
        );

    return [
      zone(_textWidth(eyebrow, _eyebrowLabelStyle), _contentTop,
          AppColors.muted, 4.5),
      // The title is 33px bold, so it takes the large-text bar.
      zone(_textWidth(session.displayTitle, _titleStyle), titleTop,
          AppColors.ink, 3.0),
      zone(_textWidth(meta, _metaStyle), metaTop, AppColors.muted, 4.5),
      for (var c = 0; c < plan.columns; c++)
        (
          reach: _reach(
            _contentLeft +
                c * (plan.columnWidth + _gutter) +
                fitter.widestName(plan, c),
            listTop,
          ),
          color: AppColors.ink,
          ratio: 4.5,
        ),
    ];
  }

  /// Where a point sits on the motif's top-right-to-bottom-left ramp.
  static double _reach(double right, double top) =>
      (((1 - right / _innerW) + top / _innerH) / 2).clamp(0.0, 1.0);

  static double _textWidth(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  static double _textHeight(String text, TextStyle style, double maxWidth,
      {int maxLines = 1}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);
    final h = tp.height;
    tp.dispose();
    return h;
  }
}

// ── Fitting ────────────────────────────────────────────────────────────
// The canvas is fixed and the workout is not, so the card works out up front
// how to draw the whole thing. It measures with TextPainter rather than
// estimating, and it is free of randomness, so the same workout always exports
// the same image.

/// The layout the fitter settled on.
class _ListPlan {
  const _ListPlan({
    required this.density,
    required this.columns,
    required this.scale,
    required this.split,
    required this.nameMaxLines,
    required this.chips,
  });

  final _Density density;
  final int columns;

  /// Type scale for the list only. 1.0 is the designed size.
  final double scale;

  /// Index of the first item in the second column; equal to the item count
  /// when there is only one.
  final int split;

  final int nameMaxLines;

  /// Chips per item, in item order — resolved once so the renderer draws
  /// exactly what was measured.
  final List<List<_Chip>> chips;

  double get columnWidth =>
      (ShareWorkoutCard._contentW -
          (columns - 1) * ShareWorkoutCard._gutter) /
      columns;

  int firstIn(int column) => column == 0 ? 0 : split;

  Iterable<int> indicesIn(int column, int count) sync* {
    final from = firstIn(column);
    final to = column == 0 ? split : count;
    for (var i = from; i < to; i++) {
      yield i;
    }
  }

}

class _Fitter {
  _Fitter(this.items, this.budget);

  final List<_Item> items;

  /// Vertical space the list has, once the header has taken its share.
  final double budget;

  // Base metrics, at scale 1.0.
  static const nameSize = 13.5;
  static const nameLead = 1.2;
  static const chipTextSize = 12.0;
  static const tailTextSize = 11.0;
  static const chipH = 22.0;
  static const chipPadX = 9.0;
  static const chipGap = 6.0;
  static const nameToChips = 7.0;
  static const entryGap = 12.0;
  static const dropIconW = 9.0;
  static const dropGap = 3.0;
  static const dropSegGap = 4.0;
  static const tailGap = 5.0;

  /// Type scales tried, largest first. The step is fine enough that the card
  /// never gives up more size than it has to.
  ///
  /// The floor is a readability floor, not an arithmetic one: 0.78 puts the
  /// exercise names at 10.5px, which survives the trip through a 1080px JPEG
  /// into someone else's chat thread. Below that the card compresses how the
  /// sets are written instead of shrinking the type further.
  static const _scales = <double>[1.0, 0.96, 0.92, 0.88, 0.84, 0.80, 0.78];

  /// Only reached once the sets are already as terse as they get.
  static const _tightScales = <double>[0.74, 0.70, 0.66, 0.62, 0.58];

  static TextStyle nameStyle(double s) => AppText.ui(
      size: nameSize * s, weight: FontWeight.w600, height: nameLead);
  static TextStyle chipStyle(double s) =>
      AppText.mono(size: chipTextSize * s, weight: FontWeight.w600, height: 1);
  static TextStyle dropStyle(double s) => AppText.mono(
      size: chipTextSize * s,
      weight: FontWeight.w600,
      height: 1,
      color: AppColors.muted);

  /// The `×3` and `· 4 sets` counters. Smaller and fainter than the numbers
  /// they qualify, which is what stops `100 × 8 ×3` reading as one product.
  static TextStyle tailStyle(double s) => AppText.mono(
      size: tailTextSize * s,
      weight: FontWeight.w700,
      height: 1,
      color: AppColors.faint);

  final _widths = <String, double>{};
  final _heights = <String, double>{};

  /// Text advances scale linearly with font size, so every string is measured
  /// once at its base size and multiplied from there. Across three densities,
  /// two column counts and thirteen scales that is the difference between a
  /// few dozen layouts and a few thousand.
  double _w(String text, TextStyle base) => _widths.putIfAbsent(
        '${base.fontSize}|${base.fontWeight?.value}|$text',
        () => ShareWorkoutCard._textWidth(text, base),
      );

  /// How tall a name is in [colW] at [s].
  ///
  /// Laid out at the real size rather than scaled from a base measurement: a
  /// line's height is not exactly `fontSize × lead` once the type gets small,
  /// and on a twelve-row column that rounding adds up to more than [_slack] can
  /// absorb. Cached, so the ladder still costs a few hundred layouts rather
  /// than a few thousand.
  double _nameHeight(String name, double colW, double s, int maxLines) {
    return _heights.putIfAbsent(
      '$maxLines|${colW.toStringAsFixed(2)}|${s.toStringAsFixed(3)}|$name',
      () => ShareWorkoutCard._textHeight(name, nameStyle(s), colW,
          maxLines: maxLines),
    );
  }

  static String _fmtW(double w) =>
      w % 1 == 0 ? w.toInt().toString() : w.toString();

  static String _seg(Exercise ex, double weight, int reps) =>
      ex.isBodyweight ? '$reps reps' : '${_fmtW(weight)} × $reps';

  /// The chips for one exercise at a given density.
  List<_Chip> _chipsFor(_Item it, _Density density) {
    final sets = it.entry.sets;
    if (sets.isEmpty) return const [];

    _Chip of(WorkoutSet s, {String? tail}) => (
          head: _seg(it.ex, s.weight, s.reps),
          drops: [for (final d in s.drops) _seg(it.ex, d.weight, d.reps)],
          tail: tail,
        );

    switch (density) {
      case _Density.detail:
        return [for (final s in sets) of(s)];

      case _Density.grouped:
        final out = <_Chip>[];
        var runStart = 0;
        for (var i = 1; i <= sets.length; i++) {
          final same = i < sets.length && _identical(it.ex, sets[i], sets[i - 1]);
          if (same) continue;
          final n = i - runStart;
          out.add(of(sets[runStart], tail: n > 1 ? '×$n' : null));
          runStart = i;
        }
        return out;

      case _Density.summary:
        var top = sets.first;
        for (final s in sets) {
          final better = it.ex.isBodyweight
              ? s.reps > top.reps
              : s.weight > top.weight ||
                  (s.weight == top.weight && s.reps > top.reps);
          if (better) top = s;
        }
        return [
          (
            head: _seg(it.ex, top.weight, top.reps),
            drops: const <String>[],
            tail: sets.length > 1 ? '· ${sets.length} sets' : null,
          ),
        ];
    }
  }

  static bool _identical(Exercise ex, WorkoutSet a, WorkoutSet b) {
    if (a.weight != b.weight || a.reps != b.reps) return false;
    if (a.drops.length != b.drops.length) return false;
    for (var i = 0; i < a.drops.length; i++) {
      if (a.drops[i].weight != b.drops[i].weight ||
          a.drops[i].reps != b.drops[i].reps) {
        return false;
      }
    }
    return true;
  }

  double _chipWidth(_Chip c, double s) {
    var w = _w(c.head, chipStyle(1));
    for (final d in c.drops) {
      w += dropSegGap + dropIconW + dropGap + _w(d, dropStyle(1));
    }
    if (c.tail case final tail?) {
      w += tailGap + _w(tail, tailStyle(1));
    }
    return (w + 2 * chipPadX) * s;
  }

  /// Height of a wrapped chip row, and the widest single chip in it — the
  /// second is what tells the caller a plan is impossible rather than tall.
  ({double height, double widest}) _chipsBox(
      List<_Chip> chips, double colW, double s) {
    if (chips.isEmpty) return (height: 0, widest: 0);
    var rows = 1;
    var line = 0.0;
    var widest = 0.0;
    for (final c in chips) {
      final w = _chipWidth(c, s);
      widest = math.max(widest, w);
      final next = line == 0 ? w : line + chipGap * s + w;
      if (next > colW && line > 0) {
        rows++;
        line = w;
      } else {
        line = next;
      }
    }
    return (
      height: rows * chipH * s + (rows - 1) * chipGap * s,
      widest: widest,
    );
  }

  /// The best layout this session fits in.
  ///
  /// Order is the design decision. "The numbers are the interface", so the card
  /// spends everything else before it spends the numbers: at each rung it takes
  /// the width it has, then steps the type down to the readability floor, and
  /// only when a whole density has failed at every size does it write the sets
  /// more tersely. A short workout therefore lands on exactly the layout this
  /// card has always had — one column, full size, every set its own chip.
  _ListPlan solve() {
    for (final density in _Density.values) {
      for (final s in _scales) {
        for (final cols in const [1, 2]) {
          final plan = _attempt(density, cols, s);
          if (plan != null) return plan;
        }
      }
    }

    // Past the readability floor, with nothing left to compress.
    for (final s in _tightScales) {
      for (final cols in const [1, 2]) {
        final plan = _attempt(_Density.summary, cols, s);
        if (plan != null) return plan;
      }
    }

    return _forced();
  }

  _ListPlan? _attempt(
    _Density density,
    int columns,
    double s, {
    int maxLines = 2,
    bool relaxChips = false,
  }) {
    final colW = (ShareWorkoutCard._contentW -
            (columns - 1) * ShareWorkoutCard._gutter) /
        columns;

    final chips = [for (final it in items) _chipsFor(it, density)];
    final heights = <double>[];

    for (var i = 0; i < items.length; i++) {
      final box = _chipsBox(chips[i], colW, s);
      // A chip that can't fit the column has nowhere to wrap to. That's a
      // failed plan, not a tall one — except on the terminal rung, where the
      // chip is allowed to ellipsize because there is nothing left to try.
      if (box.widest > colW && !relaxChips) return null;
      heights.add(_nameHeight(items[i].ex.name, colW, s, maxLines) +
          nameToChips * s +
          box.height);
    }

    final split = _balance(heights, columns, s);
    if (_tallest(heights, split, s) > budget) return null;

    return _ListPlan(
      density: density,
      columns: columns,
      scale: s,
      split: split,
      nameMaxLines: maxLines,
      chips: chips,
    );
  }

  /// Where to break the list between two columns so neither runs long. Reading
  /// order is preserved — the split is a cut, not a deal.
  int _balance(List<double> heights, int columns, double s) {
    if (columns == 1) return heights.length;
    var best = 1;
    var bestTall = double.infinity;
    for (var k = 1; k < heights.length; k++) {
      final tall = _tallest(heights, k, s);
      if (tall < bestTall) {
        bestTall = tall;
        best = k;
      }
    }
    return heights.length < 2 ? heights.length : best;
  }

  double _tallest(List<double> heights, int split, double s) {
    double run(int from, int to) {
      var h = 0.0;
      for (var i = from; i < to; i++) {
        h += heights[i] + (i > from ? entryGap * s : 0);
      }
      return h;
    }

    return math.max(run(0, split), run(split, heights.length));
  }

  /// The terminal layout, for a session so long that even the bottom of the
  /// ladder overflows.
  ///
  /// One summary chip on a single-line name is the smallest an exercise can be
  /// written, so column height is near-linear in the type scale: the closed
  /// form gives the opening guess and the search creeps down from there until a
  /// real measurement fits. However many exercises arrive, this terminates with
  /// all of them on the card.
  _ListPlan _forced() {
    final columns = items.length > 1 ? 2 : 1;
    final rows = (items.length / columns).ceil();
    final unit = nameSize * nameLead + nameToChips + chipH;
    var s = (budget / (rows * unit + (rows - 1) * entryGap))
        .clamp(0.05, _tightScales.last);

    while (s > 0.05) {
      final plan = _attempt(_Density.summary, columns, s,
          maxLines: 1, relaxChips: true);
      if (plan != null) return plan;
      s -= 0.01;
    }

    return _attempt(_Density.summary, columns, 0.05,
            maxLines: 1, relaxChips: true) ??
        _ListPlan(
          density: _Density.summary,
          columns: columns,
          scale: 0.05,
          split: rows,
          nameMaxLines: 1,
          chips: [for (final it in items) _chipsFor(it, _Density.summary)],
        );
  }

  /// How far right the names in a column actually reach — the claw needs the
  /// real number, not the column width, or a card of short names would quiet
  /// the motif for nothing.
  double widestName(_ListPlan plan, int column) {
    final colW = plan.columnWidth;
    var widest = 0.0;
    for (final i in plan.indicesIn(column, items.length)) {
      widest = math.max(
          widest, math.min(colW, _w(items[i].ex.name, nameStyle(1)) * plan.scale));
    }
    return widest;
  }
}

/// The hairline under the header — accent at the left, dissolved by the right.
/// This and the group dot are the card's only chrome; the accent is spent here
/// and in the claw motif, nowhere else.
class _AccentRule extends StatelessWidget {
  const _AccentRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: ShareWorkoutCard._ruleH,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accentLine,
            AppColors.accentLine.withValues(alpha: 0.12),
          ],
        ),
      ),
    );
  }
}
