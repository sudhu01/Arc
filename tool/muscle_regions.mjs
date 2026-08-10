// Where each muscle group lives on the body, in normalised model space.
//
// Coordinates: metres, feet at y=0, crown at y=1.8, +x is the figure's own
// left, +z is forward. These match the landmarks read off the MakeHuman
// skeleton, so a site can be moved by reading anatomy rather than by guessing
// at numbers.
//
// Classification is a weighted nearest-site test: every vertex on the mesh goes
// to whichever site is closest after its own anisotropic scaling and weight.
// That beats a cascade of if-statements because boundaries come out smooth and
// each region is tuned by one number instead of by re-ordering rules — and it
// works on *any* human mesh, which is what lets the source model be swapped.

/// Muscle ids, in the exact order of `Muscle` in lib/data/muscle.dart. The
/// shader indexes its heat array by these, so the two orders must not drift.
export const MUSCLE_IDS = [
  'chest',      // 0
  'shoulders',  // 1
  'upperBack',  // 2
  'lats',       // 3
  'lowerBack',  // 4
  'biceps',     // 5
  'triceps',    // 6
  'forearms',   // 7
  'abs',        // 8
  'quads',      // 9
  'hamstrings', // 10
  'glutes',     // 11
  'calves',     // 12
];

/// Head, neck, hands and feet. They glow with the rest of the body but carry no
/// training volume and take no taps — there is no such thing as a hand day.
export const STRUCTURAL = 13;

const id = (name) => MUSCLE_IDS.indexOf(name);

/// A site is a point (`a`) or a segment (`a`→`b`) that claims nearby surface.
///
/// - `w`      how far it reaches; bigger claims more.
/// - `scale`  anisotropy applied before measuring. Torso sites squash x and
///            stretch z, which is what keeps chest from bleeding into lats
///            around the ribcage.
/// - `fibre`  the direction the muscle pulls, used for the striation shader.
/// - `mirror` duplicated across the centre line (left and right are one group).
export const SITES = [
  // ── Torso, front ────────────────────────────────────────────────────
  {
    muscle: id('chest'),
    a: [0.020, 1.372, 0.088], b: [0.125, 1.392, 0.040],
    w: 1.00, scale: [1.0, 1.15, 0.72], fibre: [1, 0.1, 0], mirror: true,
  },
  {
    muscle: id('abs'),
    a: [0.000, 1.255, 0.092], b: [0.000, 1.015, 0.080],
    w: 0.98, scale: [0.78, 1.0, 0.70], fibre: [0, 1, 0],
  },

  // ── Torso, back ─────────────────────────────────────────────────────
  {
    muscle: id('upperBack'),
    a: [0.000, 1.462, -0.048], b: [0.128, 1.418, -0.042],
    w: 1.02, scale: [1.0, 1.05, 0.75], fibre: [1, 0.35, 0], mirror: true,
  },
  {
    // Sweeps from the armpit down toward the waist — the widest part of the
    // back, and the one that most needs to stay off the lower-back site.
    muscle: id('lats'),
    a: [0.135, 1.352, -0.020], b: [0.088, 1.170, -0.030],
    w: 1.00, scale: [0.86, 1.0, 0.80], fibre: [0.55, -0.83, 0], mirror: true,
  },
  {
    muscle: id('lowerBack'),
    a: [0.000, 1.130, -0.072], b: [0.036, 1.010, -0.070],
    w: 0.95, scale: [0.90, 1.0, 0.70], fibre: [0, 1, 0], mirror: true,
  },

  // ── Shoulder cap ────────────────────────────────────────────────────
  {
    // A point rather than a segment: the deltoid wraps the joint, and it has to
    // outrank chest, upper back and upper arm all at once right here.
    muscle: id('shoulders'),
    a: [0.178, 1.452, 0.014],
    w: 1.12, scale: [1.0, 1.0, 1.0], fibre: [0, -1, 0], mirror: true,
  },

  // ── Arms ────────────────────────────────────────────────────────────
  {
    muscle: id('biceps'),
    a: [0.212, 1.404, 0.062], b: [0.330, 1.276, 0.058],
    w: 0.94, scale: [1.0, 1.0, 0.80], fibre: [0.63, -0.78, 0], mirror: true,
  },
  {
    muscle: id('triceps'),
    a: [0.216, 1.400, -0.044], b: [0.334, 1.272, -0.038],
    w: 0.96, scale: [1.0, 1.0, 0.80], fibre: [0.63, -0.78, 0], mirror: true,
  },
  {
    muscle: id('forearms'),
    a: [0.360, 1.238, 0.048], b: [0.452, 1.162, 0.168],
    w: 1.05, scale: [1.0, 1.0, 1.0], fibre: [0.72, -0.55, 0.42], mirror: true,
  },

  // ── Legs ────────────────────────────────────────────────────────────
  {
    muscle: id('quads'),
    a: [0.122, 0.888, 0.062], b: [0.166, 0.545, 0.058],
    w: 1.04, scale: [1.0, 1.0, 0.78], fibre: [0.08, -1, 0], mirror: true,
  },
  {
    muscle: id('hamstrings'),
    a: [0.124, 0.856, -0.068], b: [0.168, 0.548, -0.052],
    w: 1.00, scale: [1.0, 1.0, 0.78], fibre: [0.08, -1, 0], mirror: true,
  },
  {
    muscle: id('glutes'),
    a: [0.092, 0.960, -0.086],
    w: 1.06, scale: [1.0, 0.92, 0.85], fibre: [0.4, -0.9, 0], mirror: true,
  },
  {
    muscle: id('calves'),
    a: [0.196, 0.440, -0.040], b: [0.232, 0.150, -0.020],
    w: 1.10, scale: [1.0, 1.0, 1.0], fibre: [0.1, -1, 0], mirror: true,
  },

  // ── Structural ──────────────────────────────────────────────────────
  {
    muscle: STRUCTURAL,
    a: [0.000, 1.560, 0.010], b: [0.000, 1.790, 0.020], // neck + head
    w: 1.30, scale: [1.0, 1.0, 1.0], fibre: [0, 1, 0],
  },
  {
    muscle: STRUCTURAL,
    a: [0.466, 1.148, 0.190], b: [0.474, 1.090, 0.205], // hand
    w: 1.00, scale: [1.0, 1.0, 1.0], fibre: [0.7, -0.7, 0], mirror: true,
  },
  {
    muscle: STRUCTURAL,
    a: [0.237, 0.055, 0.060], b: [0.237, 0.020, 0.230], // foot
    w: 1.00, scale: [1.0, 1.0, 1.0], fibre: [0, 0, 1], mirror: true,
  },
];

/// Expands `mirror` sites into an explicit left/right pair. Fibre direction
/// mirrors with the geometry so striations run the right way on both sides.
export function expandSites() {
  const out = [];
  for (const s of SITES) {
    out.push(s);
    if (!s.mirror) continue;
    out.push({
      ...s,
      a: [-s.a[0], s.a[1], s.a[2]],
      b: s.b ? [-s.b[0], s.b[1], s.b[2]] : undefined,
      fibre: [-s.fibre[0], s.fibre[1], s.fibre[2]],
    });
  }
  return out;
}
