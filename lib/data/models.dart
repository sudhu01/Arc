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

/// One tier of a drop set: the lighter weight/reps pair run straight off the
/// back of a working set, with no rest in between.
///
/// A drop never carries drops of its own — a chain is flat, so `100×8 → 80×6 →
/// 60×5` is one [WorkoutSet] holding two [SetDrop]s.
class SetDrop {
  final String id;
  final double weight;
  final int reps;

  const SetDrop({required this.id, required this.weight, required this.reps});
}

class WorkoutSet {
  final String id;
  final double weight;
  final int reps;

  /// Drop tiers run off the back of this set, in the order they were performed
  /// (heaviest first). A set and its drops are *one* set everywhere Arc counts
  /// them, and only the parent's weight/reps feed est. 1RM and PR detection —
  /// drops are fatigue work, not a strength test.
  final List<SetDrop> drops;

  const WorkoutSet({
    required this.id,
    required this.weight,
    required this.reps,
    this.drops = const [],
  });

  WorkoutSet copyWith({double? weight, int? reps, List<SetDrop>? drops}) =>
      WorkoutSet(
        id: id,
        weight: weight ?? this.weight,
        reps: reps ?? this.reps,
        drops: drops ?? this.drops,
      );
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

  /// The title Arc derives from what was logged — "Push Day", "Leg Day". Kept
  /// on every session, named or not: it's the fallback label, and it's the only
  /// group signal a companion on a build that predates naming can read.
  final String title;

  /// What the user called this workout, if they bothered. Normalized so it is
  /// never an empty string — null always means "no name, use [title]".
  final String? name;

  final List<Entry> entries;

  const Session({
    required this.id,
    required this.date,
    required this.title,
    this.name,
    required this.entries,
  });

  /// The label to show anywhere this workout is named: the user's word for it,
  /// else the one Arc inferred.
  String get displayTitle => name ?? title;
}

/// Trims a workout name down to what's worth storing. Blank in any form comes
/// back as null, so `session.name != null` always means the user named it.
String? normalizeSessionName(String? raw) {
  final t = raw?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// A single point in an exercise's progression history.
class RecordPoint {
  final String date;
  final double score; // est. 1RM (1-decimal precision), or reps for bodyweight
  final double weight; // weight of the top-scoring set
  final double maxWeight; // heaviest weight lifted that session (0 for bodyweight)
  final int reps;

  const RecordPoint({
    required this.date,
    required this.score,
    required this.weight,
    required this.maxWeight,
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
  final int totalSets;
  final int thisWeek;
  final int setsThisWeek;

  const WorkoutStats({
    required this.total,
    required this.totalSets,
    required this.thisWeek,
    required this.setsThisWeek,
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
  final bool incoming; // pending request the peer sent me (I can accept)
  final int addedAt; // ms since epoch
  final int? lastSyncedAt;

  const Companion({
    required this.publicId,
    this.publicKey,
    required this.displayName,
    required this.status,
    this.incoming = false,
    required this.addedAt,
    this.lastSyncedAt,
  });

  Companion copyWith({
    String? publicKey,
    String? displayName,
    CompanionStatus? status,
    bool? incoming,
    int? lastSyncedAt,
  }) =>
      Companion(
        publicId: publicId,
        publicKey: publicKey ?? this.publicKey,
        displayName: displayName ?? this.displayName,
        status: status ?? this.status,
        incoming: incoming ?? this.incoming,
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
