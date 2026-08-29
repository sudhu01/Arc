// Cardio's measure vocabulary.
//
// Strength work is two numbers — weight and reps — and Arc's whole derived
// layer is built on them. Cardio has neither, but it is not a different kind of
// thing: a set of eight 100 m sprints has exactly the shape of eight sets of
// 225 × 5, and a thirty-minute treadmill block is that same shape with one set
// in it. So cardio reuses the set list rather than growing a parallel one, and
// what changes is only which measures a set carries.
//
// Three slots, the same three for every activity:
//
//   time      the spine — every cardio set has one
//   distance  metres, or floors on a stepmill
//   modifier  the machine's intensity dial, and the closest thing cardio has
//             to load: incline on a treadmill, resistance on a bike
//
// Speed and pace are *derived* from the first two and never entered, so there
// is no third number that can disagree with the others.
//
// What varies per activity is the label, unit and range of the modifier — not
// the shape of the form. [CardioKind] is that variation, and it is the only
// per-activity branch in the codebase.

/// What kind of cardio an exercise is, and therefore what its third measure
/// means.
///
/// Chosen once when the exercise is created, not per session: "Treadmill" is a
/// [run] forever. The cost is one exercise per machine; the saving is that the
/// log sheet never has to ask a question mid-workout.
enum CardioKind {
  /// Treadmill, running, sprints, incline walking. The only kind whose
  /// modifier is a real physical load rather than a machine's own scale —
  /// which is why it is the only one [gradeFactor] applies to.
  run('run', 'Run', 'Incline', '%', 20, 0.5, 1),

  /// Elliptical, bike, spin, rower, ski erg. Distance is whatever the console
  /// says it is; resistance is an arbitrary scale that means nothing off this
  /// machine.
  machine('machine', 'Machine', 'Resistance', '', 25, 1, 0),

  /// StairMaster, stepmill. Counts floors rather than distance.
  climb('climb', 'Climb', 'Level', '', 25, 1, 0),

  /// Jump rope, swimming, rucking, anything outdoors. Time and distance only.
  open('open', 'Other', null, '', 0, 0, 0);

  const CardioKind(
    this.id,
    this.label,
    this.modifierLabel,
    this.modifierSuffix,
    this.modifierMax,
    this.modifierStep,
    this.modifierDecimals,
  );

  /// Stable string for the database and the sync payload. Never prettify.
  final String id;

  /// What the picker calls this.
  final String label;

  /// Null when the kind has no third measure — the modifier control is then
  /// never offered.
  final String? modifierLabel;

  final String modifierSuffix;
  final double modifierMax;
  final double modifierStep;
  final int modifierDecimals;

  bool get hasModifier => modifierLabel != null;

  /// Stairs are counted, not measured. Everything else covers ground.
  bool get countsFloors => this == CardioKind.climb;

  static CardioKind? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final k in CardioKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// What an unrecognised or absent kind reads as — a row written by a future
  /// build, or a companion on a version that predates one of these.
  static const fallback = CardioKind.open;
}

/// How much harder a grade makes the same distance.
///
/// Roughly 3% more effort per 1% of grade is the standard running
/// approximation, and it is what makes incline the *load* of a treadmill run
/// rather than a note about it: a 5 km at 3% correctly outranks the same 5 km
/// flat. Clamped at 15% because the approximation is linear and the real curve
/// is not — beyond that it would credit a hike as a sprint.
///
/// Only [CardioKind.run] uses this. A bike's resistance number is the
/// manufacturer's invention and cannot be converted into anything.
double gradeFactor(CardioKind kind, double? level) {
  if (kind != CardioKind.run || level == null || level <= 0) return 1;
  return 1 + 0.03 * (level > 15 ? 15 : level);
}

// ── Formatting ──────────────────────────────────────────────────────

/// `m:ss`, or `h:mm:ss` once there is an hour to show.
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// A duration as a screen reader should say it. `27:40` is read out as "twenty
/// seven colon forty" otherwise, which is not a time.
String spokenDuration(int seconds) {
  if (seconds <= 0) return 'not set';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final parts = <String>[
    if (h > 0) '$h hour${h == 1 ? '' : 's'}',
    if (m > 0) '$m minute${m == 1 ? '' : 's'}',
    if (s > 0) '$s second${s == 1 ? '' : 's'}',
  ];
  return parts.join(' ');
}

/// Reads a duration back out of what someone might reasonably type: `30:00`,
/// `1:47`, `1:02:30`, or a bare number.
///
/// A bare number is seconds — the reading a sprint repeat wants. The control
/// this backs never *displays* a bare number, so the ambiguity only exists for
/// someone deliberately typing over it, and seconds is what they mean when they
/// do.
int? parseDuration(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (t.contains(':')) {
    final parts = t.split(':');
    if (parts.length > 3) return null;
    var total = 0;
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || v < 0) return null;
      total = total * 60 + v;
    }
    return total;
  }
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return v.round();
}

/// The distance a set covered, as a value and its unit.
///
/// Metres below a kilometre and kilometres above it, so one "Treadmill"
/// exercise reads naturally for both a 400 m repeat and a 5 km run without the
/// user ever choosing a unit. Metres are what gets stored either way.
(String, String) formatDistance(double metres, CardioKind kind) {
  if (kind.countsFloors) {
    final f = metres.round();
    return (f.toString(), f == 1 ? 'floor' : 'floors');
  }
  if (metres < 1000) return (metres.round().toString(), 'm');
  final km = metres / 1000;
  var s = km >= 100 ? km.toStringAsFixed(1) : km.toStringAsFixed(2);
  // Every trailing zero, not just one: a flat 3 km formats as "3.00" and has
  // to come back as "3", not "3.0".
  if (s.contains('.')) {
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return (s, 'km');
}

/// The step a distance control should move by at [metres] — 10 m while the
/// numbers read in metres, 50 m once they read in kilometres. One control, two
/// registers, no mode switch.
double distanceStep(double metres, CardioKind kind) {
  if (kind.countsFloors) return 1;
  return metres < 1000 ? 10 : 50;
}

/// The step a duration control should move by at [seconds].
///
/// Sprints tick in seconds and long runs tick in minutes, from the same pair of
/// buttons: five seconds under a minute, thirty under ten minutes, a minute
/// above. Holding + on a treadmill block does not take fifty presses, and
/// nudging a 12-second repeat does not overshoot it.
int durationStep(int seconds) {
  if (seconds < 60) return 5;
  if (seconds < 600) return 30;
  return 60;
}

/// Pace as `m:ss` per kilometre. This is the number a runner thinks in, which
/// is why it is what gets shown — even though speed is what gets *stored* as
/// the score.
String formatPace(double metres, int seconds) {
  if (metres <= 0 || seconds <= 0) return '—';
  final secPerKm = seconds / (metres / 1000);
  if (!secPerKm.isFinite || secPerKm > 359999) return '—';
  return formatDuration(secPerKm.round());
}

/// Speed in km/h, one decimal.
String formatSpeed(double metres, int seconds) {
  if (metres <= 0 || seconds <= 0) return '—';
  return (metres / seconds * 3.6).toStringAsFixed(1);
}

/// Floors per minute — the only kind where pace makes no sense.
String formatClimbRate(double floors, int seconds) {
  if (floors <= 0 || seconds <= 0) return '—';
  return (floors / (seconds / 60)).toStringAsFixed(1);
}

/// The rate readout under a cardio set, as a value and its unit: pace for
/// anything that covers ground, floors per minute for a stepmill.
(String, String) formatRate(
  double dist,
  int secs,
  CardioKind kind, {
  bool asSpeed = false,
}) {
  if (kind.countsFloors) return (formatClimbRate(dist, secs), 'floors/min');
  if (asSpeed) return (formatSpeed(dist, secs), 'km/h');
  return (formatPace(dist, secs), '/km');
}

/// Metres per second, before any grade adjustment. `ArcData.cardioScore` builds
/// the stored score from this.
double speedOf(double metres, int seconds) =>
    (metres <= 0 || seconds <= 0) ? 0 : metres / seconds;

/// A score read back as the pace it represents.
String paceFromScore(double metresPerSec) {
  if (metresPerSec <= 0) return '—';
  return formatPace(1000, (1000 / metresPerSec).round());
}

/// One cardio block as a line: `27:40 · 5.2 km · 3%`.
///
/// The single formatter every read-only surface shares — the day sheet's chips,
/// the share card, the clipboard export, the progression log. Cardio has three
/// measures where a lift has two, so leaving each surface to assemble them
/// itself is how the same block ends up reading three different ways.
///
/// Empty measures are dropped rather than shown as zero: a block with no
/// distance reads "27:40", not "27:40 · 0 m".
String cardioSetLine(
  int? secs,
  double? dist,
  double? level,
  CardioKind kind, {
  bool withRate = false,
}) {
  final parts = <String>[];
  if ((secs ?? 0) > 0) parts.add(formatDuration(secs!));
  if ((dist ?? 0) > 0) {
    final (v, u) = formatDistance(dist!, kind);
    parts.add('$v $u');
  }
  if ((level ?? 0) > 0 && kind.hasModifier) {
    final suffix = kind.modifierSuffix;
    final v = level! % 1 == 0 ? level.toInt().toString() : level.toString();
    parts.add(suffix.isEmpty ? '${kind.modifierLabel} $v' : '$v$suffix');
  }
  if (withRate && (secs ?? 0) > 0 && (dist ?? 0) > 0) {
    final (v, u) = formatRate(dist!, secs!, kind);
    parts.add(kind.countsFloors ? '$v $u' : '$v$u');
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
}

/// The same block as a screen reader should hear it.
String spokenCardioSet(
    int? secs, double? dist, double? level, CardioKind kind) {
  final parts = <String>[];
  if ((secs ?? 0) > 0) parts.add(spokenDuration(secs!));
  if ((dist ?? 0) > 0) {
    final (v, u) = formatDistance(dist!, kind);
    parts.add('$v $u');
  }
  if ((level ?? 0) > 0 && kind.hasModifier) {
    final v = level! % 1 == 0 ? level.toInt().toString() : level.toString();
    parts.add('${kind.modifierLabel} $v${kind.modifierSuffix == '%' ? ' percent' : ''}');
  }
  return parts.isEmpty ? 'empty' : parts.join(', ');
}

// ── Benchmarks ──────────────────────────────────────────────────────

/// The distances a running record is worth quoting at.
///
/// Speed alone cannot rank a run — the shortest hard effort always wins it, the
/// same way est. 1RM is always won by a single. So the *ranking* key stays
/// speed, and these are what actually get shown: a fastest 5 km is a fact about
/// the runner, needs no formula anyone has to trust, and is directly comparable
/// to the same number six months ago.
class Benchmark {
  const Benchmark(this.metres, this.label);

  final double metres;
  final String label;

  /// How far off the mark a set can land and still count. A 5.1 km run is a
  /// 5 km performance; a 4.2 km run is a different workout.
  static const tolerance = 0.05;

  bool accepts(double m) =>
      m >= metres * (1 - tolerance) && m <= metres * (1 + tolerance);

  static const all = <Benchmark>[
    Benchmark(400, '400 m'),
    Benchmark(800, '800 m'),
    Benchmark(1000, '1 km'),
    Benchmark(1609.34, '1 mile'),
    Benchmark(5000, '5 km'),
    Benchmark(10000, '10 km'),
  ];
}
