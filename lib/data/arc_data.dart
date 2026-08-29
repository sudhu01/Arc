import 'dart:math' as math;
import 'cardio.dart';
import 'models.dart';
import 'muscle.dart';

/// The headline figure for a cardio record — the pace of the best block.
///
/// The *actual* pace, not the one the score implies. The score is grade
/// adjusted so a hill session can outrank a flat one, but a runner who reads
/// "4:32" wants the number that was on the treadmill, not a number that
/// accounts for the incline they can already see printed beside it.
String bestCardioValue(RecordPoint p, CardioKind kind) {
  final d = p.dist ?? 0;
  final s = p.secs ?? 0;
  if (d <= 0 || s <= 0) return '—';
  return formatRate(d, s, kind).$1;
}

String bestCardioUnit(CardioKind kind) =>
    kind.countsFloors ? 'floors/min' : 'best /km';

/// The distance a cardio best was set over, for the line beside the pace.
///
/// Always shown with the pace, and that pairing is load-bearing: the score is
/// won by whichever block was quickest, which will usually be the shortest one.
/// A thirty-second burst reading "2:58 /km" alone would masquerade as the best
/// run in the history. With "· 200 m" next to it, it reads as what it is.
String bestCardioContext(RecordPoint p, CardioKind kind) {
  final d = p.dist ?? 0;
  if (d <= 0) return '';
  final (v, u) = formatDistance(d, kind);
  return '$v $u';
}

/// Metrics + date helpers for Arc. (Exercise library and history are now
/// entirely user-created and persisted in SQLite — no seed/placeholder data.)
class ArcData {
  ArcData._();

  /// The coarse tier — movement patterns, not muscles. Still what session
  /// titles, calendar dots and the group palette speak; see [Muscle.region].
  static const List<String> groups = MuscleRegion.all;

  static const Map<String, String> dayTitle = {
    'Push': 'Push Day',
    'Pull': 'Pull Day',
    'Legs': 'Leg Day',
    'Core': 'Core Day',
    'Cardio': 'Conditioning',
  };

  /// Recovers the muscle group from a session title. Only a last resort now —
  /// [sessionGroup] reads the group off the logged exercises, which a renamed
  /// workout still answers correctly. Day titles are matched first because
  /// "Leg Day" doesn't literally contain "Legs"; a bare group name is the
  /// fallback for custom titles. Legacy titles that name no group keep their
  /// historical `Legs` reading.
  static String groupFromTitle(String title) {
    for (final e in dayTitle.entries) {
      if (title.contains(e.value)) return e.key;
    }
    for (final g in groups) {
      if (title.contains(g)) return g;
    }
    return 'Legs';
  }

  // ── Date helpers (local dates, no TZ drift) ─────────────────────────

  /// Pins [today] to a fixed date in tests so date-dependent widgets render
  /// deterministically. Null in production (uses the real clock).
  static DateTime? debugToday;

  /// The current local date with the time-of-day stripped, so ISO formatting
  /// and day-level comparisons stay clean.
  static DateTime get today {
    final n = debugToday ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime parseISO(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  static DateTime addDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  // Collision-resistant across app restarts (a persisted DB outlives any
  // in-memory counter): microsecond clock + monotonic counter + randomness.
  static int _uidCounter = 0;
  static String uid([String prefix = 'id']) {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final c = (_uidCounter++).toRadixString(36);
    final r = _r.nextInt(1 << 32).toRadixString(36);
    return '${prefix}_${t}_${c}_$r';
  }

  // ── Metrics ─────────────────────────────────────────────────────────
  /// Epley estimated 1RM, kept to one decimal place of precision.
  static double e1rm(double weight, int reps) =>
      weight <= 0 ? 0.0 : (weight * (1 + reps / 30) * 10).round() / 10;

  /// What a cardio set is worth, in metres per second of grade-adjusted speed.
  ///
  /// **Speed, not pace** — and that is the whole reason this works without
  /// touching anything else. Every consumer of a score already assumes bigger
  /// is better: [computeRecords] promotes on `topScore > best.score`,
  /// `RecordQuery` sorts descending, the dashboard delta paints itself with
  /// `AppColors.up` and an up arrow. A pace would have inverted all of them.
  /// Pace is a display transform on the way out ([paceFromScore]).
  ///
  /// Incline folds in as [gradeFactor], which is what makes it the load of a
  /// treadmill run rather than a footnote to one.
  ///
  /// There is deliberately no cross-distance normalisation (Riegel and its
  /// relatives). It is only sound between about 1500 m and 30 km, and it
  /// fabricates outside that band — it would credit a 13-second 100 m with a
  /// 2:29 kilometre. Within one exercise, like is compared with like, which is
  /// all [computeRecords] ever asks.
  static double cardioScore(Exercise ex, WorkoutSet s) {
    if (!s.hasCardio) return 0;
    return speedOf(s.dist! * gradeFactor(ex.cardio, s.level), s.secs!);
  }

  static double setScore(Exercise ex, WorkoutSet s) => switch (ex.unit) {
        'bw' => s.reps.toDouble(),
        'cardio' => cardioScore(ex, s),
        _ => e1rm(s.weight, s.reps),
      };

  /// Formats a 1RM/score to one decimal place, dropping a trailing `.0`
  /// (187.5 → "187.5", 190.0 → "190").
  static String fmtScore(num v) {
    final d = v.toDouble();
    return d % 1 == 0 ? d.toInt().toString() : d.toStringAsFixed(1);
  }

  /// Best record per exercise across all sessions, plus chronological history.
  static Map<String, ExerciseRecord> computeRecords(
      List<Session> sessions, List<Exercise> exercises) {
    final byEx = <String, ExerciseRecord>{};
    for (final ex in exercises) {
      byEx[ex.id] = ExerciseRecord(ex: ex);
    }
    final chrono = [...sessions]..sort((a, b) => a.date.compareTo(b.date));
    for (final ses in chrono) {
      for (final e in ses.entries) {
        final rec = byEx[e.exerciseId];
        if (rec == null) continue;
        final ex = rec.ex;
        WorkoutSet? topSet;
        var topScore = -1.0;
        var maxW = 0.0;
        var totalSecs = 0;
        for (final s in e.sets) {
          final sc = setScore(ex, s);
          if (sc > topScore) {
            topScore = sc;
            topSet = s;
          }
          if (s.weight > maxW) maxW = s.weight;
          totalSecs += s.secs ?? 0;
        }
        if (topSet == null) continue;
        // A cardio effort needs both a duration and a distance to be a
        // performance. A block logged with only one of them is a real
        // half-finished state — an elliptical with no distance readout, a run
        // still being typed in — and plotting it as a zero would put a floor in
        // the trend that never happened.
        if (ex.isCardio && topScore <= 0) continue;
        final point = RecordPoint(
          date: ses.date,
          score: topScore,
          weight: topSet.weight,
          maxWeight: maxW,
          reps: topSet.reps,
          sets: e.sets.length,
          secs: topSet.secs,
          dist: topSet.dist,
          level: topSet.level,
          totalSecs: ex.isCardio ? totalSecs : null,
        );
        rec.history.add(point);
        if (rec.best == null || topScore > rec.best!.score) {
          rec.best = point;
        }
      }
    }
    return byEx;
  }

  /// How hard each muscle group has been worked lately, as a 0..1 ratio of the
  /// hardest-worked group. This is what lights the body — a group at 1.0 glows,
  /// one at 0 sits matte.
  ///
  /// Counted in sets, not in weight: across thirteen groups that span barbell
  /// squats and cable curls, tonnage compares apples to nothing. A drop tier
  /// rides along with its parent set rather than counting again, matching how
  /// Arc counts sets everywhere else. Secondary groups accrue at
  /// [secondaryWeight] — bench builds triceps, but not the way dips do.
  ///
  /// Returns every group, including the untrained ones at 0, so a caller can
  /// paint the whole body without checking for absent keys.
  static Map<Muscle, double> muscleVolume(
    List<Session> sessions,
    Exercise? Function(String) exById, {
    int days = 14,
    double secondaryWeight = 0.4,
  }) {
    // Trainable only: Conditioning is counted in minutes and the body has no
    // mesh for it, so a key here would be a group that can never light.
    final raw = {for (final m in Muscle.trainable) m: 0.0};
    for (final s in sessions) {
      final ago = daysAgo(s.date);
      if (ago < 0 || ago >= days) continue;
      for (final e in s.entries) {
        final ex = exById(e.exerciseId);
        if (ex == null) continue;
        // Conditioning is counted in minutes, not sets, and the body has no
        // mesh to light for it. Leaving it in would let four treadmill blocks
        // outrank a squat session on a scale neither of them shares.
        if (ex.isCardio) continue;
        final sets = e.sets.length.toDouble();
        if (sets == 0) continue;
        raw[ex.muscle] = raw[ex.muscle]! + sets;
        for (final m in ex.secondary) {
          raw[m] = raw[m]! + sets * secondaryWeight;
        }
      }
    }
    final peak = raw.values.fold(0.0, math.max);
    if (peak <= 0) return raw;
    return {for (final e in raw.entries) e.key: e.value / peak};
  }

  /// Raw set counts for one group over the window the body map uses: [direct]
  /// from lifts that name it as their primary, [assisted] from lifts that only
  /// list it as secondary. Kept separate rather than blended because "18 sets"
  /// is a claim, and 12 of them being bench press is worth saying out loud.
  static ({int direct, int assisted}) muscleSets(
    List<Session> sessions,
    Exercise? Function(String) exById,
    Muscle muscle, {
    int days = 14,
  }) {
    var direct = 0;
    var assisted = 0;
    for (final s in sessions) {
      final ago = daysAgo(s.date);
      if (ago < 0 || ago >= days) continue;
      for (final e in s.entries) {
        final ex = exById(e.exerciseId);
        if (ex == null || ex.isCardio) continue;
        if (ex.muscle == muscle) {
          direct += e.sets.length;
        } else if (ex.secondary.contains(muscle)) {
          assisted += e.sets.length;
        }
      }
    }
    return (direct: direct, assisted: assisted);
  }

  static int daysAgo(String isoStr) {
    final d = parseISO(isoStr);
    return (today.difference(d).inHours / 24).round();
  }

  /// How long a personal record wears its "New" tag. Just over a fortnight, so
  /// a lift trained once a week still shows its last two attempts as fresh.
  static const newRecordDays = 16;

  /// Whether a record set on [isoStr] still counts as new — the one definition
  /// behind the tag on a record row and the "new records only" filter, so the
  /// filter can never disagree with the badge it filters on.
  static bool isNewRecord(String isoStr) => daysAgo(isoStr) <= newRecordDays;

  static String relDate(String isoStr) {
    final n = daysAgo(isoStr);
    if (n == 0) return 'Today';
    if (n == 1) return 'Yesterday';
    if (n < 7) return '$n days ago';
    if (n < 14) return 'Last week';
    return '${(n / 7).floor()} weeks ago';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _monthsLong = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];
  static const _wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  static List<String> get monthsLong => _monthsLong;
  static List<String> get monthsShort => _months;
  static List<String> get weekdayShort => _wd;

  /// `long` → "Fri, May 29"; otherwise "May 29".
  static String fmtDate(String isoStr, [String? opts]) {
    final d = parseISO(isoStr);
    final wd = _wd[d.weekday % 7]; // Dart: Mon=1..Sun=7 → JS Sun=0..Sat=6
    final mo = _months[d.month - 1];
    final day = d.day;
    if (opts == 'long') return '$wd, $mo $day';
    return '$mo $day';
  }

  /// The muscle group most of a workout's exercises belong to. Null when
  /// nothing resolves — an empty workout, or a companion's exercise this device
  /// hasn't synced. Ties break in [groups] order, so the inferred title and the
  /// dot drawn beside it can never disagree.
  ///
  /// Takes exercise ids rather than entries so a draft still being edited can
  /// ask the same question a saved session does.
  static String? dominantGroup(
      Iterable<String> exerciseIds, Exercise? Function(String) exById) {
    final count = <String, int>{};
    for (final id in exerciseIds) {
      final g = exById(id)?.region;
      if (g == null) continue;
      count[g] = (count[g] ?? 0) + 1;
    }
    if (count.isEmpty) return null;
    int rank(String g) {
      final i = groups.indexOf(g);
      return i < 0 ? groups.length : i;
    }

    final ordered = count.keys.toList()
      ..sort((a, b) {
        final byCount = count[b]!.compareTo(count[a]!);
        return byCount != 0 ? byCount : rank(a).compareTo(rank(b));
      });
    return ordered.first;
  }

  /// The title Arc gives a workout the user didn't name.
  static String inferTitle(
      Iterable<String> exerciseIds, Exercise? Function(String) exById) {
    final top = dominantGroup(exerciseIds, exById);
    return top == null ? 'Workout' : (dayTitle[top] ?? 'Workout');
  }

  /// The group a saved session belongs to — read from what was actually logged
  /// rather than from its label, so a workout the user renamed "Chest & Arms"
  /// still carries the right dot. Only sessions whose exercises are all missing
  /// fall back to parsing the old derived title.
  static String sessionGroup(Session s, Exercise? Function(String) exById) =>
      dominantGroup(s.entries.map((e) => e.exerciseId), exById) ??
      groupFromTitle(s.title);

  /// Every muscle group a session trained, deduplicated and in body order.
  ///
  /// Primary groups only. Bench builds triceps, but a session that counted every
  /// assisting group would report six or seven of them on any ordinary day, and
  /// the answer this exists to give — *what did I train* — is the one a lifter
  /// answers with the lifts they chose, not with the ones that came along.
  /// [muscleVolume] is where the assisted share is counted.
  ///
  /// Body order rather than volume order, because [Muscle]'s declaration order is
  /// the display order everywhere else in Arc; a group should not move because a
  /// set was added to it.
  ///
  /// Empty when nothing resolves — every exercise missing from this device's
  /// library — which is the case [sessionGroup] still answers, from the title.
  static List<Muscle> sessionMuscles(
      Session s, Exercise? Function(String) exById) {
    final trained = <Muscle>{};
    for (final e in s.entries) {
      final ex = exById(e.exerciseId);
      if (ex != null) trained.add(ex.muscle);
    }
    if (trained.isEmpty) return const [];
    return Muscle.values.where(trained.contains).toList();
  }

  /// Workout and set counts, plus the week's conditioning time.
  ///
  /// Cardio entries are counted in seconds and *not* in sets. A treadmill block
  /// is one entry whether it ran for six minutes or sixty, so folding it into
  /// "62 sets" would inflate a number the user reads as lifting volume — the
  /// same reason [muscleVolume] skips it.
  static WorkoutStats workoutStats(
      List<Session> sessions, Exercise? Function(String) exById) {
    var totalSets = 0;
    var thisWeek = 0;
    var setsThisWeek = 0;
    var cardioSecsThisWeek = 0;
    for (final s in sessions) {
      var sets = 0;
      var cardioSecs = 0;
      for (final e in s.entries) {
        if (exById(e.exerciseId)?.isCardio ?? false) {
          for (final st in e.sets) {
            cardioSecs += st.secs ?? 0;
          }
        } else {
          sets += e.sets.length;
        }
      }
      totalSets += sets;
      final ago = daysAgo(s.date);
      if (ago >= 0 && ago <= 6) {
        thisWeek++;
        setsThisWeek += sets;
        cardioSecsThisWeek += cardioSecs;
      }
    }
    return WorkoutStats(
      total: sessions.length,
      totalSets: totalSets,
      thisWeek: thisWeek,
      setsThisWeek: setsThisWeek,
      cardioSecsThisWeek: cardioSecsThisWeek,
    );
  }

  /// Seconds of conditioning across [sessions], for the calendar's month tile.
  static int cardioSeconds(
      List<Session> sessions, Exercise? Function(String) exById) {
    var total = 0;
    for (final s in sessions) {
      for (final e in s.entries) {
        if (!(exById(e.exerciseId)?.isCardio ?? false)) continue;
        for (final st in e.sets) {
          total += st.secs ?? 0;
        }
      }
    }
    return total;
  }

  /// Sets across [sessions], counted Arc's way — conditioning excluded.
  static int strengthSets(
      List<Session> sessions, Exercise? Function(String) exById) {
    var total = 0;
    for (final s in sessions) {
      for (final e in s.entries) {
        if (exById(e.exerciseId)?.isCardio ?? false) continue;
        total += e.sets.length;
      }
    }
    return total;
  }

  /// The best effort at each benchmark distance, newest-first per benchmark.
  ///
  /// Only benchmarks with a qualifying set appear — an empty row would promise
  /// a distance the user has never run. Returns the fastest set at each mark,
  /// paired with the date it was set.
  static List<({Benchmark mark, RecordPoint point})> benchmarkBests(
    String exerciseId,
    List<Session> sessions,
    Exercise ex,
  ) {
    if (!ex.isCardio) return const [];
    final best = <int, ({Benchmark mark, RecordPoint point})>{};
    for (final ses in sessions) {
      for (final e in ses.entries) {
        if (e.exerciseId != exerciseId) continue;
        for (final s in e.sets) {
          if (!s.hasCardio) continue;
          for (var i = 0; i < Benchmark.all.length; i++) {
            final mark = Benchmark.all[i];
            if (!mark.accepts(s.dist!)) continue;
            // Normalise to the mark itself so a 5.1 km and a 4.9 km compete on
            // the same footing rather than the longer one always losing.
            final norm = s.secs! * (mark.metres / s.dist!);
            final held = best[i];
            if (held == null || norm < held.point.secs!) {
              best[i] = (
                mark: mark,
                point: RecordPoint(
                  date: ses.date,
                  score: cardioScore(ex, s),
                  weight: 0,
                  maxWeight: 0,
                  reps: 0,
                  sets: 1,
                  secs: norm.round(),
                  dist: mark.metres,
                  level: s.level,
                ),
              );
            }
          }
        }
      }
    }
    final out = <({Benchmark mark, RecordPoint point})>[];
    for (var i = 0; i < Benchmark.all.length; i++) {
      final b = best[i];
      if (b != null) out.add(b);
    }
    return out;
  }

  /// Weekday index matching JS getDay() (Sun=0 .. Sat=6).
  static int jsWeekday(DateTime d) => d.weekday % 7;

  static final math.Random _r = math.Random();
  static String randomId() => 'r${_r.nextInt(1 << 32)}';
}
