// Arc's body renderer.
//
// The figure is a cloud of ~300,000 points sampled evenly across a human mesh,
// not a lit solid. That choice is the whole look: additive points accumulate
// where the surface turns away from the camera, so silhouette edges blow out on
// their own — the rim light in the reference is not a shader trick there, it is
// what you get when you can see through a volume tangentially. Overlapping
// surfaces sum instead of occluding, which is what reads as tissue rather than
// plastic.
//
// Points are baked once at load and never simulated. The technique this borrows
// from drives particles with a GPGPU velocity field so they can flee a cursor;
// Arc's body only turns and lights up, so the ping-pong render targets and the
// float-texture support they need would buy nothing and cost a lot on a phone.
// A cheap vertex-shader shimmer covers the difference.
//
// The mesh still exists — invisible, purely as a raycast collider, so tapping a
// muscle stays exact.
//
// Nothing here draws text. The figure is unlabelled by design: a tap reports
// which group was hit and Flutter opens that group's sheet, so the naming
// happens there rather than floating over the body.

import * as THREE from 'three';
import { EffectComposer } from './addons/postprocessing/EffectComposer.js';
import { RenderPass } from './addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from './addons/postprocessing/UnrealBloomPass.js';
import { ShaderPass } from './addons/postprocessing/ShaderPass.js';
import { OutputPass } from './addons/postprocessing/OutputPass.js';

// ── Bridge ─────────────────────────────────────────────────────────────
const send = (msg) => {
  try {
    window.ArcChannel.postMessage(JSON.stringify(msg));
  } catch (_) {
    /* Running outside the app shell; harmless. */
  }
};

const MUSCLE_IDS = [
  'chest', 'shoulders', 'upperBack', 'lats', 'lowerBack', 'biceps', 'triceps',
  'forearms', 'abs', 'quads', 'hamstrings', 'glutes', 'calves',
];
const STRUCTURAL = 13;
const SLOTS = 14; // 13 groups + structural

const PARTICLE_COUNT = 300000;

/// Centre of the figure. Feet at 0, crown at 1.8.
const BODY_MID = 0.9;

/// The baked vertex positions, kept past load so framing can be solved against
/// the real figure. Measured rather than written down: a hardcoded width is a
/// silent trap the moment the source model is swapped — which
/// `tool/prepare_body.mjs` is explicitly built to allow — and the constant this
/// replaced was about a third short for the mesh already in the repo.
let framePositions = null;

/// Breathing room around the figure, as a fraction of its own size.
///
/// Wider than the framing alone wants, because the figure is not the only thing
/// on screen — its glow is, and a glow needs somewhere to go. Bloom is a blur
/// inside a render target, so any halo that reaches the boundary is not faded
/// there, it is cut there, and a cut halo draws the edge of the canvas as a
/// line. At the 1.07 this replaced the crown and the feet sat about 3% of the
/// frame from the edge, which is less than the bloom kernel's own reach.
const FRAME_MARGIN = 1.20;

const stage = document.getElementById('stage');

// ── Renderer ───────────────────────────────────────────────────────────

/// Device pixels per CSS pixel, clamped. Past 2× nothing about a cloud of soft
/// sprites is resolvable and the cost of the buffer is quadratic.
const pixelRatio = () => Math.min(window.devicePixelRatio || 1, 2);

/// What the composer's targets are scaled by against that. Half resolution: on
/// a mid-range Android this is the difference between 60 and 30, and at this
/// blur radius nobody can tell.
const COMPOSER_SCALE = 0.5;

const renderer = new THREE.WebGLRenderer({
  antialias: false, // points are round sprites; MSAA does nothing for them
  alpha: false,
  powerPreference: 'high-performance',
});
renderer.setPixelRatio(pixelRatio());
// Additive points routinely stack past 1.0, and ACES is what turns that
// overflow into a white-hot core that rolls off instead of a flat clipped
// patch of accent. It is the single biggest reason this reads as light rather
// than as green paint.
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.00;
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();

// A long lens: at 30° the figure keeps human proportions instead of the
// bulbous near-field distortion a wide default would give it.
const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 50);

/// Distance at which the whole figure fits the current viewport with a margin.
/// Computed rather than fixed because this view is a different shape on every
/// device, and a constant that frames well on one crops the feet on another.
function fitDistance() {
  const vFov = (camera.fov * Math.PI) / 180;
  const tanV = Math.tan(vFov / 2);
  const tanH = tanV * camera.aspect;
  if (!framePositions) return 1.96 / 2 / tanV;

  // Solved per vertex rather than off a bounding box, because the parts that
  // reach furthest sideways — the hands — also sit well forward of the
  // turntable axis, and a vertex nearer the camera needs more distance to fit
  // than its x alone implies. A box fit is what left the fingers cut off.
  //
  // `dist >= |x| / tan(hFov/2) + z` is that relationship rearranged, and the
  // largest answer over every vertex frames all of them. |z| rather than z
  // covers both settled views: the turntable snaps to front or back, and a
  // half turn puts the same vertex the same distance the other side of centre.
  let d = 0;
  for (let i = 0; i < framePositions.length; i += 3) {
    const ax = Math.abs(framePositions[i]) * FRAME_MARGIN;
    const ay = Math.abs(framePositions[i + 1] - BODY_MID) * FRAME_MARGIN;
    const az = Math.abs(framePositions[i + 2]);
    d = Math.max(d, ax / tanH + az, ay / tanV + az);
  }
  return d;
}

let camDist = 4.0;
camera.position.set(0, BODY_MID, camDist);

const model = new THREE.Group();
scene.add(model);

// ── Theme ──────────────────────────────────────────────────────────────
// Every colour is kept twice over, because the two polarities send them through
// different pipelines and the pipelines want different spaces.
//
// Dark composes, and OutputPass encodes linear to sRGB on the way out — so what
// is written there belongs in three's linear working space, which is what
// `Color.setStyle` produces.
//
// Light skips the composer — multiplied ink has nothing to bloom — and skips
// that encode with it. A linear value written there lands in the drawing buffer
// raw and is then read as though it were already sRGB, which is far darker than
// it should be. The ink is the visible casualty: the figure's colour is a dark
// green chosen so both polarities read as the same body, and in linear form it
// is a tenth as bright with no tint left in it at all — a neutral near-black.
// That, not the ink shading, is why the light figure had no colour in it.
//
// So each colour is held in the working space *and* exactly as the app authored
// it, and `tint` writes whichever one the current polarity's buffer wants.
const theme = {
  field: new THREE.Color('#07080a'),
  accent: new THREE.Color('#c9f24a'),
  ink: new THREE.Color('#171a1f'),
};

/// The same colours, 0-1, straight off the hex with no colour-space conversion
/// of any kind. Replaced wholesale when the app sends a theme.
const themeSRGB = {
  field: [0.027, 0.031, 0.039],
  accent: [0.788, 0.949, 0.290],
  ink: [0.090, 0.102, 0.122],
};

let polarity = 1; // 1 = glow on black, 0 = ink on paper

/// Writes theme colour [name] into [out], in whichever space this polarity's
/// buffer wants: linear where a downstream pass will encode it, raw sRGB where
/// nothing will.
///
/// Assigned component-wise on purpose — every `set`-style call on a Color runs
/// a colour-space conversion, and both forms are already in the space they are
/// headed for.
function tint(out, name) {
  if (polarity > 0.5) return out.copy(theme[name]);
  const c = themeSRGB[name];
  out.r = c[0];
  out.g = c[1];
  out.b = c[2];
  return out;
}

// ── Field colour ───────────────────────────────────────────────────────
// The ground behind the figure has to be the app's own background exactly, or
// the view reads as a panel of a slightly different shade cut into the screen.
// The light path gets there on `tint` alone — the authored sRGB, which nothing
// downstream will touch.
//
// Dark needs one more step. OutputPass tone maps before it encodes, and ACES —
// there to roll off the cloud's additive highlights — treats the background the
// same way and crushes near-black hard: #0C0F17 arrived as roughly #020608. So
// what is written there is not the field but whatever comes back out as it.

/// `#rrggbb` to 0-1 components, with no colour-space conversion of any kind.
function readHex(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex).trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
}

/// three's `ACESFilmicToneMapping`, ported. GLSL's `mat3` constructor takes
/// columns, so these rows are the transposes of the ones in ToneMapping.js.
const ACES_IN = [
  [0.59719, 0.35458, 0.04823],
  [0.07600, 0.90834, 0.01566],
  [0.02840, 0.13383, 0.83777],
];
const ACES_OUT = [
  [1.60475, -0.53108, -0.07367],
  [-0.10208, 1.10813, -0.00605],
  [-0.00327, -0.07276, 1.07602],
];
const mul3 = (m, v) => m.map((r) => r[0] * v[0] + r[1] * v[1] + r[2] * v[2]);

function acesFilmic(rgb) {
  const c = rgb.map((x) => x * (renderer.toneMappingExposure / 0.6));
  const a = mul3(ACES_IN, c);
  const fit = a.map(
    (v) =>
      (v * (v + 0.0245786) - 0.000090537) /
      (v * (0.983729 * v + 0.4329510) + 0.238081),
  );
  return mul3(ACES_OUT, fit).map((v) => Math.min(1, Math.max(0, v)));
}

/// Numerically undoes [acesFilmic]. The curve has a matrix either side of it,
/// so the channels are coupled and there is no tidy closed form — but this runs
/// on one constant colour and only when the theme changes, so a short damped
/// fixed-point search is far cheaper than being clever.
function inverseAces(target) {
  const v = target.slice();
  for (let i = 0; i < 80; i++) {
    const out = acesFilmic(v);
    for (let k = 0; k < 3; k++) {
      if (target[k] <= 0) { v[k] = 0; continue; }
      // Climb by a fixed step where the curve has flattened to nothing, since
      // there is no ratio to scale by down there.
      v[k] = out[k] > 1e-7
        ? v[k] * Math.pow(target[k] / out[k], 0.7)
        : v[k] + 0.01;
    }
  }
  return v;
}

/// The values actually written into the buffer, each in whichever space the
/// current polarity's pipeline wants. Instances of their own rather than
/// pointers into `theme`, which only ever holds the linear form.
const fieldOut = new THREE.Color();
const inkOut = new THREE.Color();
const backdropAccent = new THREE.Color();

/// Points the backdrop and the clear colour at the pre-corrected field.
function applyField() {
  const c = polarity > 0.5
      ? inverseAces([theme.field.r, theme.field.g, theme.field.b])
      : themeSRGB.field;
  // Component-wise for the same reason `tint` is; see the note there.
  fieldOut.r = c[0];
  fieldOut.g = c[1];
  fieldOut.b = c[2];
  backdrop.material.uniforms.uField.value = fieldOut;
  // Same value again, for the pass that eases the composed frame onto it.
  // Copied rather than shared: ShaderPass clones the uniforms it is handed.
  edgeFade.uniforms.uField.value.copy(fieldOut);
  renderer.setClearColor(fieldOut, 1);
}

// ── Material ───────────────────────────────────────────────────────────
const uniforms = {
  uTime: { value: 0 },
  uSize: { value: 1 },
  // Accent stays linear: it is read only in the additive branch, which is the
  // dark path, and that one does get encoded on the way out. Ink is read only
  // in the multiply branch, which is the light path, and that one does not —
  // hence its own instance rather than `theme.ink`.
  uAccent: { value: theme.accent },
  uInk: { value: inkOut },
  uPolarity: { value: 1 },
  uHeat: { value: new Float32Array(SLOTS) },
  uSelected: { value: -1 },
  // Per-particle, and deliberately tiny. Points blend additively and overlap
  // roughly five deep on the torso, so what one particle contributes is a
  // fraction of what any pixel ends up with. Tuning these as if they were a
  // surface's brightness blows the whole figure to white.
  uCore: { value: 0.040 },
  uRim: { value: 0.260 },
  uRimPow: { value: 2.0 },
  // Head, neck, hands and feet, scaled against the muscle values above. They
  // carry no training volume and take no taps, so they are context, not
  // content — but left at parity they render *brighter* than any muscle, for
  // two compounding reasons. They sit in a shell a quarter as deep (see
  // `scatter`), so their points stack far harder where the surface grazes the
  // camera; and being deep inside one large region they never come near a
  // group border, so they escape the groove dimming that every muscle takes.
  // The rim is the bigger offender of the two, which is why it is cut further.
  uStructCore: { value: 0.62 },
  uStructRim: { value: 0.30 },
  uHeatGain: { value: 0.600 },
  uGroove: { value: 0.22 },
  uStripe: { value: 168.0 },
  uCenterDist: { value: 4.0 },
  // Light polarity only; see the ink branch of the fragment shader, which is
  // where the shape of all four of these is argued.
  //
  // Both of the first two are stated as the *page's* optical density rather
  // than one particle's, so they mean something a person can go and look at.
  // A resting muscle turned square to the camera accumulates about 0.27 of it,
  // which is the ~78% grey the figure rests at; the same muscle at the edge of
  // a limb runs to black, and the gradient between the two is the form.
  uInkGain: { value: 4.2 },
  // Range compressor. Resting and fully worked surface are about 22× apart in
  // intensity; through a multiply that is far more than one page can hold, and
  // every muscle carrying any volume lands on black together. Flatter than this
  // and a resting limb is barely off the paper; steeper and the lit middle of
  // each form narrows to a strip with black either side.
  uInkCurve: { value: 0.72 },
  // How deep the sprite stack runs on an average pixel of the figure. Computed
  // by [stackDepth] rather than tuned — it is the divisor that makes the two
  // above mean what they say.
  uInkDepth: { value: 40.0 },
  // A rail, not a tone control: `mix` extrapolates past the ink and into
  // negative light if this is ever exceeded. Under the values above it never
  // engages — the densest particle on the figure asks for about 0.09.
  uInkMax: { value: 0.45 },
  uInkStruct: { value: 0.45 },
};

const VERT = /* glsl */ `
  attribute vec3 fibre;
  attribute float muscleId;
  attribute float edge;

  uniform float uTime;
  uniform float uSize;
  uniform float uHeat[${SLOTS}];
  uniform float uSelected;
  uniform float uCore;
  uniform float uRim;
  uniform float uRimPow;
  uniform float uStructCore;
  uniform float uStructRim;
  uniform float uHeatGain;
  uniform float uGroove;
  uniform float uStripe;
  uniform float uCenterDist;
  // The one uniform both stages read, and the fragment shader is mediump by
  // its own precision statement while vertex shaders default to highp. A
  // uniform whose precision differs across stages fails to link, so both
  // declarations say it outright rather than inheriting a default.
  uniform mediump float uPolarity;

  varying float vIntensity;
  varying float vStruct;

  void main() {
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    vec3 n = normalize(normalMatrix * normal);

    // How side-on this bit of surface is. Grazing surface is where a volume
    // stacks up along the view ray, so that is where it should burn.
    float facing = abs(dot(n, normalize(-mv.xyz)));
    float rim = pow(1.0 - facing, uRimPow);

    int id = int(muscleId + 0.5);
    float heat = uHeat[id];
    float structural = id == ${STRUCTURAL} ? 1.0 : 0.0;

    // Striations run *along* the fibre, so the banding has to vary across it.
    vec3 perp = normalize(cross(normal, fibre) + vec3(1e-5));
    float stripe = sin(dot(position, perp) * uStripe) * 0.5 + 0.5;

    // Just enough drift that a still body still feels alive. No simulation —
    // a sine on a per-point constant, which costs nothing.
    float shimmer = 0.90 + 0.10 * sin(uTime * 1.3 + dot(position, fibre) * 11.0);

    float i = uCore * mix(1.0, uStructCore, structural)
            + rim * uRim * mix(1.0, uStructRim, structural);
    i += heat * (0.34 + 0.66 * rim) * uHeatGain;
    i *= 0.74 + 0.26 * stripe;
    i *= shimmer;

    // The groove between one group and the next. This is the only anatomy the
    // source mesh doesn't supply, and it is what separates pec from rib and
    // deltoid from arm on a surface that is otherwise perfectly smooth.
    i *= mix(uGroove, 1.0, smoothstep(0.0, 0.75, edge));

    // Depth fade, measured against the distance to the figure's own centre —
    // not against raw view-space z, which is just "how far the camera happens
    // to be". The far side of the body reads, but quietly.
    float behind = clamp((-mv.z - uCenterDist) / 0.42, -1.0, 1.0);
    i *= 1.0 - max(behind, 0.0) * 0.60;

    if (uSelected >= 0.0) {
      i *= (abs(float(id) - uSelected) < 0.5) ? 1.65 : 0.22;
    }

    vIntensity = i;
    vStruct = structural;

    // Worked muscle gets slightly fatter points as well as brighter ones, so
    // density carries the reading too and a hot group thickens visibly.
    //
    // Damped hard in the ink polarity. There a fatter point means more overlap,
    // and overlap is already the whole mechanism by which multiply accumulates
    // darkness — so at full strength heat counts twice and takes the group to
    // solid black well before it reaches the top of its range.
    float sizeHeat = heat * mix(0.35, 1.0, uPolarity);
    gl_PointSize = uSize * (0.85 + 0.45 * sizeHeat) / -mv.z;
    gl_Position = projectionMatrix * mv;
  }
`;

const FRAG = /* glsl */ `
  precision mediump float;

  uniform vec3 uAccent;
  uniform vec3 uInk;
  // Explicit to match the vertex shader; see the note there.
  uniform mediump float uPolarity;
  uniform float uInkMax;
  uniform float uInkGain;
  uniform float uInkCurve;
  uniform float uInkDepth;
  uniform float uInkStruct;

  varying float vIntensity;
  varying float vStruct;

  void main() {
    // Soft round sprite. A hard cutout would alias into gravel at this count;
    // the falloff is what lets 300k points read as one continuous body. Its
    // integral is SPRITE_COVERAGE, which the ink normalisation needs.
    float d = length(gl_PointCoord - 0.5);
    float a = smoothstep(0.5, 0.06, d);
    if (a <= 0.001) discard;

    float i = max(vIntensity, 0.0);

    if (uPolarity > 0.5) {
      // Glow: additive, so overlapping points sum straight past 1.0 and the
      // tone mapper handles the roll-off to white. Nothing is clamped here on
      // purpose — clamping per particle would throw away the highlight before
      // it ever accumulates. Coverage folds straight in: at a sprite's edge it
      // simply contributes less light.
      float lit = i * a;
      gl_FragColor = vec4(uAccent * lit, lit);
    } else {
      // Ink: multiplied into the page, so overlapping points darken. Same
      // volume, same edges, opposite polarity.
      //
      // Multiplication compounds, so the quantity that behaves here is not how
      // dark a particle is but the optical density of the whole stack landing
      // on the pixel — minus the log of it, which simply adds up. All of this is
      // written in that, which is why these constants can be stated as tones
      // you can go and look at rather than as per-particle magic.
      //
      // Dividing by the depth of that stack is the load-bearing part. The
      // saturating curve this replaced was described as bounding the top, and
      // it does — for one particle, which bounds nothing: the product runs to
      // black at *any* per-particle density once enough sprites overlap, so the
      // tone was really a function of how many points happened to land there.
      // That is why raising the count from 200k to 300k, and then sizing the
      // sprites correctly, each took the figure closer to a solid slab, and why
      // a flat floor turned the head — the most overlapped surface on the body
      // — into a black egg. Normalised, the tone is a property of the surface.
      //
      // Depth still does its real work, because this divides by the *average*
      // stack and not the local one: grazing surface stacks far deeper than
      // average and so darkens on its own, which is the same accumulation that
      // blows the silhouette out in the glow. The edge is still earned, not
      // drawn.
      float density = min(pow(i, uInkCurve) * uInkGain / uInkDepth, uInkMax);

      // Head, hands and feet again — but for a different reason than in the
      // vertex shader, and one dimming intensity cannot reach. Fingers and toes
      // are only a few pixels across while the sprites are not, so they stack
      // many times deeper than the average this is normalised against.
      density *= mix(1.0, uInkStruct, vStruct);

      // Coverage last, and deliberately outside the curve: it is how much of
      // this pixel the sprite actually covers, not part of the tone. Keeping it
      // out is also what makes the normalisation exact — summed over a stack,
      // the shaped intensity then comes out times the stack's depth, and the
      // depth is precisely what has just been divided away.
      gl_FragColor = vec4(mix(vec3(1.0), uInk, density * a), 1.0);
    }
  }
`;

const material = new THREE.ShaderMaterial({
  uniforms,
  vertexShader: VERT,
  fragmentShader: FRAG,
  transparent: true,
  depthWrite: false,
  depthTest: false,
  blending: THREE.AdditiveBlending,
});

// ── Silhouette ─────────────────────────────────────────────────────────
// The cloud has no hard boundary anywhere. That is the whole look in a dark
// room, and it is also the first thing to disappear on a gym floor in daylight,
// which the product asks this screen to survive.
//
// So the figure gets a contour: the body mesh grown along its own normals and
// drawn back-faces-only. A depth-only pass of the ungrown body goes down first,
// which buries everything except a constant-width ring standing proud of the
// silhouette. Interior stays volumetric, edge becomes a line.
const OUTLINE_PX = 2.0;

const outlineUniforms = {
  uWidth: { value: 0.0012 },
  uColor: { value: new THREE.Color('#34EEC2') },
  uAlpha: { value: 0.55 },
};

const outlineMaterial = new THREE.ShaderMaterial({
  uniforms: outlineUniforms,
  vertexShader: /* glsl */ `
    uniform float uWidth;
    void main() {
      vec4 mv = modelViewMatrix * vec4(position, 1.0);
      vec3 n = normalize(normalMatrix * normal);
      // Grown in view space and scaled by depth, so the ring holds the same
      // thickness in pixels however the figure happens to be framed.
      mv.xyz += n * (uWidth * -mv.z);
      gl_Position = projectionMatrix * mv;
    }
  `,
  fragmentShader: /* glsl */ `
    precision mediump float;
    uniform vec3 uColor;
    uniform float uAlpha;
    void main() { gl_FragColor = vec4(uColor, uAlpha); }
  `,
  side: THREE.BackSide,
  transparent: true,
  depthWrite: false,
  depthTest: true,
});

/// Writes depth and nothing else. Without it the grown shell has nothing to be
/// hidden behind and fills in as a solid slab instead of a ring.
const depthOnlyMaterial = new THREE.MeshBasicMaterial({ colorWrite: false });

function applyPolarity() {
  uniforms.uPolarity.value = polarity;
  // Everything that ends up in a buffer rather than in a uniform read by one
  // branch only. The backdrop is drawn on both paths, so its accent follows
  // the polarity even though what it contributes is a whisper.
  tint(inkOut, 'ink');
  tint(backdropAccent, 'accent');
  // The two paths draw into differently sized targets, and this is not a
  // resize — nothing else would recompute it.
  applyPointSize();
  if (polarity > 0.5) {
    material.blending = THREE.AdditiveBlending;
    // Accent, held deliberately under the bloom threshold — a contour that
    // blooms is just another soft edge, which is the thing it exists to fix.
    tint(outlineUniforms.uColor.value, 'accent');
    outlineUniforms.uAlpha.value = 0.55;
  } else {
    tint(outlineUniforms.uColor.value, 'ink');
    outlineUniforms.uAlpha.value = 1.0;
    // dst = dst * src — density accumulates as darkness.
    material.blending = THREE.CustomBlending;
    material.blendSrc = THREE.ZeroFactor;
    material.blendDst = THREE.SrcColorFactor;
    material.blendEquation = THREE.AddEquation;
  }
  material.needsUpdate = true;
  applyField();
  needsRender = true;
}

// ── Backdrop ───────────────────────────────────────────────────────────
// A whisper of lift behind the figure so the ground is a space rather than a
// flat fill. Kept under the bloom threshold so it never blooms on its own.
//
// Drawn as a screen-space quad rather than a plane standing in the world. The
// world-space version was 12 units square at a fixed depth, of which the camera
// only ever saw the middle third — so its falloff never got anywhere near zero
// before the canvas ran out, and the lift was still around half strength at the
// top and bottom edges. Half strength is nothing much in absolute terms, but
// this is a near-black ground and the encode to sRGB stretches small values
// hard: it arrived as a step of about twenty levels along a dead straight line,
// which is precisely how you read "panel cut into the screen".
//
// Shaped against the frame instead, the halo is guaranteed to land on the
// ground colour before it reaches any edge, whatever shape the view is.
const backdrop = new THREE.Mesh(
  new THREE.PlaneGeometry(2, 2),
  new THREE.ShaderMaterial({
    // Both written by `applyField` / `applyPolarity` before the first frame,
    // in whichever space this polarity's buffer wants.
    uniforms: { uField: { value: fieldOut }, uAccent: { value: backdropAccent } },
    vertexShader: `
      varying vec2 vUv;
      void main() {
        vUv = uv;
        // Straight to clip space: the quad *is* the viewport, so uv is screen
        // position and the halo can be measured against the frame.
        gl_Position = vec4(position.xy, 0.0, 1.0);
      }
    `,
    fragmentShader: `
      varying vec2 vUv;
      uniform vec3 uField;
      uniform vec3 uAccent;
      void main() {
        // How far out we are, with 1.0 meaning the frame edge — measured
        // separately above and below the centre, since the centre sits high and
        // the two halves are not the same size. An ellipse inscribed in the
        // frame this way touches zero at the edge midpoints and is long gone by
        // the corners.
        vec2 c = vec2(0.5, 0.56);
        vec2 p = vUv - c;
        float span = p.y > 0.0 ? 1.0 - c.y : c.y;
        p.x /= 0.5;
        p.y /= span;
        float t = clamp(1.0 - length(p), 0.0, 1.0);

        // Smoothstep rather than a power curve: it arrives at the edge with
        // zero gradient, so the landing has no lip, and it holds its value
        // through the middle instead of collapsing the moment you step off the
        // figure.
        float glow = t * t * (3.0 - 2.0 * t);

        // Very low: this is written in linear space and the output pass
        // encodes to sRGB, which lifts small values a long way.
        gl_FragColor = vec4(uField + uAccent * (glow * 0.011), 1.0);
      }
    `,
    depthWrite: false,
    // The silhouette pass fills the depth buffer with the figure, and this sits
    // behind it — left depth-testing it would be punched out body-shaped.
    depthTest: false,
  }),
);
// Nothing about this quad lives in the world, so there is no bounding sphere
// worth testing and the cull would be against a position it never uses.
backdrop.frustumCulled = false;
backdrop.renderOrder = -10;
scene.add(backdrop);

// ── Edge falloff ───────────────────────────────────────────────────────
// The last thing before the frame is encoded: ease it onto the ground colour at
// its own border.
//
// The backdrop above cannot do this job, because it is behind everything and
// bloom happens after it. Bloom is a blur, and a blur inside a render target
// has nowhere to spread once it reaches the boundary — the halo around the feet
// is truncated rather than faded, and a truncated glow draws the boundary.
// Selecting a muscle makes it unavoidable: the figure zooms in past every edge
// at once, so the cut is the whole way round.
//
// This runs *before* OutputPass, so what it lands on is the pre-corrected field
// — the same value the buffer is cleared to, which tone maps and encodes back
// to exactly the app's own background. The border of the canvas is therefore
// the background, to the level, and there is nothing there to see.
const EDGE_BAND = 0.075;

const edgeFade = new ShaderPass({
  name: 'ArcEdgeFade',
  uniforms: {
    tDiffuse: { value: null },
    uField: { value: new THREE.Color(0, 0, 0) },
    uBand: { value: EDGE_BAND },
  },
  vertexShader: `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: `
    precision mediump float;
    uniform sampler2D tDiffuse;
    uniform vec3 uField;
    uniform float uBand;
    varying vec2 vUv;
    void main() {
      // Distance to the nearest edge, in bands. The corners take whichever of
      // the two is closer, so the band is a frame rather than a rounded well.
      vec2 e = min(vUv, 1.0 - vUv) / max(uBand, 0.0001);
      float t = clamp(min(e.x, e.y), 0.0, 1.0);
      // Smootherstep — flat at both ends, so neither the boundary nor the inner
      // lip of the band leaves a line of its own. A linear ramp would just move
      // the seam inwards.
      float k = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
      gl_FragColor = vec4(mix(uField, texture2D(tDiffuse, vUv).rgb, k), 1.0);
    }
  `,
});

// ── Geometry ───────────────────────────────────────────────────────────
const groupAnchors = {};
const groupNormals = {};
let collider = null;

/// Total surface area of the source mesh, in the model's own units. Measured
/// at scatter time; see [stackDepth] for what needs it.
let meshArea = 0;

/// Reads the baked body. Layout is written by tool/prepare_body.mjs.
async function loadBody() {
  const res = await fetch('body.bin', { cache: 'no-store' });
  if (!res.ok) throw new Error(`body.bin ${res.status}`);
  const buf = await res.arrayBuffer();

  const dv = new DataView(buf);
  let magic = '';
  for (let i = 0; i < 8; i++) magic += String.fromCharCode(dv.getUint8(i));
  if (magic !== 'ARCBODY2') throw new Error('body.bin: bad header');

  const vc = dv.getUint32(8, true);
  const ic = dv.getUint32(12, true);
  const pad = Math.ceil(vc / 4) * 4;

  let o = 16;
  const position = new Float32Array(buf, o, vc * 3); o += vc * 12;
  const normal = new Float32Array(buf, o, vc * 3); o += vc * 12;
  const fibre = new Float32Array(buf, o, vc * 3); o += vc * 12;
  const muscleId = new Uint8Array(buf, o, vc); o += pad;
  const border = new Uint8Array(buf, o, vc); o += pad;
  const index = new Uint32Array(buf, o, ic);

  return { vc, position, normal, fibre, muscleId, border, index };
}

/// Scatters points evenly over the surface *by area*.
///
/// Sampling the mesh's own vertices would clump: this source model spends most
/// of its topology on the face, hands and feet, so a per-vertex cloud would be
/// a dense head above a sparse torso. Area sampling makes the density uniform
/// no matter how the source was modelled — which is also what lets the source
/// mesh be swapped for another one.
function scatter(body, count) {
  const { position, normal, fibre, muscleId, border, index } = body;
  const triCount = index.length / 3;

  const cumulative = new Float32Array(triCount);
  let total = 0;
  const ax = [0, 0, 0], bx = [0, 0, 0];
  for (let t = 0; t < triCount; t++) {
    const i0 = index[t * 3] * 3, i1 = index[t * 3 + 1] * 3, i2 = index[t * 3 + 2] * 3;
    for (let k = 0; k < 3; k++) {
      ax[k] = position[i1 + k] - position[i0 + k];
      bx[k] = position[i2 + k] - position[i0 + k];
    }
    const cx = ax[1] * bx[2] - ax[2] * bx[1];
    const cy = ax[2] * bx[0] - ax[0] * bx[2];
    const cz = ax[0] * bx[1] - ax[1] * bx[0];
    total += Math.hypot(cx, cy, cz) / 2;
    cumulative[t] = total;
  }
  // Kept: the ink normalisation needs to know how much surface this cloud is
  // spread over, and this loop has just measured it. ~1.86m² for the shipped
  // mesh, which is a plausible human and a good sign the units are metres.
  meshArea = total;

  const outPos = new Float32Array(count * 3);
  const outNor = new Float32Array(count * 3);
  const outFib = new Float32Array(count * 3);
  const outId = new Float32Array(count);
  const outEdge = new Float32Array(count);

  for (let s = 0; s < count; s++) {
    // Pick a triangle with probability proportional to its area.
    const target = Math.random() * total;
    let lo = 0, hi = triCount - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (cumulative[mid] < target) lo = mid + 1; else hi = mid;
    }

    const i0 = index[lo * 3], i1 = index[lo * 3 + 1], i2 = index[lo * 3 + 2];
    // Square-rooting the first coordinate is what makes barycentric picks
    // uniform over the triangle instead of bunched at one corner.
    let u = Math.random(), v = Math.random();
    u = Math.sqrt(u);
    const w0 = 1 - u, w1 = u * (1 - v), w2 = u * v;

    const o3 = s * 3;
    for (let k = 0; k < 3; k++) {
      outPos[o3 + k] =
        position[i0 * 3 + k] * w0 + position[i1 * 3 + k] * w1 + position[i2 * 3 + k] * w2;
      outNor[o3 + k] =
        normal[i0 * 3 + k] * w0 + normal[i1 * 3 + k] * w1 + normal[i2 * 3 + k] * w2;
      outFib[o3 + k] =
        fibre[i0 * 3 + k] * w0 + fibre[i1 * 3 + k] * w1 + fibre[i2 * 3 + k] * w2;
    }

    // The group of whichever corner dominates this sample. Interpolating an id
    // would invent groups that don't exist between two that do.
    const dom = w0 >= w1 && w0 >= w2 ? i0 : (w1 >= w2 ? i1 : i2);
    outId[s] = muscleId[dom];
    // Border depth *is* interpolated — it is a smooth field, and interpolating
    // it is what makes the groove a soft valley rather than a stair.
    outEdge[s] =
      (border[i0] * w0 + border[i1] * w1 + border[i2] * w2) / 255;

    // Sink a share of the points under the skin. A shell one particle thick
    // reads as a balloon; a little depth is what gives the silhouette its
    // falloff and lets the far side show through.
    //
    // Scaled right down on the head, hands and feet. Three centimetres is
    // nothing on a thigh and most of a nose — at full depth it turns eye
    // sockets and the mouth into torn voids, which is what made the face read
    // as a skull.
    const nl = Math.hypot(outNor[o3], outNor[o3 + 1], outNor[o3 + 2]) || 1;
    const reach = muscleId[dom] === STRUCTURAL ? 0.007 : 0.030;
    const depth = -Math.pow(Math.random(), 2.2) * reach;
    for (let k = 0; k < 3; k++) {
      outNor[o3 + k] /= nl;
      outPos[o3 + k] += outNor[o3 + k] * depth;
    }
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(outPos, 3));
  geo.setAttribute('normal', new THREE.BufferAttribute(outNor, 3));
  geo.setAttribute('fibre', new THREE.BufferAttribute(outFib, 3));
  geo.setAttribute('muscleId', new THREE.BufferAttribute(outId, 1));
  geo.setAttribute('edge', new THREE.BufferAttribute(outEdge, 1));
  return geo;
}

/// Label anchor and outward direction per group, plus the figure's overall
/// extents for framing — one pass over the mesh, since both want the same read.
function measureGroups(body) {
  const { position, normal, muscleId, vc } = body;
  const sum = {}, nrm = {}, n = {};

  // Every vertex, hands and feet included — they are the parts that reach
  // furthest, so framing against the muscles alone would clip them again.
  framePositions = position;

  for (let i = 0; i < vc; i++) {
    const id = muscleId[i];
    if (id === STRUCTURAL) continue;
    const key = MUSCLE_IDS[id];
    if (!sum[key]) { sum[key] = [0, 0, 0]; nrm[key] = [0, 0, 0]; n[key] = 0; }
    for (let k = 0; k < 3; k++) {
      sum[key][k] += position[i * 3 + k];
      nrm[key][k] += normal[i * 3 + k];
    }
    n[key]++;
  }
  for (const key of Object.keys(sum)) {
    const c = sum[key].map((x) => x / n[key]);
    const d = new THREE.Vector3(...nrm[key]).normalize();
    groupNormals[key] = d;
    // The group's own centre, which is what the camera lifts to when its sheet
    // opens. It used to be pushed out along the normal so a label chip cleared
    // the silhouette; with no chip to place, the true centre is the honest one.
    groupAnchors[key] = new THREE.Vector3(...c);
  }
}

// ── Post ───────────────────────────────────────────────────────────────
let composer = null;
let bloom = null;

function buildComposer(w, h) {
  composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  // Threshold well above the body's resting brightness, so bloom is reserved
  // for edges and worked muscle rather than smearing the whole figure.
  bloom = new UnrealBloomPass(new THREE.Vector2(w, h), 0.46, 0.45, 0.70);
  composer.addPass(bloom);
  // After the glow, before the encode — see the note on the pass itself.
  composer.addPass(edgeFade);
  composer.addPass(new OutputPass());
  // See [COMPOSER_SCALE]. Anything that draws in framebuffer pixels has to know
  // about this — which is what [applyPointSize] exists for.
  composer.setPixelRatio(pixelRatio() * COMPOSER_SCALE);
}

// ── State ──────────────────────────────────────────────────────────────
let yaw = 0;
let yawVelocity = 0;
let dragging = false;
let selected = null;
let reduceMotion = false;
let sheetFraction = 0;

// Whether the Exercises tab is the one on screen. Flutter is the only thing
// that knows: this page is inside a platform WebView, so it is never told it
// stopped being painted and no visibility event ever fires. Defaults to true
// so the scene still runs when the page is opened directly in a browser.
let activeTab = true;
/// Whether a frame is currently scheduled. The loop stops rescheduling itself
/// when the tab goes away rather than spinning on an early return.
let running = false;

/// How often the resting shimmer is allowed to force a redraw. It is a ±10%
/// sine on a still figure — at 20Hz it looks the same as at 60 and composes a
/// third as many bloom passes.
const SHIMMER_PERIOD = 1 / 20;
let shimmerAccum = 0;

const view = { targetY: BODY_MID, dist: camDist };
const viewGoal = { targetY: BODY_MID, dist: camDist };

let intro = 0;
let introFrom = -0.5;
let needsRender = true;
let ready = false;

// ── Interaction ────────────────────────────────────────────────────────
// A turntable, locked to the vertical axis. No pitch, no roll: a body you can
// tumble is a toy, and this one is a control.
const SNAP = Math.PI;

let pointerId = null;
let lastX = 0, downX = 0, downY = 0, downAt = 0;

stage.addEventListener('pointerdown', (e) => {
  if (pointerId !== null) return;
  pointerId = e.pointerId;
  stage.setPointerCapture(e.pointerId);
  dragging = true;
  lastX = downX = e.clientX;
  downY = e.clientY;
  downAt = performance.now();
  yawVelocity = 0;
});

stage.addEventListener('pointermove', (e) => {
  if (e.pointerId !== pointerId) return;
  const dx = e.clientX - lastX;
  lastX = e.clientX;
  // Full width of the view ≈ a half turn, so front-to-back is one thumb sweep.
  const perPixel = Math.PI / Math.max(stage.clientWidth, 1);
  yaw += dx * perPixel;
  yawVelocity = dx * perPixel;
  needsRender = true;
});

function endDrag(e) {
  if (e.pointerId !== pointerId) return;
  pointerId = null;
  dragging = false;
  try { stage.releasePointerCapture(e.pointerId); } catch (_) {}

  const dt = performance.now() - downAt;
  const dist = Math.hypot(e.clientX - downX, e.clientY - downY);
  if (dist < 12 && dt < 500) {
    yawVelocity = 0;
    pick(e.clientX, e.clientY);
  }
  needsRender = true;
}

stage.addEventListener('pointerup', endDrag);
stage.addEventListener('pointercancel', endDrag);

const raycaster = new THREE.Raycaster();

function pick(clientX, clientY) {
  if (!collider) return;
  const rect = stage.getBoundingClientRect();
  raycaster.setFromCamera(
    new THREE.Vector2(
      ((clientX - rect.left) / rect.width) * 2 - 1,
      -((clientY - rect.top) / rect.height) * 2 + 1,
    ),
    camera,
  );
  // Against the solid mesh, never the cloud: raycasting a point cloud is a
  // proximity guess, and picking a muscle should not be a guess.
  const hits = raycaster.intersectObject(collider, false);
  if (!hits.length) {
    send({ t: 'tap', id: null });
    return;
  }
  const ids = collider.geometry.attributes.muscleId.array;
  const id = ids[hits[0].face.a];
  send({ t: 'tap', id: id === STRUCTURAL ? null : MUSCLE_IDS[id] });
}

// ── Loop ───────────────────────────────────────────────────────────────

/// Sprite diameter at unit depth, in the pixels of whatever buffer is being
/// drawn into. See [applyPointSize] for why that qualifier is the whole point.
const POINT_PX = 5.44;

/// The stage's CSS height, held because the point size depends on it and has to
/// be recomputed on a polarity change, which is not a resize.
let stageH = 0;

/// Sizes the sprites against the *target* rather than against the screen.
///
/// `gl_PointSize` is in framebuffer pixels, and the two polarities do not draw
/// into the same framebuffer: dark composes at [COMPOSER_SCALE], light renders
/// straight to the canvas at full ratio. A sprite of a given size therefore
/// covers four times as much of the dark path's target as it does of the light
/// one's — and since both looks are an accumulation of overlapping sprites, how
/// deep that stack runs *is* the look.
///
/// Sizing against `pixelRatio()` alone is what left the light figure sandy: the
/// same 300k points spread over four times the pixels stack about 14 deep where
/// dark stacks about 55, which is the difference between a continuous volume
/// and a Poisson scatter you can see the grain of. Scaling by the target's own
/// ratio keeps both the apparent size and the stack depth invariant, so one set
/// of constants describes both paths.
function applyPointSize() {
  if (!stageH) return;
  const ratio = polarity > 0.5 ? pixelRatio() * COMPOSER_SCALE : pixelRatio();
  uniforms.uSize.value = POINT_PX * ratio * (stageH / 700) * camDist;
  uniforms.uInkDepth.value = stackDepth(ratio);
}

/// What one sprite covers, as a fraction of the square its point size spans.
/// The integral of the falloff in the fragment shader over its own disc — a
/// hard disc of that size would be 0.785, and the soft edge is the difference.
const SPRITE_COVERAGE = 0.277;

/// How many sprites land on an average pixel of the figure.
///
/// Derived, because this is exactly the number that rots in silence. The ink
/// constants were measured against a cloud of ~200,000 points, the file now
/// scatters 300,000, and every extra point multiplies into the page — so the
/// figure had been drifting toward a solid slab through changes that said
/// nothing about tone.
///
/// The count landing on the figure is the whole cloud, since the scatter is by
/// area and every point is drawn: depth testing is off, so the surface facing
/// away contributes to the same pixels as the one facing the viewer. The pixels
/// they land on are the figure's silhouette, and Cauchy's theorem puts a convex
/// body's mean projected area at a quarter of its surface. The shipped mesh
/// measures 4.33 rather than 4.00 from the front — the gap is the parts of a
/// standing body that are not convex, the space between the legs and under the
/// arms — and 8% of a density is not a thing anyone can see.
///
/// Note what falls out: the camera distance cancels, because framing the figure
/// larger grows its silhouette and its sprites by the same square. So does the
/// pixel ratio, now that [applyPointSize] sizes points against their target.
/// The depth is a property of the cloud, which is the point of computing it.
function stackDepth(ratio) {
  if (!meshArea) return 1;
  const sprite = (uniforms.uSize.value * 0.85) / camDist;
  const perWorld =
    (stageH * ratio) / 2 / (camDist * Math.tan((camera.fov * Math.PI) / 360));
  const silhouette = (meshArea / 4) * perWorld * perWorld;
  return Math.max(
    1,
    (PARTICLE_COUNT * SPRITE_COVERAGE * sprite * sprite) / silhouette,
  );
}

function resize() {
  const w = stage.clientWidth;
  const h = stage.clientHeight;
  if (!w || !h) return;
  stageH = h;
  // `updateStyle` left on. Passing false is only correct when CSS gives the
  // canvas a size; without it the element lays out at its *buffer* size, so on
  // a 2.75× screen the canvas comes out 2.75× too big and anchored top-left —
  // the figure ends up enormous and shoved off to one side.
  renderer.setSize(w, h);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  camDist = fitDistance();
  if (selected === null) view.dist = camDist;
  if (!composer) buildComposer(w, h); else composer.setSize(w, h);
  // Tracks how tightly the figure is framed as well as the target, or the cloud
  // thins out on a big screen.
  applyPointSize();
  // The contour is specified in device pixels and converted here, so it stays
  // the same weight on a dense phone screen as on a coarse one. Measured
  // against the screen rather than the target on purpose: the two cancel — a
  // half-resolution buffer draws it half as thick and is then upscaled twice as
  // far — so the line lands at the same physical weight on both paths.
  outlineUniforms.uWidth.value =
    (OUTLINE_PX * 2 * Math.tan((camera.fov * Math.PI) / 360)) /
    (h * pixelRatio());
  needsRender = true;
}
window.addEventListener('resize', resize);

// Android's WebView often reports its final size only after the first paint,
// and it does not always fire a window resize when it settles. Watching the
// element itself is the only reliable signal.
if (window.ResizeObserver) new ResizeObserver(resize).observe(stage);

let last = performance.now();

function frame(now) {
  // Stop rescheduling rather than early-returning, so an unwatched tab costs
  // nothing at all. `ensureRunning` picks the loop back up.
  if (!ready || !activeTab) {
    running = false;
    return;
  }
  requestAnimationFrame(frame);

  const dt = Math.min((now - last) / 1000, 0.05);
  last = now;
  uniforms.uTime.value += dt;

  // Did the *figure* move this frame, as opposed to merely needing repainting?
  // Kept apart because the shimmer asks for a redraw on its own schedule and
  // has nothing to do with the turntable having come to rest.
  let moved = false;

  if (!reduceMotion) {
    shimmerAccum += dt;
    if (shimmerAccum >= SHIMMER_PERIOD) {
      shimmerAccum = 0;
      needsRender = true;
    }
  }

  // Entrance: the figure arrives already turning and comes to rest facing you.
  // One authored moment, played once.
  if (intro < 1) {
    intro = Math.min(1, intro + dt / 1.0);
    yaw = introFrom * (1 - (1 - Math.pow(1 - intro, 4)));
    moved = true;
  } else if (!dragging) {
    if (Math.abs(yawVelocity) > 0.00025) {
      yaw += yawVelocity * dt * 60;
      yawVelocity *= Math.pow(0.945, dt * 60);
      moved = true;
    } else if (yawVelocity !== 0) {
      yawVelocity = 0;
    } else if (selected === null) {
      // Settle onto whichever face is nearer. Front and back are the two views
      // that name themselves; anything between is a transition.
      const nearest = Math.round(yaw / SNAP) * SNAP;
      const delta = nearest - yaw;
      if (Math.abs(delta) > 0.0015) {
        yaw += delta * (reduceMotion ? 1 : Math.min(1, dt * 9));
        moved = true;
      }
    }
  }

  model.rotation.y = yaw;

  // `sheetFraction` lifts the figure so the group you just opened stays above
  // the sheet rather than behind it.
  const lift = sheetFraction * 0.42;
  const anchor = selected && groupAnchors[selected];
  viewGoal.targetY = (anchor ? anchor.y : BODY_MID) + lift * 0.55;
  viewGoal.dist = selected ? camDist * 0.62 : camDist;

  const k = reduceMotion ? 1 : Math.min(1, dt * 6.5);
  const before = view.dist + view.targetY;
  view.targetY += (viewGoal.targetY - view.targetY) * k;
  view.dist += (viewGoal.dist - view.dist) * k;
  if (Math.abs(before - (view.dist + view.targetY)) > 0.0004) moved = true;

  camera.position.set(0, view.targetY + lift * 0.25, view.dist);
  camera.lookAt(0, view.targetY, 0);
  uniforms.uCenterDist.value = view.dist;

  if (moved) needsRender = true;

  if (needsRender) {
    // Bloom is the glow; multiplied ink has nothing to bloom, so light mode
    // skips the composer entirely rather than blurring the paper.
    if (polarity > 0.5 && composer) composer.render();
    else renderer.render(scene, camera);
    needsRender = false;
  }
}

/// Restarts the render loop if it is idle and there is a reason to draw.
/// Safe to call repeatedly; the `running` latch keeps rAF callbacks from
/// stacking up into a loop that runs several times per frame.
function ensureRunning() {
  if (running || !ready || !activeTab) return;
  running = true;
  // Reset the clock, or the first frame back gets a `dt` covering however long
  // the tab was away and the settle animations jump.
  last = performance.now();
  requestAnimationFrame(frame);
}

// ── Inbound ────────────────────────────────────────────────────────────
window.arcBody = {
  handle(raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }

    switch (msg.t) {
      case 'theme':
        // Each colour lands twice: in the linear working space, and untouched.
        // See the note on `theme` for why neither one alone will do.
        for (const name of ['field', 'accent', 'ink']) {
          if (!msg[name]) continue;
          theme[name].setStyle(msg[name]);
          themeSRGB[name] = readHex(msg[name]) || themeSRGB[name];
        }
        polarity = msg.polarity === 0 || msg.polarity === false ? 0 : 1;
        // Distributes both forms to everything that draws with them.
        applyPolarity();
        break;

      case 'volume': {
        const heat = uniforms.uHeat.value;
        for (let i = 0; i < MUSCLE_IDS.length; i++) {
          const v = msg.v ? msg.v[MUSCLE_IDS[i]] : 0;
          heat[i] = typeof v === 'number' ? v : 0;
        }
        heat[STRUCTURAL] = 0;
        needsRender = true;
        break;
      }

      case 'select': {
        selected = msg.id && groupAnchors[msg.id] ? msg.id : null;
        uniforms.uSelected.value =
          selected === null ? -1 : MUSCLE_IDS.indexOf(selected);
        if (selected) {
          // Turn the selected group toward the viewer, so focusing lands on
          // something you can actually see.
          const d = groupNormals[selected];
          const facing = Math.atan2(d.x, d.z);
          const turns = Math.round((yaw + facing) / (2 * Math.PI));
          yaw = turns * 2 * Math.PI - facing;
          yawVelocity = 0;
        }
        needsRender = true;
        break;
      }

      case 'active': {
        const next = msg.value !== false;
        if (next === activeTab) break;
        activeTab = next;
        if (activeTab) {
          // Whatever arrived while the tab was away — a logged workout, a
          // theme change — was applied to the scene but never drawn.
          needsRender = true;
          ensureRunning();
        }
        break;
      }

      case 'motion':
        reduceMotion = !!msg.reduce;
        if (reduceMotion && intro < 1) {
          intro = 1;
          introFrom = 0;
          yaw = 0;
        }
        needsRender = true;
        break;

      case 'sheet':
        sheetFraction = typeof msg.fraction === 'number' ? msg.fraction : 0;
        needsRender = true;
        break;
    }
  },
};

// ── Boot ───────────────────────────────────────────────────────────────
(async () => {
  try {
    const body = await loadBody();
    measureGroups(body);

    const cloud = new THREE.Points(scatter(body, PARTICLE_COUNT), material);
    cloud.frustumCulled = false;
    // Draw order is stated rather than left to three's own sort, because the
    // silhouette depends on it: depth first, then the ring that depth reveals,
    // then the cloud over both.
    cloud.renderOrder = 2;
    model.add(cloud);

    const solid = new THREE.BufferGeometry();
    solid.setAttribute('position', new THREE.BufferAttribute(body.position, 3));
    // Needed by the contour, which grows the surface along it.
    solid.setAttribute('normal', new THREE.BufferAttribute(body.normal, 3));
    solid.setAttribute(
      'muscleId', new THREE.BufferAttribute(Float32Array.from(body.muscleId), 1));
    solid.setIndex(new THREE.BufferAttribute(body.index, 1));
    collider = new THREE.Mesh(solid, new THREE.MeshBasicMaterial());
    collider.visible = false;
    model.add(collider);

    const depthMask = new THREE.Mesh(solid, depthOnlyMaterial);
    depthMask.renderOrder = 0;
    model.add(depthMask);

    const outline = new THREE.Mesh(solid, outlineMaterial);
    outline.renderOrder = 1;
    model.add(outline);

    resize();
    applyPolarity();
    ready = true;
    ensureRunning();
    send({ t: 'ready' });
  } catch (err) {
    send({ t: 'error', message: String(err && err.message ? err.message : err) });
  }
})();
