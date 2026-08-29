import 'arc_data.dart';
import 'models.dart';

/// A read-only snapshot of one companion's synced workout data, with the same
/// derived metrics the dashboard computes for the local user.
class CompanionData {
  final Companion companion;
  final List<Exercise> exercises;
  final List<Session> sessions; // newest first
  final Map<String, ExerciseRecord> records;
  final WorkoutStats stats;

  const CompanionData({
    required this.companion,
    required this.exercises,
    required this.sessions,
    required this.records,
    required this.stats,
  });

  factory CompanionData.from(
    Companion companion,
    List<Exercise> exercises,
    List<Session> sessions,
  ) {
    final sorted = [...sessions]..sort((a, b) => b.date.compareTo(a.date));
    final index = {for (final e in exercises) e.id: e};
    Exercise? byId(String id) => index[id];
    return CompanionData(
      companion: companion,
      exercises: exercises,
      sessions: sorted,
      records: ArcData.computeRecords(sorted, exercises),
      stats: ArcData.workoutStats(sorted, byId),
    );
  }

  Exercise? exById(String id) {
    for (final e in exercises) {
      if (e.id == id) return e;
    }
    return null;
  }
}
