// Arc's muscle-group taxonomy.
//
// Two tiers, deliberately. The fine tier ([Muscle], 13 values) is what the user
// browses and files exercises under. The coarse tier ([Muscle.region], the
// original four movement patterns) is *derived* from it, and is what every
// pre-existing surface keeps reading: session titles ("Push Day"), calendar
// dots, the four-colour group palette, and the companion-sync payload.
//
// Deriving rather than replacing is what keeps this a contained change — and it
// keeps group identity legible without colour, since 13 groups are distinguished
// by name and body position while only the 4 regions carry a colour.

/// A trainable muscle group.
///
/// Declaration order is the display order everywhere Arc lists groups: torso
/// down through arms to legs, roughly how you'd read them off a standing body.
/// It is deliberately *not* alphabetical — "Abs, Biceps, Calves, Chest…" scans
/// as a dictionary, not as a body.
enum Muscle {
  chest('Chest', 'Push'),
  shoulders('Shoulders', 'Push'),
  upperBack('Upper Back', 'Pull'),
  lats('Lats', 'Pull'),
  lowerBack('Lower Back', 'Pull'),
  biceps('Biceps', 'Pull'),
  triceps('Triceps', 'Push'),
  forearms('Forearms', 'Pull'),
  abs('Abs', 'Core'),
  quads('Quads', 'Legs'),
  hamstrings('Hamstrings', 'Legs'),
  glutes('Glutes', 'Legs'),
  calves('Calves', 'Legs'),

  /// Conditioning. Not a muscle, and deliberately last: declaration order is
  /// display order everywhere, and a body part is what the other twelve are.
  ///
  /// Cardio needs *a* place in this taxonomy because every surface that files,
  /// filters, colours or summarises an exercise reads [Muscle] — but it is not
  /// counted the way the others are. [ArcData.muscleVolume] and
  /// [ArcData.muscleSets] both skip it: they count in sets, and a set is not
  /// what a run is made of.
  cardio('Cardio', 'Cardio');

  const Muscle(this.label, this.region);

  /// Display name — "Upper Back", not "upperBack".
  final String label;

  /// The coarse movement pattern this group rolls up to: Push | Pull | Legs |
  /// Core. Everything that predates the muscle taxonomy reads this.
  final String region;

  /// Stable string id used in the database, the sync payload, and as the mesh
  /// name in the body model. Never localise or prettify this — [label] is for
  /// humans, this is for storage.
  String get id => name;

  /// Parses a stored [id] back to a group. Null for anything unrecognised —
  /// a value written by a future build, or a corrupt row — so callers can fall
  /// back rather than crash on data they didn't write.
  static Muscle? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final m in Muscle.values) {
      if (m.name == id) return m;
    }
    return null;
  }

  /// Parses a comma-separated list of ids, dropping anything unrecognised and
  /// any duplicate. Order is preserved.
  static List<Muscle> parseList(String? csv) {
    if (csv == null || csv.isEmpty) return const [];
    final out = <Muscle>[];
    for (final part in csv.split(',')) {
      final m = fromId(part.trim());
      if (m != null && !out.contains(m)) out.add(m);
    }
    return out;
  }

  static String encodeList(Iterable<Muscle> muscles) =>
      muscles.map((m) => m.name).join(',');

  /// The groups belonging to one coarse region, in display order.
  static List<Muscle> inRegion(String region) =>
      Muscle.values.where((m) => m.region == region).toList();

  /// The thirteen body parts — everything a lift can be filed under.
  ///
  /// For the surfaces that ask "which muscle does this work", where
  /// [Muscle.cardio] is not an answer. Browsing surfaces (the library, the
  /// records filter, the colour picker) use [values] and show all fourteen.
  static final List<Muscle> trainable =
      List.unmodifiable(Muscle.values.where((m) => m != Muscle.cardio));
}

/// The coarse tier, kept as plain strings because that is what the database
/// column, the sync payload and [AppColors.group] have always held.
class MuscleRegion {
  MuscleRegion._();

  static const push = 'Push';
  static const pull = 'Pull';
  static const legs = 'Legs';
  static const core = 'Core';

  /// Conditioning — the one region that holds no muscle.
  static const cardio = 'Cardio';

  /// Last, and that placement is load-bearing: [ArcData.dominantGroup] breaks a
  /// tie by this order, so a day of three lifts and three runs still titles as
  /// the lifting day it was.
  static const all = [push, pull, legs, core, cardio];

  /// Where an exercise lands when all we know is its region — a row written by
  /// a build that predates the muscle taxonomy, or a companion still on one.
  /// Always the most common group in that region, and always marked unconfirmed
  /// so the review card offers to correct it.
  static Muscle defaultMuscle(String region) => switch (region) {
        push => Muscle.chest,
        pull => Muscle.lats,
        legs => Muscle.quads,
        core => Muscle.abs,
        cardio => Muscle.cardio,
        _ => Muscle.chest,
      };
}
