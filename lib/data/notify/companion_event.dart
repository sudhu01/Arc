// THESIS: A companion's workout is news, not a data row — Arc tells you the
//   moment it happens, in one sentence with the number in it, and then gets out
//   of the way. It refuses the category default of an in-app activity feed with
//   a red badge you have to go and clear.
// OWN-WORLD: The Android shade, wearing what Arc can actually own there — the
//   rising-curve mark (`ic_stat_arc`), the live accent from the user's own
//   theme resolved against the shade's brightness, Arc's `100 kg × 8` notation,
//   and two channels named in its factual voice. The lettering is the
//   platform's; a notification is set in the system face and no API changes
//   that, so type is not part of this surface's identity.
// STORY: You are on the sofa. Your phone says a training partner just started
//   Leg Day, or just put 100 kg over their old bench. You know, without opening
//   anything, and it costs you one glance.
// FIRST VIEWPORT: One shade line. Title carries who and what; body carries the
//   specifics; the expanded form is the whole sentence, verbatim.
// FORM: OS notification, extending an established surface — no concept
//   tournament, the app's world is inherited whole.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the
//   finish review, the verdict, and DESIGN.md.

import 'dart:convert';

import '../arc_data.dart';

/// The moments Arc broadcasts to companions. Wire values — never renamed
/// without a server change, since the relay validates the set.
enum EventKind {
  workoutStarted('workout_started'),
  personalRecord('pr');

  const EventKind(this.wire);
  final String wire;

  static EventKind? fromWire(String? s) {
    for (final k in EventKind.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// How long after the fact a moment is still worth announcing.
///
/// These are the whole reason a first sync on a freshly paired device doesn't
/// replay a week of a companion's history into the shade, and the reason a
/// phone that was in a basement for three hours doesn't claim someone is
/// starting a workout they finished before lunch.
///
/// "Started a workout" is perishable: past the window it is simply false. A
/// personal record is a fact that stays true, so it gets a day's grace — long
/// enough to survive an overnight flight-mode, short enough that it never reads
/// as history.
Duration eventFreshness(EventKind kind) => switch (kind) {
      EventKind.workoutStarted => const Duration(hours: 4),
      EventKind.personalRecord => const Duration(hours: 24),
    };

/// One moment, either about to be published or freshly pulled from the relay.
class CompanionEvent {
  final String id;
  final EventKind kind;
  final Map<String, dynamic> payload;

  /// Milliseconds since epoch, on the *actor's* clock — the moment it happened,
  /// not the moment it was relayed.
  final int createdAt;

  /// Whose moment this is. Empty on an event of my own still in the outbox.
  final String ownerId;

  /// The actor's name as the relay knows it. A fallback only: the local
  /// companion row wins, because that is the name the user chose to see.
  final String ownerName;

  const CompanionEvent({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.ownerId = '',
    this.ownerName = '',
  });

  /// A moment of my own, ready for the outbox.
  factory CompanionEvent.mine(EventKind kind, Map<String, dynamic> payload) =>
      CompanionEvent(
        id: ArcData.uid('ev'),
        kind: kind,
        payload: payload,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// Parses one entry of the relay's `/v1/events` response. Returns null for
  /// anything this build doesn't understand, so a companion running a newer Arc
  /// can add a kind without breaking this one.
  static CompanionEvent? fromWire(Map<String, dynamic> m) {
    final kind = EventKind.fromWire(m['kind'] as String?);
    final id = m['id'] as String?;
    if (kind == null || id == null || id.isEmpty) return null;
    return CompanionEvent(
      id: id,
      kind: kind,
      payload: (m['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      ownerId: (m['owner_id'] as String?) ?? '',
      ownerName: (m['owner_name'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toWire() => {
        'id': id,
        'kind': kind.wire,
        'payload': payload,
        'created_at': createdAt,
      };

  String get payloadJson => jsonEncode(payload);

  /// Whether this moment is still true enough to interrupt someone with.
  bool isFreshAt(int nowMs) =>
      nowMs - createdAt <= eventFreshness(kind).inMilliseconds;

  // ── Payload builders ────────────────────────────────────────────────
  // Kept beside the readers below so a field can never be written under one
  // name and read under another.

  /// `{name}` is what the workout is *called* — the user's name for it if they
  /// gave one, else the title Arc infers from the first lift they logged. It is
  /// resolved at the moment the beacon fires, which is the only moment at which
  /// "Today is …" is a statement rather than a guess.
  static Map<String, dynamic> workoutStartedPayload({
    required String name,
    required String date,
  }) =>
      {'name': name, 'date': date};

  /// The record itself, not a pointer to it: a companion whose exercise library
  /// this device has never synced still gets a sentence with the lift's name and
  /// the number in it.
  static Map<String, dynamic> prPayload({
    required String exercise,
    required double weight,
    required int reps,
    required String unit,
  }) =>
      {
        'exercise': exercise,
        'weight': weight,
        'reps': reps,
        'unit': unit,
      };

  // ── Payload readers ─────────────────────────────────────────────────

  String get workoutName {
    final n = (payload['name'] as String?)?.trim();
    return (n == null || n.isEmpty) ? 'Workout' : n;
  }

  String get exerciseName {
    final n = (payload['exercise'] as String?)?.trim();
    return (n == null || n.isEmpty) ? 'a lift' : n;
  }

  double get weight => (payload['weight'] as num?)?.toDouble() ?? 0;
  int get reps => (payload['reps'] as num?)?.toInt() ?? 0;

  /// Bodyweight lifts are scored in reps; everything else in kilos. The unit
  /// decides which number the sentence quotes, so it travels with the record.
  bool get isBodyweight => payload['unit'] == 'bw';
}

/// What a moment says, in Arc's voice.
///
/// Title and body split the same sentence at its natural seam so the shade's
/// two type sizes carry the claim and the number separately — a glance from
/// across the room lands on "Alice has a new PR record", a proper look lands on
/// "100 kg for Bench Press". [full] is that sentence unbroken: it feeds the
/// expanded notification and the accessibility ticker, so nothing is lost to
/// the split.
class AlertCopy {
  final String title;
  final String body;
  final String full;

  const AlertCopy({
    required this.title,
    required this.body,
    required this.full,
  });

  /// Renders [event] for [who] — the name this device knows the companion by.
  factory AlertCopy.of(CompanionEvent event, String who) {
    switch (event.kind) {
      case EventKind.workoutStarted:
        final name = event.workoutName;
        return AlertCopy(
          title: '$who has started a workout!',
          body: 'Today is $name',
          full: '$who has started a workout! Today is $name',
        );
      case EventKind.personalRecord:
        // Records break on estimated 1RM, not on load, so the same weight for
        // more reps is a genuine PR — and quoting the weight alone would
        // announce a number the companion already saw last week and call it
        // new. Arc's own notation everywhere else is `100 kg × 8`; the sentence
        // uses it, so the thing that actually moved is always on screen.
        final amount = event.isBodyweight
            ? '${event.reps} ${event.reps == 1 ? 'rep' : 'reps'}'
            : '${ArcData.fmtScore(event.weight)} kg × ${event.reps}';
        final lift = event.exerciseName;
        return AlertCopy(
          title: '$who has a new PR record',
          body: '$amount for $lift',
          full: '$who has a new PR record of $amount for $lift',
        );
    }
  }
}
