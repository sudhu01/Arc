// Domain models for Arc — ported from arc-data.js.

import '../notes/note_doc.dart';
import 'cardio.dart';
import 'muscle.dart';

class Exercise {
  final String id;
  final String name;

  /// The group this lift is filed under and counted against — the one the user
  /// picks, and the only one that decides where it appears in the library.
  final Muscle muscle;

  /// Groups the lift also works, in descending contribution. These never move
  /// an exercise in the library; they only feed the body's volume map, at a
  /// discount — see [ArcData.muscleVolume].
  final List<Muscle> secondary;

  /// What a set of this exercise is measured in: `'kg'` | `'bw'` | `'cardio'`.
  ///
  /// This is the polymorphism switch — it decides which measures a set carries,
  /// which controls the log sheet draws, and which branch scores it. A value
  /// this build does not know reads as weighted, which is the oldest behaviour
  /// and the safest one.
  final String unit;

  /// Which cardio this is, and therefore what its third measure means. Null on
  /// every non-cardio exercise, and on a cardio row written by a build or a
  /// companion that predates the kinds — [cardio] resolves that to a sane
  /// default rather than making callers check twice.
  final CardioKind? cardioKind;

  /// False when [muscle] was guessed rather than chosen — either backfilled
  /// from the old Push/Pull/Legs/Core taxonomy or inferred from a companion's
  /// row. The Exercises screen offers to correct these; nothing else cares.
  final bool muscleConfirmed;

  const Exercise({
    required this.id,
    required this.name,
    required this.muscle,
    this.secondary = const [],
    required this.unit,
    this.cardioKind,
    this.muscleConfirmed = true,
  });

  bool get isBodyweight => unit == 'bw';

  bool get isCardio => unit == 'cardio';

  /// The cardio kind to actually draw and score with. Only meaningful when
  /// [isCardio]; falls back rather than throwing, so an unrecognised kind
  /// degrades to time-and-distance instead of an empty screen.
  CardioKind get cardio => cardioKind ?? CardioKind.fallback;

  /// The coarse movement pattern — Push | Pull | Legs | Core. Everything that
  /// predates the muscle taxonomy (session titles, calendar dots, the group
  /// palette) reads this rather than [muscle].
  String get region => muscle.region;

  /// Whether this lift works [m] at all, primarily or otherwise.
  bool trains(Muscle m) => muscle == m || secondary.contains(m);

  Exercise copyWith({
    String? name,
    Muscle? muscle,
    List<Muscle>? secondary,
    String? unit,
    CardioKind? cardioKind,
    bool clearCardioKind = false,
    bool? muscleConfirmed,
  }) =>
      Exercise(
        id: id,
        name: name ?? this.name,
        muscle: muscle ?? this.muscle,
        secondary: secondary ?? this.secondary,
        unit: unit ?? this.unit,
        cardioKind: clearCardioKind ? null : (cardioKind ?? this.cardioKind),
        muscleConfirmed: muscleConfirmed ?? this.muscleConfirmed,
      );
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

  /// How long the effort lasted, in seconds. Null on every strength set.
  ///
  /// Cardio's three measures live beside [weight] and [reps] rather than
  /// overloading them. Two slots cannot hold three numbers, `reps` cannot be
  /// zero, and `e1rm` returns 0 for any set with no weight — an overload would
  /// have scored every run as nothing and rendered nonsense on the share card.
  final int? secs;

  /// Ground covered, in metres — or floors climbed on a stepmill. Always
  /// stored in metres however the control chose to display it.
  final double? dist;

  /// The machine's intensity dial: incline %, resistance, or level, per the
  /// exercise's [CardioKind]. Only incline is a real load; see [gradeFactor].
  final double? level;

  const WorkoutSet({
    required this.id,
    required this.weight,
    required this.reps,
    this.drops = const [],
    this.secs,
    this.dist,
    this.level,
  });

  /// Whether this set carries a usable cardio effort. Both measures have to be
  /// present: a duration with no distance cannot be paced, and a distance with
  /// no duration is not a performance.
  bool get hasCardio => (secs ?? 0) > 0 && (dist ?? 0) > 0;

  WorkoutSet copyWith({
    double? weight,
    int? reps,
    List<SetDrop>? drops,
    int? secs,
    double? dist,
    double? level,
  }) =>
      WorkoutSet(
        id: id,
        weight: weight ?? this.weight,
        reps: reps ?? this.reps,
        drops: drops ?? this.drops,
        secs: secs ?? this.secs,
        dist: dist ?? this.dist,
        level: level ?? this.level,
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

  /// The user's written note about this workout, as an encoded [NoteDoc] —
  /// see `lib/notes/note_doc.dart`. Normalized so a note whose text is blank is
  /// stored as null: `session.notes != null` always means there is something to
  /// read. Opaque to everything outside the notes layer, which is what lets it
  /// ride the sync payload as one string.
  final String? notes;

  final List<Entry> entries;

  const Session({
    required this.id,
    required this.date,
    required this.title,
    this.name,
    this.notes,
    required this.entries,
  });

  /// The label to show anywhere this workout is named: the user's word for it,
  /// else the one Arc inferred.
  String get displayTitle => name ?? title;

  /// [notes] is nullable, so passing null cannot mean "clear it" — [clearNotes]
  /// is how the note is removed.
  Session copyWith({
    String? name,
    String? notes,
    bool clearNotes = false,
    List<Entry>? entries,
  }) =>
      Session(
        id: id,
        date: date,
        title: title,
        name: name ?? this.name,
        notes: clearNotes ? null : (notes ?? this.notes),
        entries: entries ?? this.entries,
      );
}

/// Trims a workout name down to what's worth storing. Blank in any form comes
/// back as null, so `session.name != null` always means the user named it.
String? normalizeSessionName(String? raw) {
  final t = raw?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// The same for a note: a document that decodes to nothing but whitespace and
/// the marks of empty checklist lines is not a note. Every read path out of the
/// database runs through this, so `session.notes != null` can be trusted
/// everywhere to mean "there is something to read".
String? normalizeSessionNotes(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final text = NoteDoc.decode(raw).text.replaceAll(RegExp('[$checkEmpty$checkDone]'), '');
  return text.trim().isEmpty ? null : raw;
}

/// A single point in an exercise's progression history.
class RecordPoint {
  final String date;
  final double score; // est. 1RM (1-decimal precision), or reps for bodyweight
  final double weight; // weight of the top-scoring set
  final double maxWeight; // heaviest weight lifted that session (0 for bodyweight)
  final int reps;

  /// Sets performed on this exercise that session, counted Arc's way: a set and
  /// its drop tiers are one set. This is volume, not a strength test, so it is
  /// the only field here that describes the whole session rather than the
  /// top-scoring set.
  final int sets;

  /// The cardio measures of the top-scoring set, mirroring [WorkoutSet]. Null
  /// on every strength record.
  ///
  /// Carried on the point rather than looked up again because the record row
  /// shows the distance beside the pace, and it has to be the distance that
  /// *earned* the pace — a 30-second burst and a 5 km run read very differently
  /// at the same number, and without the context the burst would masquerade as
  /// the better run.
  final int? secs;
  final double? dist;
  final double? level;

  /// Total seconds of cardio on this exercise that session — the volume figure,
  /// the way [sets] is for lifting.
  final int? totalSecs;

  const RecordPoint({
    required this.date,
    required this.score,
    required this.weight,
    required this.maxWeight,
    required this.reps,
    required this.sets,
    this.secs,
    this.dist,
    this.level,
    this.totalSecs,
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

  /// Seconds of conditioning in the last seven days. Zero for a user who has
  /// never logged cardio, which is what keeps it out of their dashboard.
  final int cardioSecsThisWeek;

  const WorkoutStats({
    required this.total,
    required this.totalSets,
    required this.thisWeek,
    required this.setsThisWeek,
    this.cardioSecsThisWeek = 0,
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
