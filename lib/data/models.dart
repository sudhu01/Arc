// Domain models for Arc — ported from arc-data.js.

class Exercise {
  final String id;
  final String name;
  final String group; // Push | Pull | Legs | Core
  final String unit; // 'kg' | 'bw'

  const Exercise({
    required this.id,
    required this.name,
    required this.group,
    required this.unit,
  });

  bool get isBodyweight => unit == 'bw';
}

class WorkoutSet {
  final String id;
  final double weight;
  final int reps;

  const WorkoutSet({required this.id, required this.weight, required this.reps});

  WorkoutSet copyWith({double? weight, int? reps}) =>
      WorkoutSet(id: id, weight: weight ?? this.weight, reps: reps ?? this.reps);
}

class Entry {
  final String id;
  final String exerciseId;
  final List<WorkoutSet> sets;

  const Entry({required this.id, required this.exerciseId, required this.sets});

  Entry copyWith({List<WorkoutSet>? sets}) =>
      Entry(id: id, exerciseId: exerciseId, sets: sets ?? this.sets);
}

class Session {
  final String id;
  final String date; // ISO yyyy-MM-dd
  final String title;
  final List<Entry> entries;

  const Session({
    required this.id,
    required this.date,
    required this.title,
    required this.entries,
  });
}

/// A single point in an exercise's progression history.
class RecordPoint {
  final String date;
  final int score; // est. 1RM, or reps for bodyweight
  final double weight;
  final int reps;

  const RecordPoint({
    required this.date,
    required this.score,
    required this.weight,
    required this.reps,
  });
}

/// Aggregated record + chronological history for one exercise.
class ExerciseRecord {
  final Exercise ex;
  RecordPoint? best;
  final List<RecordPoint> history;

  ExerciseRecord({required this.ex, this.best, List<RecordPoint>? history})
      : history = history ?? [];
}

class WorkoutStats {
  final int total;
  final int totalVol;
  final int totalSets;
  final int thisWeek;

  const WorkoutStats({
    required this.total,
    required this.totalVol,
    required this.totalSets,
    required this.thisWeek,
  });
}

/// Pairing status of a companion.
enum CompanionStatus { pending, accepted, blocked }

/// Another user paired via QR. `publicId` is their shareable identity;
/// `publicKey` is learned (for signature verification) once sync is wired up.
class Companion {
  final String publicId;
  final String? publicKey; // base64 Ed25519 public key — null until learned
  final String displayName;
  final CompanionStatus status;
  final int addedAt; // ms since epoch
  final int? lastSyncedAt;

  const Companion({
    required this.publicId,
    this.publicKey,
    required this.displayName,
    required this.status,
    required this.addedAt,
    this.lastSyncedAt,
  });

  Companion copyWith({
    String? publicKey,
    String? displayName,
    CompanionStatus? status,
    int? lastSyncedAt,
  }) =>
      Companion(
        publicId: publicId,
        publicKey: publicKey ?? this.publicKey,
        displayName: displayName ?? this.displayName,
        status: status ?? this.status,
        addedAt: addedAt,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
}

/// This device's own identity. The private key never lives here — it stays in
/// secure storage (see IdentityService). `publicId` is the QR-shareable handle.
class Identity {
  final String publicId;
  final String publicKey; // base64 Ed25519 public key
  final String? displayName;
  final int createdAt;

  const Identity({
    required this.publicId,
    required this.publicKey,
    this.displayName,
    required this.createdAt,
  });
}
