import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/muscle.dart';
import 'oklch.dart';

/// One colour per muscle group, derived from one hue each.
///
/// Arc shipped four group colours for the four movement regions, so nine of the
/// thirteen groups wore a colour that belonged to a neighbour: chest, shoulders
/// and triceps were the same coral. That is fine when the dot only ever claims
/// "Push", and wrong now that the dot sits beside a group name.
///
/// ## Why hue is the only thing the user picks
///
/// Same reasoning as [AccentRamp], and the same guarantee. A dot is 9–14px of
/// colour on a card; it survives that size only at a lightness that separates it
/// from the surface, and a picker that let a group go near-white in the light
/// theme would hand the user a group they cannot see. So every dot is pinned to
/// `oklch(0.68 0.15 H)` — the exact recipe the four shipped colours were built
/// from — and the user moves H.
///
/// Pinning lightness buys a second thing worth more than the freedom it costs:
/// **no group can outshout another.** Thirteen dots at one lightness read as one
/// set. Let lightness float and the palette becomes a hierarchy nobody asked for,
/// with the bright groups reading as important and the dark ones as disabled.
///
/// Chroma is `min(0.15, maxChroma)` because 0.15 is unreachable in the
/// cyan/teal quarter (the gamut floor there is ~0.116). Those hues land a little
/// quieter than the rest; that is the sRGB gamut, not a choice.
///
/// ## Contrast
///
/// At L = 0.68 a dot holds 5.6:1 against the darkest Midnight surface and
/// 2.5:1 against the palest Surge one, at every hue. The light-theme figure is
/// under 3:1, which is the ratio the shipped four have always had — group
/// identity is never carried by colour alone (PRODUCT's accessibility rule), the
/// label is always adjacent, so the dot is a locator rather than the
/// information. Raising L to clear 3:1 would repaint the shipped palette pale;
/// the swatches inside the picker, where colour *is* the content, carry a border
/// instead so they never float on the surface.
class MuscleRamp {
  MuscleRamp._();

  /// The recipe every group dot is built from — and the recipe the four shipped
  /// region colours turn out to have been built from, exactly:
  /// `#E66F62 #539AF2 #45B164 #C077D1` are `oklch(0.68 0.15 H)` at H = 28, 255,
  /// 150 and 320.
  static const lightness = 0.68;
  static const chroma = 0.15;

  /// The hue each region's shipped colour sits at. Kept because the defaults
  /// below are laid out around them: see [defaultHues].
  static const regionAnchorHue = <String, int>{
    MuscleRegion.push: 28,
    MuscleRegion.pull: 255,
    MuscleRegion.legs: 150,
    MuscleRegion.core: 320,
  };

  /// Where each group starts for a new install.
  ///
  /// Three rules produced this table, in priority order:
  ///
  /// 1. **Every region keeps a contiguous arc of the hue circle, centred on the
  ///    colour it ships with today.** Push is still the warm quarter, Pull still
  ///    the cool one. A user who has been reading these dots for months does not
  ///    have to relearn them — the family moved apart, it did not move.
  /// 2. **The arcs are centred, not merely near.** The circular mean of each
  ///    region's hues lands *on* its anchor, which is what lets
  ///    [MusclePalette.regionColor] reproduce `#E66F62`, `#539AF2`, `#45B164`
  ///    and `#C077D1` bit-exactly from the thirteen — so the calendar and the
  ///    session dots, which speak the coarse tier, are untouched by this change.
  ///    Chest, lats and abs land exactly on their region's shipped colour too.
  /// 3. **No two groups sit closer than 21°.** Swept over all thirteen; the
  ///    tightest pair is biceps → abs. At L = 0.68 that is roughly 2.5× the
  ///    just-noticeable hue step, so adjacent rows in the library are separable
  ///    rather than merely different.
  ///
  /// The 58° hole between shoulders and glutes is deliberate: it is the yellow
  /// band, where the sRGB gamut collapses to ~0.139 chroma at this lightness and
  /// every hue turns to mustard. Nothing good lives there, so nothing is filed
  /// there.
  ///
  /// One consequence worth the table: all thirteen defaults get a *different*
  /// name out of [nameFor] — Coral, Amber, Rose, Azure, Blue, Indigo, Violet,
  /// Cyan, Orchid, Green, Emerald, Olive, Teal. The readout in the picker can
  /// therefore say something a person repeats out loud.
  static const defaultHues = <Muscle, int>{
    // Push — the warm arc, centred on 28°.
    Muscle.chest: 28, // Coral   #E66F62 — the shipped Push colour, exactly
    Muscle.shoulders: 56, // Amber   #DC7C29
    Muscle.triceps: 0, // Rose    #E06C94
    // Pull — the cool arc, centred on 255°.
    Muscle.upperBack: 233, // Azure   #00A5E0
    Muscle.lats: 255, // Blue    #539AF2 — the shipped Pull colour, exactly
    Muscle.lowerBack: 277, // Indigo  #828DF3
    Muscle.biceps: 299, // Violet  #A681E7
    Muscle.forearms: 211, // Cyan    #00ABC1
    // Core — one group, so it simply keeps its anchor.
    Muscle.abs: 320, // Orchid  #C077D1 — the shipped Core colour, exactly
    // Legs — the green arc, centred on 150°. Four members cannot straddle a
    // centre without one of them standing on it, so quads takes the slot
    // nearest the anchor rather than the anchor itself.
    Muscle.quads: 138, // Green   #67AD4C
    Muscle.hamstrings: 162, // Emerald #00B47B
    Muscle.glutes: 114, // Olive   #98A20E
    Muscle.calves: 186, // Teal    #00B0A3
  };

  static int defaultHue(Muscle m) => defaultHues[m] ?? regionAnchorHue[m.region]!;

  /// Keyed by hue. Thirteen dots repaint on every frame of a slider drag and the
  /// ramp under the thumb adds 25 more, each of which runs a binary search over
  /// the gamut — without this a drag re-solves ~500 times a second.
  static final _cache = <int, Color>{};

  /// The dot colour for [hue].
  static Color color(int hue) {
    final h = hue % 360;
    return _cache.putIfAbsent(h, () {
      final c = math.min(chroma, Oklch.maxChroma(lightness, h.toDouble()));
      return Oklch.toColor(lightness, c, h.toDouble());
    });
  }

  /// Fourteen bands around the circle, named for what the colour actually looks
  /// like *at this lightness*. [AccentRamp]'s names are tuned to the accent's
  /// much higher lightness and would call 114° "Volt" here, where it is olive.
  ///
  /// Factual and athletic per PRODUCT's voice — the names a paint chart would
  /// use, not the ones a smoothie menu would.
  static const _names = <(int, String)>[
    (14, 'Rose'),
    (42, 'Coral'),
    (70, 'Amber'),
    (126, 'Olive'),
    (150, 'Green'),
    (174, 'Emerald'),
    (198, 'Teal'),
    (222, 'Cyan'),
    (244, 'Azure'),
    (266, 'Blue'),
    (288, 'Indigo'),
    (310, 'Violet'),
    (334, 'Orchid'),
  ];

  static String nameFor(int hue) {
    final h = hue % 360;
    for (final (upper, name) in _names) {
      if (h < upper) return name;
    }
    return 'Rose'; // 334..359 wraps back
  }

  /// Shortest distance between two hues on the circle, 0..180.
  static int distance(int a, int b) {
    final d = ((a - b) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }
}

/// Holds the group hues currently in force.
///
/// Read through statics for the same reason [ArcTheme] is: Arc's widgets take
/// their colours from plain getters rather than an inherited theme, and a dot
/// three levels inside a list row should not have to be handed a controller to
/// know what colour it is. `MusclePaletteController` owns the values and
/// rebuilds the tree; this is what the tree reads on the way back down.
class MusclePalette {
  MusclePalette._();

  static Map<Muscle, int> _hues = MuscleRamp.defaultHues;

  /// Replaces the whole map. Callers pass a complete table — the controller
  /// merges its overrides over the defaults before calling.
  static void apply(Map<Muscle, int> hues) {
    _hues = hues;
    _regionCache.clear();
  }

  static int hueOf(Muscle m) => _hues[m] ?? MuscleRamp.defaultHue(m);

  /// The colour of one muscle group.
  static Color of(Muscle m) => MuscleRamp.color(hueOf(m));

  static final _regionCache = <String, Color>{};

  /// The colour of a coarse region — Push | Pull | Legs | Core — for the
  /// surfaces that speak that tier: the calendar's day dots and legend, and the
  /// dot beside a session's title.
  ///
  /// Computed as the *circular mean* of the region's member hues rather than
  /// held as a fifth set of constants, so it is always an honest summary of the
  /// groups underneath it. Recolour every push group to blue and the calendar's
  /// push dot follows; leave the defaults alone and it returns the four colours
  /// Arc has always drawn here, to the byte.
  static Color regionColor(String region) {
    return _regionCache.putIfAbsent(region, () {
      final members = Muscle.inRegion(region);
      if (members.isEmpty) return MuscleRamp.color(MuscleRamp.regionAnchorHue[region] ?? 28);
      var x = 0.0;
      var y = 0.0;
      for (final m in members) {
        final r = hueOf(m) * math.pi / 180;
        x += math.cos(r);
        y += math.sin(r);
      }
      // Degenerate only if the members are spread perfectly evenly around the
      // circle, which no reachable set of thirteen integers on four groups
      // reaches — but a mean of nothing has no colour, so fall back rather than
      // hand atan2 a pair of zeroes.
      if (x.abs() < 1e-9 && y.abs() < 1e-9) {
        return MuscleRamp.color(hueOf(members.first));
      }
      final deg = math.atan2(y, x) * 180 / math.pi;
      return MuscleRamp.color(deg.round() % 360);
    });
  }

  /// Cheap identity of the whole palette, for the widget key that forces the
  /// shell to rebuild when a colour changes. Order-independent additions would
  /// collide, so this folds position in.
  static int get signature {
    var h = 17;
    for (final m in Muscle.values) {
      h = h * 31 + hueOf(m);
    }
    return h;
  }
}
