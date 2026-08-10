// Name → muscle-group dictionary.
//
// Used twice: once to backfill the library when a device upgrades off the old
// Push/Pull/Legs/Core taxonomy, and live in the add-exercise sheet to preselect
// a group while the user is still typing the name.
//
// Names are squashed — lowercased, every non-alphanumeric dropped — so
// "Pull-Up", "pull up" and "Pullup" collapse to one key. A pattern matches only
// where it begins at a *word* boundary of the original name, which is what
// stops "Narrow Stance Squat" from matching `row` and filing itself under Lats.
//
// Rules are tried in order and the first hit wins, which makes ordering
// load-bearing: `legcurl` has to be tested before `curl`, `closegripbench`
// before `bench`, `romaniandeadlift` before `deadlift`. Each block below is
// ordered specific → general for exactly that reason; adding a short pattern
// near the top of a block is how you silently break the ones under it.

import 'muscle.dart';

/// What the dictionary thinks an exercise trains.
class MuscleGuess {
  final Muscle primary;
  final List<Muscle> secondary;

  /// True when a dictionary rule actually matched the name. False means this is
  /// a fallback from the coarse region and the user should be offered a chance
  /// to correct it — see the review card on the Exercises screen.
  final bool confident;

  const MuscleGuess(this.primary,
      {this.secondary = const [], this.confident = true});
}

class _Rule {
  final String pattern;
  final Muscle primary;
  final List<Muscle> secondary;
  const _Rule(this.pattern, this.primary, [this.secondary = const []]);
}

/// A name reduced to letters and digits, alongside the offsets at which each
/// of the original words began.
class _Norm {
  final String squashed;
  final List<int> wordStarts;
  const _Norm(this.squashed, this.wordStarts);

  /// True when [pattern] appears in the squashed name starting exactly where
  /// one of the original words did. "barbell row" contains `row` at word start
  /// 7; "narrow stance squat" contains it at 3, mid-word, so it does not count.
  bool hasPatternAtWordStart(String pattern) {
    for (final i in wordStarts) {
      if (squashed.startsWith(pattern, i)) return true;
    }
    return false;
  }
}

class MuscleMap {
  MuscleMap._();

  /// Lowercase, alphanumerics only. "Close-Grip Bench Press" → "closegripbenchpress".
  static String squash(String s) => _normalize(s).squashed;

  /// The dictionary's reading of [name], or null if nothing matched.
  static MuscleGuess? guess(String name) {
    final n = _normalize(name);
    if (n.squashed.isEmpty) return null;
    for (final r in _rules) {
      if (n.hasPatternAtWordStart(r.pattern)) {
        return MuscleGuess(r.primary, secondary: r.secondary);
      }
    }
    return null;
  }

  /// The squashed name plus the offsets where each original word began. Keeping
  /// the word starts is the whole trick: it lets "Barbell Row" match `row`
  /// while "Narrow Stance Squat" does not.
  static _Norm _normalize(String s) {
    final buf = StringBuffer();
    final starts = <int>[];
    var inWord = false;
    for (final c in s.toLowerCase().codeUnits) {
      final isWordChar =
          (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A);
      if (isWordChar) {
        if (!inWord) {
          starts.add(buf.length);
          inWord = true;
        }
        buf.writeCharCode(c);
      } else {
        inWord = false;
      }
    }
    return _Norm(buf.toString(), starts);
  }

  /// Always returns something. Falls back to the default group for [region]
  /// (the old coarse tier) with `confident: false` when no rule matches, so the
  /// exercise is still filed somewhere sensible and still flagged for review.
  static MuscleGuess resolve(String name, {String? region}) =>
      guess(name) ??
      MuscleGuess(
        MuscleRegion.defaultMuscle(region ?? MuscleRegion.push),
        confident: false,
      );

  // ── The dictionary ────────────────────────────────────────────────────
  static const List<_Rule> _rules = [
    // Chest / horizontal press. `closegripbench` and `narrowgrip` variants are
    // triceps-led and have to outrank the bare `bench` rule beneath them.
    _Rule('closegripbench', Muscle.triceps, [Muscle.chest, Muscle.shoulders]),
    _Rule('inclinebench', Muscle.chest, [Muscle.shoulders, Muscle.triceps]),
    _Rule('inclinepress', Muscle.chest, [Muscle.shoulders, Muscle.triceps]),
    _Rule('inclinedumbbell', Muscle.chest, [Muscle.shoulders, Muscle.triceps]),
    _Rule('declinebench', Muscle.chest, [Muscle.triceps]),
    _Rule('declinepress', Muscle.chest, [Muscle.triceps]),
    _Rule('benchpress', Muscle.chest, [Muscle.triceps, Muscle.shoulders]),
    _Rule('chestpress', Muscle.chest, [Muscle.triceps, Muscle.shoulders]),
    _Rule('bench', Muscle.chest, [Muscle.triceps, Muscle.shoulders]),
    _Rule('pecdeck', Muscle.chest, [Muscle.shoulders]),
    _Rule('reversefly', Muscle.shoulders, [Muscle.upperBack]),
    _Rule('reverseflye', Muscle.shoulders, [Muscle.upperBack]),
    _Rule('chestfly', Muscle.chest, [Muscle.shoulders]),
    _Rule('cablecrossover', Muscle.chest, [Muscle.shoulders]),
    _Rule('flies', Muscle.chest, [Muscle.shoulders]),
    _Rule('flye', Muscle.chest, [Muscle.shoulders]),
    _Rule('fly', Muscle.chest, [Muscle.shoulders]),
    _Rule('pushup', Muscle.chest, [Muscle.triceps, Muscle.shoulders]),
    _Rule('pressup', Muscle.chest, [Muscle.triceps, Muscle.shoulders]),
    _Rule('pullover', Muscle.lats, [Muscle.chest, Muscle.triceps]),
    _Rule('dip', Muscle.triceps, [Muscle.chest, Muscle.shoulders]),

    // Shoulders. `facepull` and `uprightrow` sit above the back block so the
    // generic `pull` / `row` rules can't claim them.
    _Rule('facepull', Muscle.upperBack, [Muscle.shoulders]),
    _Rule('uprightrow', Muscle.shoulders, [Muscle.upperBack, Muscle.biceps]),
    _Rule('shrug', Muscle.upperBack, [Muscle.forearms]),
    _Rule('overheadpress', Muscle.shoulders, [Muscle.triceps]),
    _Rule('militarypress', Muscle.shoulders, [Muscle.triceps]),
    _Rule('shoulderpress', Muscle.shoulders, [Muscle.triceps]),
    _Rule('pushpress', Muscle.shoulders, [Muscle.triceps]),
    _Rule('arnoldpress', Muscle.shoulders, [Muscle.triceps]),
    _Rule('landminepress', Muscle.shoulders, [Muscle.triceps, Muscle.chest]),
    _Rule('ohp', Muscle.shoulders, [Muscle.triceps]),
    _Rule('lateralraise', Muscle.shoulders),
    _Rule('sideraise', Muscle.shoulders),
    _Rule('latraise', Muscle.shoulders),
    _Rule('frontraise', Muscle.shoulders),
    _Rule('reardelt', Muscle.shoulders, [Muscle.upperBack]),
    _Rule('deltraise', Muscle.shoulders),

    // Back + posterior chain. Every deadlift variant is spelled out before the
    // bare `deadlift` rule, because they lead with different muscles.
    _Rule('romaniandeadlift', Muscle.hamstrings, [Muscle.glutes, Muscle.lowerBack]),
    _Rule('rdl', Muscle.hamstrings, [Muscle.glutes, Muscle.lowerBack]),
    _Rule('stifflegdeadlift', Muscle.hamstrings, [Muscle.glutes, Muscle.lowerBack]),
    _Rule('stiffleg', Muscle.hamstrings, [Muscle.glutes, Muscle.lowerBack]),
    _Rule('sumodeadlift', Muscle.glutes,
        [Muscle.hamstrings, Muscle.quads, Muscle.lowerBack]),
    _Rule('trapbardeadlift', Muscle.quads,
        [Muscle.glutes, Muscle.hamstrings, Muscle.lowerBack]),
    _Rule('deficitdeadlift', Muscle.lowerBack, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('deadlift', Muscle.lowerBack,
        [Muscle.glutes, Muscle.hamstrings, Muscle.upperBack]),
    _Rule('goodmorning', Muscle.hamstrings, [Muscle.lowerBack, Muscle.glutes]),
    _Rule('backextension', Muscle.lowerBack, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('hyperextension', Muscle.lowerBack, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('straightarmpulldown', Muscle.lats),
    _Rule('latpulldown', Muscle.lats, [Muscle.biceps, Muscle.upperBack]),
    _Rule('pulldown', Muscle.lats, [Muscle.biceps, Muscle.upperBack]),
    _Rule('pullup', Muscle.lats, [Muscle.biceps, Muscle.upperBack]),
    _Rule('chinup', Muscle.lats, [Muscle.biceps, Muscle.upperBack]),
    _Rule('tbarrow', Muscle.upperBack, [Muscle.lats, Muscle.biceps]),
    _Rule('pendlayrow', Muscle.upperBack, [Muscle.lats, Muscle.biceps]),
    _Rule('seatedrow', Muscle.upperBack, [Muscle.lats, Muscle.biceps]),
    _Rule('cablerow', Muscle.upperBack, [Muscle.lats, Muscle.biceps]),
    _Rule('inverted', Muscle.upperBack, [Muscle.lats, Muscle.biceps]),
    _Rule('row', Muscle.lats, [Muscle.upperBack, Muscle.biceps]),

    // Arms. `legcurl` / `wristcurl` / `reversecurl` must all outrank `curl`.
    _Rule('legcurl', Muscle.hamstrings, [Muscle.calves]),
    _Rule('hamstringcurl', Muscle.hamstrings, [Muscle.calves]),
    _Rule('nordiccurl', Muscle.hamstrings, [Muscle.glutes]),
    _Rule('wristcurl', Muscle.forearms),
    _Rule('reversecurl', Muscle.forearms, [Muscle.biceps]),
    _Rule('hammercurl', Muscle.biceps, [Muscle.forearms]),
    _Rule('curl', Muscle.biceps, [Muscle.forearms]),
    _Rule('skullcrusher', Muscle.triceps),
    _Rule('tricepextension', Muscle.triceps),
    _Rule('overheadextension', Muscle.triceps),
    _Rule('pushdown', Muscle.triceps),
    _Rule('pressdown', Muscle.triceps),
    _Rule('kickback', Muscle.triceps),
    _Rule('tricep', Muscle.triceps),
    _Rule('jmpress', Muscle.triceps, [Muscle.chest]),

    // Forearms. Kept below the back and arm blocks so "Wide Grip Pulldown" and
    // "Close-Grip Bench" resolve on their own terms first.
    _Rule('farmer', Muscle.forearms, [Muscle.upperBack]),
    _Rule('wristroller', Muscle.forearms),
    _Rule('gripper', Muscle.forearms),
    _Rule('deadhang', Muscle.forearms, [Muscle.lats]),
    _Rule('wrist', Muscle.forearms),

    // Abs / trunk.
    _Rule('cablecrunch', Muscle.abs),
    _Rule('crunch', Muscle.abs),
    _Rule('situp', Muscle.abs),
    _Rule('legraise', Muscle.abs),
    _Rule('toestobar', Muscle.abs, [Muscle.lats]),
    _Rule('kneeraise', Muscle.abs),
    _Rule('plank', Muscle.abs),
    _Rule('abwheel', Muscle.abs),
    _Rule('abrollout', Muscle.abs),
    _Rule('rollout', Muscle.abs),
    _Rule('russiantwist', Muscle.abs),
    _Rule('deadbug', Muscle.abs),
    _Rule('hollowhold', Muscle.abs),
    _Rule('woodchop', Muscle.abs),
    _Rule('oblique', Muscle.abs),
    _Rule('hangingleg', Muscle.abs),

    // Legs.
    _Rule('legextension', Muscle.quads),
    _Rule('legpress', Muscle.quads, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('hacksquat', Muscle.quads, [Muscle.glutes]),
    _Rule('frontsquat', Muscle.quads, [Muscle.glutes, Muscle.abs]),
    _Rule('splitsquat', Muscle.quads, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('gobletsquat', Muscle.quads, [Muscle.glutes]),
    _Rule('sissysquat', Muscle.quads),
    _Rule('squat', Muscle.quads, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('lunge', Muscle.quads, [Muscle.glutes, Muscle.hamstrings]),
    _Rule('stepup', Muscle.quads, [Muscle.glutes]),
    _Rule('sled', Muscle.quads, [Muscle.glutes, Muscle.calves]),
    _Rule('hipthrust', Muscle.glutes, [Muscle.hamstrings]),
    _Rule('glutebridge', Muscle.glutes, [Muscle.hamstrings]),
    _Rule('gluteham', Muscle.hamstrings, [Muscle.glutes]),
    _Rule('kickthrough', Muscle.glutes),
    _Rule('abduction', Muscle.glutes),
    _Rule('adduction', Muscle.quads, [Muscle.glutes]),
    _Rule('glute', Muscle.glutes, [Muscle.hamstrings]),
    _Rule('nordic', Muscle.hamstrings, [Muscle.glutes]),
    _Rule('calfraise', Muscle.calves),
    _Rule('calf', Muscle.calves),
    _Rule('tibialis', Muscle.calves),
  ];
}
