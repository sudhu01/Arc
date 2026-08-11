// How the Records screen is ordered and narrowed.
//
// Kept out of the screen because three surfaces read it — the list, the sheet
// that edits it, and the chip strip that reports it — and because the ranking
// rules below are the sort of thing that quietly rots when it lives inside a
// build method.

import 'package:flutter/foundation.dart' show immutable, setEquals;

import 'arc_data.dart';
import 'models.dart';
import 'muscle.dart';

/// What the list is ranked by.
enum RecordSort {
  /// Down the body, in [Muscle]'s own declaration order.
  muscle('Muscle group'),

  /// The number the row already shows large: est. 1RM, or reps for a
  /// bodyweight lift.
  best('Best'),

  /// The weight that set the record. Bodyweight lifts have none.
  weight('Weight'),

  /// Reps in the set that set the record.
  reps('Reps');

  const RecordSort(this.label);

  final String label;

  /// The two directions this key can run, natural order first.
  ///
  /// Muscle group runs down a body rather than down a number line, so it names
  /// its own ends instead of borrowing "high" and "low" — which would be a
  /// direction the user has to decode rather than read.
  ///
  /// Worded rather than arrowed: Sora has no `→`, and a label that renders as a
  /// tofu box on the one control whose whole job is stating a direction is not
  /// a label.
  (String, String) get orderLabels => switch (this) {
        RecordSort.muscle => (
            '${Muscle.values.first.label} first',
            '${Muscle.values.last.label} first',
          ),
        _ => ('Highest first', 'Lowest first'),
      };

  /// One line under the order control saying what this key actually ranks, for
  /// the two cases where the label alone leaves a real question ("best of
  /// what?", "where do bodyweight lifts go?").
  String get note => switch (this) {
        RecordSort.muscle => 'Down the body, heaviest first inside each group.',
        RecordSort.best => 'Estimated 1RM — or reps, for a bodyweight lift.',
        RecordSort.weight => 'Bodyweight lifts carry no weight, so they sort last.',
        RecordSort.reps => 'Reps in the set that set the record.',
      };
}

/// Which lifts the list is allowed to show, by how they are loaded.
enum RecordUnit {
  all('All'),
  weighted('Weighted'),
  bodyweight('Bodyweight');

  const RecordUnit(this.label);

  final String label;
}

/// One complete answer to "which records, in what order".
///
/// Immutable, so the sheet can hand a whole new query back on every tap and the
/// screen never has to reason about half-applied state.
@immutable
class RecordQuery {
  const RecordQuery({
    this.sort = RecordSort.best,
    this.reversed = false,
    this.muscles = const {},
    this.unit = RecordUnit.all,
    this.newOnly = false,
  });

  /// What Records opens on: every lift, strongest first. This is the order the
  /// screen has always shipped.
  static const initial = RecordQuery();

  final RecordSort sort;

  /// Whether [sort] runs against its natural direction — see
  /// [RecordSort.orderLabels]. False is always the key's own order: down the
  /// body for [RecordSort.muscle], strongest first for the rest.
  final bool reversed;

  /// The groups to show. Empty means all of them — an empty filter and a
  /// thirteen-of-thirteen filter mean the same thing, and the empty one is the
  /// state the user can reach by deselecting.
  final Set<Muscle> muscles;

  final RecordUnit unit;

  /// Only records set within [ArcData.newRecordDays] — the same window that
  /// puts the "New" tag on a row.
  final bool newOnly;

  bool get isDefault =>
      sort == RecordSort.best &&
      !reversed &&
      muscles.isEmpty &&
      unit == RecordUnit.all &&
      !newOnly;

  /// Whether anything is being hidden. Distinct from [isDefault], which a
  /// re-ordered but unfiltered list also fails.
  bool get isFiltered =>
      muscles.isNotEmpty || unit != RecordUnit.all || newOnly;

  RecordQuery copyWith({
    RecordSort? sort,
    bool? reversed,
    Set<Muscle>? muscles,
    RecordUnit? unit,
    bool? newOnly,
  }) =>
      RecordQuery(
        sort: sort ?? this.sort,
        reversed: reversed ?? this.reversed,
        muscles: muscles ?? this.muscles,
        unit: unit ?? this.unit,
        newOnly: newOnly ?? this.newOnly,
      );

  /// This query with [m] added to or removed from the group filter.
  RecordQuery toggleMuscle(Muscle m) {
    final next = {...muscles};
    if (!next.remove(m)) next.add(m);
    return copyWith(muscles: next);
  }

  /// Everything shown again, in the order the user chose. The escape hatch on
  /// an empty result, which is why it keeps [sort] and [reversed].
  RecordQuery get withoutFilters => RecordQuery(sort: sort, reversed: reversed);

  bool matches(ExerciseRecord r) {
    final best = r.best;
    if (best == null) return false;
    // Secondary groups are deliberately not consulted: the library files a lift
    // under its primary group only, and a filter that disagreed with where the
    // user put the lift would read as a bug.
    if (muscles.isNotEmpty && !muscles.contains(r.ex.muscle)) return false;
    if (unit == RecordUnit.weighted && r.ex.isBodyweight) return false;
    if (unit == RecordUnit.bodyweight && !r.ex.isBodyweight) return false;
    if (newOnly && !ArcData.isNewRecord(best.date)) return false;
    return true;
  }

  List<ExerciseRecord> apply(Iterable<ExerciseRecord> all) {
    final out = all.where(matches).toList();
    out.sort(_compare);
    return out;
  }

  int _compare(ExerciseRecord a, ExerciseRecord b) {
    if (sort == RecordSort.weight) {
      // A bodyweight lift has no weight to rank — it is unranked on this axis
      // rather than zero on it, so it sits after the ranked lifts in *both*
      // directions instead of leading the ascending list with a phantom 0 kg.
      final ua = a.ex.isBodyweight ? 1 : 0;
      final ub = b.ex.isBodyweight ? 1 : 0;
      if (ua != ub) return ua - ub;
    }

    var cmp = switch (sort) {
      RecordSort.muscle => a.ex.muscle.index.compareTo(b.ex.muscle.index),
      RecordSort.best => b.best!.score.compareTo(a.best!.score),
      RecordSort.weight => b.best!.weight.compareTo(a.best!.weight),
      RecordSort.reps => b.best!.reps.compareTo(a.best!.reps),
    };
    if (reversed) cmp = -cmp;
    if (cmp != 0) return cmp;

    // Ties break on strength and then on name, never on the sort direction —
    // so flipping the group order re-stacks the groups without scrambling the
    // ranking inside any one of them.
    final byScore = b.best!.score.compareTo(a.best!.score);
    if (byScore != 0) return byScore;
    return a.ex.name.toLowerCase().compareTo(b.ex.name.toLowerCase());
  }

  @override
  bool operator ==(Object other) =>
      other is RecordQuery &&
      other.sort == sort &&
      other.reversed == reversed &&
      other.unit == unit &&
      other.newOnly == newOnly &&
      setEquals(other.muscles, muscles);

  @override
  int get hashCode => Object.hash(
        sort,
        reversed,
        unit,
        newOnly,
        Object.hashAllUnordered(muscles),
      );
}
