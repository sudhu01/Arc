import 'dart:math' as math;
import 'models.dart';

/// Metrics + date helpers for Arc. (Exercise library and history are now
/// entirely user-created and persisted in SQLite — no seed/placeholder data.)
class ArcData {
  ArcData._();

  static const List<String> groups = ['Push', 'Pull', 'Legs', 'Core'];

  static const Map<String, String> dayTitle = {
    'Push': 'Push Day',
    'Pull': 'Pull Day',
    'Legs': 'Leg Day',
    'Core': 'Core Day',
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

  static double setScore(Exercise ex, WorkoutSet s) =>
      ex.unit == 'bw' ? s.reps.toDouble() : e1rm(s.weight, s.reps);

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
        for (final s in e.sets) {
          final sc = setScore(ex, s);
          if (sc > topScore) {
            topScore = sc;
            topSet = s;
          }
          if (s.weight > maxW) maxW = s.weight;
        }
        if (topSet == null) continue;
        final point = RecordPoint(
          date: ses.date,
          score: topScore,
          weight: topSet.weight,
          maxWeight: maxW,
          reps: topSet.reps,
        );
        rec.history.add(point);
        if (rec.best == null || topScore > rec.best!.score) {
          rec.best = point;
        }
      }
    }
    return byEx;
  }

  static int daysAgo(String isoStr) {
    final d = parseISO(isoStr);
    return (today.difference(d).inHours / 24).round();
  }

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
      final g = exById(id)?.group;
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

  static WorkoutStats workoutStats(List<Session> sessions) {
    var totalSets = 0;
    var thisWeek = 0;
    var setsThisWeek = 0;
    for (final s in sessions) {
      final sets = s.entries.fold<int>(0, (x, e) => x + e.sets.length);
      totalSets += sets;
      final ago = daysAgo(s.date);
      if (ago >= 0 && ago <= 6) {
        thisWeek++;
        setsThisWeek += sets;
      }
    }
    return WorkoutStats(
      total: sessions.length,
      totalSets: totalSets,
      thisWeek: thisWeek,
      setsThisWeek: setsThisWeek,
    );
  }

  /// Weekday index matching JS getDay() (Sun=0 .. Sat=6).
  static int jsWeekday(DateTime d) => d.weekday % 7;

  static final math.Random _r = math.Random();
  static String randomId() => 'r${_r.nextInt(1 << 32)}';
}
