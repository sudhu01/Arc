import 'package:arc/data/arc_data.dart';
import 'package:arc/data/models.dart';
import 'package:arc/data/muscle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bench = Exercise(
    id: 'bench',
    name: 'Bench press',
    muscle: Muscle.chest,
    secondary: [Muscle.triceps],
    unit: 'kg',
  );
  const curl = Exercise(
    id: 'curl',
    name: 'Curl',
    muscle: Muscle.biceps,
    unit: 'kg',
  );
  const run = Exercise(
    id: 'run',
    name: 'Run',
    muscle: Muscle.cardio,
    unit: 'cardio',
  );
  final exercises = {
    for (final ex in [bench, curl, run]) ex.id: ex,
  };
  Exercise? byId(String id) => exercises[id];

  Session session(String date, List<Entry> entries) =>
      Session(id: date, date: date, title: 'Workout', entries: entries);
  Entry entry(String id, int count) => Entry(
    id: id,
    exerciseId: id,
    sets: List.generate(
      count,
      (i) => WorkoutSet(id: '$id-$i', weight: 60, reps: 8),
    ),
  );

  setUp(() => ArcData.debugToday = DateTime(2026, 9, 25));
  tearDown(() => ArcData.debugToday = null);

  test(
    'effective sets use direct and assisted counts in the 14-day window',
    () {
      final sessions = [
        session('2026-09-25', [entry('bench', 4), entry('run', 5)]),
        session('2026-09-12', [entry('bench', 2)]),
        session('2026-09-11', [entry('bench', 20)]),
      ];
      final workload = ArcData.muscleWorkload(sessions, byId);
      expect(workload[Muscle.chest], 6);
      expect(workload[Muscle.triceps], closeTo(2.4, 1e-9));
      expect(workload[Muscle.biceps], 0);
      expect(workload.containsKey(Muscle.cardio), isFalse);
    },
  );

  test('one group keeps its absolute workload when another group changes', () {
    final original = [
      session('2026-09-25', [entry('bench', 4)]),
    ];
    final expanded = [
      session('2026-09-25', [entry('bench', 4), entry('curl', 12)]),
    ];
    expect(ArcData.muscleWorkload(original, byId)[Muscle.chest], 4);
    expect(ArcData.muscleWorkload(expanded, byId)[Muscle.chest], 4);
    expect(ArcData.muscleVolume(original, byId)[Muscle.chest], 1);
    expect(ArcData.muscleVolume(expanded, byId)[Muscle.chest], 1 / 3);
  });

  test('workload returns to zero when its sets age out', () {
    final sessions = [
      session('2026-09-12', [entry('bench', 4)]),
    ];
    expect(ArcData.muscleWorkload(sessions, byId)[Muscle.chest], 4);
    ArcData.debugToday = DateTime(2026, 9, 26);
    expect(ArcData.muscleWorkload(sessions, byId)[Muscle.chest], 0);
  });
}
