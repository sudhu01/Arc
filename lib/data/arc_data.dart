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
  };

  // ── Date helpers (local dates, no TZ drift) ─────────────────────────
  static final DateTime today = DateTime(2026, 5, 29); // Fri, May 29 2026

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
  static int e1rm(double weight, int reps) =>
      weight <= 0 ? 0 : (weight * (1 + reps / 30)).round();

  static int setScore(Exercise ex, WorkoutSet s) =>
      ex.unit == 'bw' ? s.reps : e1rm(s.weight, s.reps);

  static int sessionVolume(Session session) {
    var v = 0.0;
    for (final e in session.entries) {
      for (final s in e.sets) {
        v += s.weight * s.reps;
      }
    }
    return v.round();
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
        var topScore = -1;
        for (final s in e.sets) {
          final sc = setScore(ex, s);
          if (sc > topScore) {
            topScore = sc;
            topSet = s;
          }
        }
        if (topSet == null) continue;
        final point = RecordPoint(
          date: ses.date,
          score: topScore,
          weight: topSet.weight,
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

  static String inferTitle(List<Entry> entries, Exercise? Function(String) exById) {
    final count = <String, int>{};
    for (final e in entries) {
      final g = exById(e.exerciseId)?.group;
      if (g == null) continue;
      count[g] = (count[g] ?? 0) + 1;
    }
    if (count.isEmpty) return 'Workout';
    final top = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
    return dayTitle[top.first] ?? 'Workout';
  }

  static WorkoutStats workoutStats(List<Session> sessions) {
    final total = sessions.length;
    final totalVol =
        sessions.fold<int>(0, (a, s) => a + sessionVolume(s));
    final totalSets = sessions.fold<int>(
        0, (a, s) => a + s.entries.fold<int>(0, (x, e) => x + e.sets.length));
    final thisWeek = sessions
        .where((s) => daysAgo(s.date) <= 6 && daysAgo(s.date) >= 0)
        .length;
    return WorkoutStats(
      total: total,
      totalVol: totalVol,
      totalSets: totalSets,
      thisWeek: thisWeek,
    );
  }

  /// Weekday index matching JS getDay() (Sun=0 .. Sat=6).
  static int jsWeekday(DateTime d) => d.weekday % 7;

  static final math.Random _r = math.Random();
  static String randomId() => 'r${_r.nextInt(1 << 32)}';
}
