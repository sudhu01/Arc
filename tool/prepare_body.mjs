// Bakes the runtime body mesh.
//
//   node tool/prepare_body.mjs
//
// Reads a human body mesh from assets/source/, keeps only the skin surface,
// normalises it, assigns every vertex a muscle group and a fibre direction, and
// writes the compact binary the renderer loads.
//
// Checked in so the shipped asset is reproducible: the binary in assets/body/
// is an output, not a mystery file, and re-tuning a region means editing
// muscle_regions.mjs and re-running this.
//
// Source: MakeHuman base mesh (hm08), explicitly released CC0 in September
// 2020 — the licence is stated in the .obj header itself. No attribution is
// required, which is why it was chosen over the CC BY-SA anatomy atlases.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { MUSCLE_IDS, STRUCTURAL, expandSites } from './muscle_regions.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = join(root, 'assets/source/base.obj');
const OUT = join(root, 'assets/body/body.bin');

/// Groups in the source OBJ that are actually part of the visible body.
/// Everything else it ships is rigging scaffolding — joint cubes and the helper
/// cages it uses to fit clothing — and none of that belongs in a render.
const SKIN_GROUPS = new Set(['body']);

const TARGET_HEIGHT = 1.8;

// ── Vector helpers ─────────────────────────────────────────────────────
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];
const norm = (v) => {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
};

/// Squared distance from `p` to segment `a`–`b`, measured after `scale` is
/// applied to each axis. The anisotropy is what stops a chest site from
/// reaching around the ribcage to claim back surface.
function distSqToSite(p, site) {
  const s = site.scale;
  const P = [p[0] * s[0], p[1] * s[1], p[2] * s[2]];
  const A = [site.a[0] * s[0], site.a[1] * s[1], site.a[2] * s[2]];
  if (!site.b) {
    const d = sub(P, A);
    return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
  }
  const B = [site.b[0] * s[0], site.b[1] * s[1], site.b[2] * s[2]];
  const ab = sub(B, A);
  const ap = sub(P, A);
  const len = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  let t = len === 0 ? 0 : (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / len;
  t = Math.max(0, Math.min(1, t));
  const d = [ap[0] - ab[0] * t, ap[1] - ab[1] * t, ap[2] - ab[2] * t];
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}

// ── Holes ──────────────────────────────────────────────────────────────
/// Fills any open boundary in the source mesh.
///
/// Reports nothing on the mesh shipped here, which is already closed. It stays
/// because the source is meant to be swappable, and an open boundary renders
/// as a black tear on a figure made of light — far better caught at bake time
/// than discovered on a device.
function capHoles(verts, tris) {
  const seen = new Map(); // undirected edge -> times used
  const directed = new Map(); // "a,b" -> true, in triangle winding order
  const key = (a, b) => `${Math.min(a, b)},${Math.max(a, b)}`;

  for (const [a, b, c] of tris) {
    for (const [u, v] of [[a, b], [b, c], [c, a]]) {
      seen.set(key(u, v), (seen.get(key(u, v)) || 0) + 1);
      directed.set(`${u},${v}`, true);
    }
  }

  // A boundary edge belongs to exactly one triangle. Chain them tip-to-tail
  // and each chain closes into one hole.
  const next = new Map();
  for (const [k, count] of seen) {
    if (count !== 1) continue;
    const [x, y] = k.split(',').map(Number);
    if (directed.has(`${x},${y}`)) next.set(x, y);
    else next.set(y, x);
  }

  let capped = 0;
  const visited = new Set();
  for (const start of next.keys()) {
    if (visited.has(start)) continue;
    const loop = [];
    let at = start;
    while (at !== undefined && !visited.has(at)) {
      visited.add(at);
      loop.push(at);
      at = next.get(at);
    }
    if (loop.length < 3) continue;

    const centre = [0, 0, 0];
    for (const i of loop) {
      centre[0] += verts[i][0];
      centre[1] += verts[i][1];
      centre[2] += verts[i][2];
    }
    const ci = verts.length;
    verts.push(centre.map((x) => x / loop.length));
    for (let i = 0; i < loop.length; i++) {
      // Reversed against the boundary's own direction, so the cap faces out
      // with the rest of the surface.
      tris.push([loop[(i + 1) % loop.length], loop[i], ci]);
    }
    capped++;
  }
  return capped;
}

// ── Shape ──────────────────────────────────────────────────────────────
// The source is a deliberately neutral base mesh: soft, androgynous, standing
// in a splayed A-pose because it exists to be rigged, not to be looked at. Two
// passes turn it into someone who lifts. Both are keyed off the skeleton
// landmarks the source ships with, so they stay honest about anatomy.

const clamp01 = (x) => Math.max(0, Math.min(1, x));
const smoothstep = (a, b, x) => {
  const t = clamp01((x - a) / (b - a || 1e-6));
  return t * t * (3 - 2 * t);
};

/// Piecewise-linear lookup over [height, factor] control points.
function profile(y, points) {
  if (y <= points[0][0]) return points[0][1];
  for (let i = 1; i < points.length; i++) {
    if (y <= points[i][0]) {
      const [y0, v0] = points[i - 1];
      const [y1, v1] = points[i];
      return v0 + (v1 - v0) * ((y - y0) / (y1 - y0));
    }
  }
  return points[points.length - 1][1];
}

/// Width against height. Broad across the shoulders, cut in at the waist,
/// narrow through the hips — the V that separates an athletic male silhouette
/// from a mannequin's.
const WIDTH = [
  [0.00, 1.00], [0.84, 0.94], [0.95, 0.90], [1.06, 0.89], [1.16, 0.88],
  [1.26, 0.98], [1.34, 1.05], [1.42, 1.10], [1.48, 1.10], [1.54, 1.02],
  [1.62, 1.00], [1.80, 1.00],
];

/// Depth against height. A fuller chest and a flatter waist.
const DEPTH = [
  [0.00, 1.00], [0.86, 0.98], [0.98, 0.95], [1.12, 0.92], [1.22, 0.97],
  [1.32, 1.08], [1.42, 1.08], [1.52, 1.02], [1.80, 1.00],
];

function sculpt(verts) {
  for (const p of verts) {
    const y = p[1];
    const ax = Math.abs(p[0]);
    // How far out the reshaping reaches. Wider up at the shoulders, where the
    // deltoid should broaden with the torso; tight at the waist, so the arms
    // hanging beside it aren't dragged in with it.
    const limit = 0.20 + 0.09 * smoothstep(1.30, 1.44, y);
    const w = 1 - smoothstep(limit, limit + 0.12, ax);
    p[0] *= 1 + (profile(y, WIDTH) - 1) * w;
    p[2] *= 1 + (profile(y, DEPTH) - 1) * w;
  }
}

/// Cut line under the jaw. Everything above it is discarded and rebuilt.
const JAW = 1.545;

/// Replaces the source's head with a smooth form.
///
/// Deliberate, and worth saying why. The source models the mouth open with an
/// interior cavity and the eye sockets as recesses, because it is built to be
/// fitted with separate eye and tongue props. On a body made of light those
/// read as black pits — the figure comes out looking like it is screaming, and
/// no amount of smoothing removes them because they are holes in the form
/// rather than dents in it.
///
/// A calm, convincing face needs better source geometry than a rigging base
/// mesh has. Between an uncanny face and none, none wins: a smooth head reads
/// as an instrument's figure rather than a person staring back, which is the
/// right register for a screen you check between sets.
function replaceHead(verts, tris) {
  // Drop every triangle wholly above the jaw. Partial ones stay, so the neck
  // keeps a continuous surface up to the cut.
  const kept = tris.filter(
    (t) => !(verts[t[0]][1] > JAW && verts[t[1]][1] > JAW && verts[t[2]][1] > JAW));
  tris.length = 0;
  tris.push(...kept);

  // Sized and placed to sit over the neck stump, so the opening left behind is
  // enclosed rather than patched.
  const centre = [0, 1.668, 0.014];
  const radius = [0.084, 0.130, 0.100];
  const RINGS = 22;
  const SEGMENTS = 30;

  const base = verts.length;
  for (let r = 0; r <= RINGS; r++) {
    const phi = (r / RINGS) * Math.PI;
    for (let s = 0; s < SEGMENTS; s++) {
      const theta = (s / SEGMENTS) * Math.PI * 2;
      verts.push([
        centre[0] + radius[0] * Math.sin(phi) * Math.cos(theta),
        centre[1] + radius[1] * Math.cos(phi),
        centre[2] + radius[2] * Math.sin(phi) * Math.sin(theta),
      ]);
    }
  }
  const at = (r, s) => base + r * SEGMENTS + (s % SEGMENTS);
  for (let r = 0; r < RINGS; r++) {
    for (let s = 0; s < SEGMENTS; s++) {
      // Wound counter-clockwise seen from outside, matching the body. Rings run
      // top to bottom and segments run +x toward +z, so taking them in the
      // reading order gives the inside-out sphere — which costs nothing until
      // something asks the mesh which way is out, and then costs a great deal.
      tris.push([at(r, s), at(r + 1, s + 1), at(r + 1, s)]);
      tris.push([at(r, s), at(r, s + 1), at(r + 1, s + 1)]);
    }
  }
}

/// Signed volume of each closed shell, via the divergence theorem.
///
/// A shell wound inside-out comes back negative. Nothing in the old pipeline
/// asked, so the generated head shipped inverted: its vertex normals pointed
/// into the skull, which pushed the point cloud's depth-sink outward instead of
/// under the surface, and made every back-face test on it answer backwards.
function shellVolumes(verts, tris) {
  const parent = new Int32Array(verts.length).map((_, i) => i);
  const find = (a) => { while (parent[a] !== a) { parent[a] = parent[parent[a]]; a = parent[a]; } return a; };
  const union = (a, b) => { a = find(a); b = find(b); if (a !== b) parent[b] = a; };
  for (const [a, b, c] of tris) { union(a, b); union(a, c); }

  const shells = new Map();
  for (const [i0, i1, i2] of tris) {
    const key = find(i0);
    if (!shells.has(key)) shells.set(key, { volume: 0, tris: 0 });
    const s = shells.get(key);
    const [ax, ay, az] = verts[i0], [bx, by, bz] = verts[i1], [cx, cy, cz] = verts[i2];
    s.volume += (ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)) / 6;
    s.tris++;
  }
  return [...shells.values()];
}

/// Rotates `p` about `centre` in the XY plane.
function rotateZ(p, centre, angle) {
  const dx = p[0] - centre[0];
  const dy = p[1] - centre[1];
  const c = Math.cos(angle), s = Math.sin(angle);
  p[0] = centre[0] + dx * c - dy * s;
  p[1] = centre[1] + dx * s + dy * c;
}

const SHOULDER = [0.176, 1.385, 0];
const HAND = [0.466, 1.148, 0.190];
const HIP = [0.119, 0.936, 0.013];

/// Where `p` falls against segment `a`–`b`: `t` is how far along (0..1) and `d`
/// is the perpendicular distance. Membership of a limb has to be measured
/// against the limb's own bone — anything simpler catches half the body.
function onSegment(p, a, b) {
  const ab = sub(b, a);
  const ap = sub(p, a);
  const len = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  let t = len === 0 ? 0 : (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / len;
  t = Math.max(0, Math.min(1, t));
  const d = Math.hypot(
    ap[0] - ab[0] * t, ap[1] - ab[1] * t, ap[2] - ab[2] * t);
  return { t, d };
}

/// Arms brought down, legs brought under the hips.
///
/// The source's 51°-from-vertical A-pose reads as a specimen on a slab. This
/// takes it to about 28°, which is a person standing — but deliberately not to
/// 0°: arms flat against the ribs would bury the lats, and the lats are one of
/// the thirteen things this screen exists to let you tap.
function pose(verts, fibre) {
  const ARM = -0.40;  // ~23°, leaving the arm clear of the ribs
  const LEG = -0.105; // ~6°, closing most of the stance
  const origin = [0, 0, 0];

  for (let i = 0; i < verts.length; i++) {
    const p = verts[i];
    const side = p[0] >= 0 ? 1 : -1;
    const shoulder = [SHOULDER[0] * side, SHOULDER[1], SHOULDER[2]];
    const hip = [HIP[0] * side, HIP[1], HIP[2]];

    // Arm membership: close to the arm bone, and far enough from the shoulder
    // joint itself that the cap deforms like a ball joint instead of creasing.
    // Both halves are needed — the ribs sit near the top of that bone, and the
    // legs lie straight along the direction it points.
    const hand = [HAND[0] * side, HAND[1], HAND[2]];
    const arm = onSegment(p, shoulder, hand);
    const fromJoint = Math.hypot(
      p[0] - shoulder[0], p[1] - shoulder[1], p[2] - shoulder[2]);
    const armW =
      smoothstep(0.135, 0.030, arm.d) * smoothstep(0.045, 0.175, fromJoint);
    const legW = smoothstep(1.00, 0.86, p[1]);

    const turn = ARM * side * armW + LEG * side * legW;
    if (turn === 0) continue;

    rotateZ(p, shoulder, ARM * side * armW);
    rotateZ(p, hip, LEG * side * legW);

    // Fibre is a direction, so it turns with the limb but never translates —
    // rotate it about the origin by the same total angle. Striations that kept
    // their rest-pose orientation would run across a lowered arm instead of
    // down it.
    const f = [fibre[i * 3], fibre[i * 3 + 1], fibre[i * 3 + 2]];
    rotateZ(f, origin, turn);
    fibre[i * 3] = f[0];
    fibre[i * 3 + 1] = f[1];
    fibre[i * 3 + 2] = f[2];
  }
}

// ── Parse ──────────────────────────────────────────────────────────────
function parseObj(text) {
  const positions = [];
  const faces = [];
  let group = null;

  for (const line of text.split('\n')) {
    if (line.startsWith('v ')) {
      const p = line.split(/\s+/);
      positions.push([+p[1], +p[2], +p[3]]);
    } else if (line.startsWith('g ')) {
      group = line.slice(2).trim();
    } else if (line.startsWith('f ') && SKIN_GROUPS.has(group)) {
      const idx = line
        .trim()
        .split(/\s+/)
        .slice(1)
        .map((t) => parseInt(t.split('/')[0], 10) - 1);
      // The source is quads; fan-triangulate. Every face in this mesh is
      // planar and convex, so a fan is exact.
      for (let i = 1; i + 1 < idx.length; i++) {
        faces.push([idx[0], idx[i], idx[i + 1]]);
      }
    }
  }
  return { positions, faces };
}

// ── Build ──────────────────────────────────────────────────────────────
function main() {
  if (!existsSync(SOURCE)) {
    console.error(
      `No source mesh at ${SOURCE}.\n` +
        'Drop a human body .obj there (single closed skin surface, A-pose,\n' +
        '20k-80k triangles) and re-run.',
    );
    process.exit(1);
  }

  const { positions, faces } = parseObj(readFileSync(SOURCE, 'utf8'));
  if (!faces.length) {
    throw new Error(`No faces found in ${[...SKIN_GROUPS].join(', ')}.`);
  }

  // Only the vertices the skin actually uses; the source array also holds the
  // scaffolding's. Re-index down to a dense set.
  const remap = new Map();
  const verts = [];
  const tris = [];
  for (const f of faces) {
    const t = [];
    for (const vi of f) {
      let n = remap.get(vi);
      if (n === undefined) {
        n = verts.length;
        remap.set(vi, n);
        verts.push(positions[vi].slice());
      }
      t.push(n);
    }
    tris.push(t);
  }

  const capped = capHoles(verts, tris);

  // Normalise: feet on the ground, 1.8 tall, centred left-to-right.
  let minY = Infinity, maxY = -Infinity, minX = Infinity, maxX = -Infinity;
  for (const v of verts) {
    if (v[1] < minY) minY = v[1];
    if (v[1] > maxY) maxY = v[1];
    if (v[0] < minX) minX = v[0];
    if (v[0] > maxX) maxX = v[0];
  }
  const scale = TARGET_HEIGHT / (maxY - minY);
  const cx = (minX + maxX) / 2;
  for (const v of verts) {
    v[0] = (v[0] - cx) * scale;
    v[1] = (v[1] - minY) * scale;
    v[2] = v[2] * scale;
  }

  replaceHead(verts, tris);

  // Every shell has to face outward before anything downstream reads a normal.
  // Cheap, and it fails loudly rather than shipping a figure whose head is
  // inside out — which is exactly what happened for as long as nobody looked.
  const inverted = shellVolumes(verts, tris).filter((s) => s.volume <= 0);
  if (inverted.length) {
    throw new Error(
      `${inverted.length} shell(s) wound inside out ` +
        `(${inverted.map((s) => `${s.tris} tris`).join(', ')}). ` +
        'Reverse their triangle order at the source.',
    );
  }

  // Classify in the *rest* pose. The sites in muscle_regions.mjs are authored
  // against the skeleton the source ships with, so they have to be read before
  // anything moves — after which the ids simply travel with their vertices.
  const sites = expandSites();
  const muscleId = new Uint8Array(verts.length);
  const fibre = new Float32Array(verts.length * 3);

  for (let i = 0; i < verts.length; i++) {
    let best = -1;
    let bestD = Infinity;
    for (let s = 0; s < sites.length; s++) {
      // Divide by weight rather than multiply the distance: a site's weight
      // then reads as "how far it reaches", which is the tunable that matters.
      const d = distSqToSite(verts[i], sites[s]) / (sites[s].w * sites[s].w);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    muscleId[i] = sites[best].muscle;
    const f = norm(sites[best].fibre);
    fibre[i * 3] = f[0];
    fibre[i * 3 + 1] = f[1];
    fibre[i * 3 + 2] = f[2];
  }

  sculpt(verts);
  pose(verts, fibre);

  // Normals come last, off the posed geometry — they drive the rim term, and a
  // rim computed from the rest pose would light the wrong edges.
  const normals = verts.map(() => [0, 0, 0]);
  for (const [i0, i1, i2] of tris) {
    const n = cross(sub(verts[i1], verts[i0]), sub(verts[i2], verts[i0]));
    for (const i of [i0, i1, i2]) {
      normals[i][0] += n[0];
      normals[i][1] += n[1];
      normals[i][2] += n[2];
    }
  }
  for (let i = 0; i < normals.length; i++) normals[i] = norm(normals[i]);

  // Relax the boundaries. Nearest-site gives clean regions but ragged edges
  // where two sites are near-tied; a few majority passes over the mesh graph
  // makes the seams follow the form instead of the triangulation.
  const adjacency = Array.from({ length: verts.length }, () => new Set());
  for (const [a, b, c] of tris) {
    adjacency[a].add(b); adjacency[a].add(c);
    adjacency[b].add(a); adjacency[b].add(c);
    adjacency[c].add(a); adjacency[c].add(b);
  }
  for (let pass = 0; pass < 4; pass++) {
    const next = muscleId.slice();
    for (let i = 0; i < verts.length; i++) {
      const tally = new Map();
      // Self counts double so a stable region can't be flipped by a bare
      // majority of its neighbours, which would make the passes oscillate.
      tally.set(muscleId[i], 2);
      for (const j of adjacency[i]) {
        tally.set(muscleId[j], (tally.get(muscleId[j]) || 0) + 1);
      }
      let win = muscleId[i];
      let winN = -1;
      for (const [k, n] of tally) if (n > winN) { winN = n; win = k; }
      next[i] = win;
    }
    muscleId.set(next);
  }

  // How deep inside its own group each vertex sits, in graph rings out from
  // the nearest border with another group.
  //
  // This is where the figure's internal anatomy comes from. The source mesh is
  // smooth — it has no pec, no lat, no rectus to catch light. Darkening the
  // last few rings before a border draws the separation lines between groups
  // instead, so chest reads apart from abs and the deltoid reads apart from
  // the arm, on geometry that never had either.
  const border = new Uint8Array(verts.length);
  {
    const ring = new Int32Array(verts.length).fill(-1);
    let frontier = [];
    for (let i = 0; i < verts.length; i++) {
      for (const j of adjacency[i]) {
        if (muscleId[j] !== muscleId[i]) { ring[i] = 0; frontier.push(i); break; }
      }
    }
    let depth = 0;
    while (frontier.length) {
      const nextRing = [];
      depth++;
      for (const i of frontier) {
        for (const j of adjacency[i]) {
          if (ring[j] === -1) { ring[j] = depth; nextRing.push(j); }
        }
      }
      frontier = nextRing;
    }
    // Five rings to fade over. Fewer and the groove is a hard line; more and
    // small groups like the deltoid never reach full brightness at all.
    const SPAN = 5;
    for (let i = 0; i < verts.length; i++) {
      const r = ring[i] < 0 ? SPAN : Math.min(ring[i], SPAN);
      border[i] = Math.round((r / SPAN) * 255);
    }
  }

  // ── Checks ───────────────────────────────────────────────────────────
  const counts = new Map();
  for (const m of muscleId) counts.set(m, (counts.get(m) || 0) + 1);

  const missing = MUSCLE_IDS.filter((_, i) => !counts.get(i));
  if (missing.length) {
    throw new Error(
      `These groups claimed no surface: ${missing.join(', ')}. ` +
        'Raise their weight in tool/muscle_regions.mjs.',
    );
  }
  for (const m of muscleId) {
    if (m > STRUCTURAL) throw new Error(`Vertex got an invalid id ${m}.`);
  }

  // ── Write ────────────────────────────────────────────────────────────
  const vc = verts.length;
  const ic = tris.length * 3;

  const position = new Float32Array(vc * 3);
  const normal = new Float32Array(vc * 3);
  for (let i = 0; i < vc; i++) {
    position.set(verts[i], i * 3);
    normal.set(normals[i], i * 3);
  }
  const index = new Uint32Array(ic);
  for (let t = 0; t < tris.length; t++) index.set(tris[t], t * 3);

  // Byte blocks are padded to a multiple of 4 so every block after them stays
  // 4-byte aligned and the reader can use typed-array views directly.
  const bytePadded = Math.ceil(vc / 4) * 4;
  const header = 16;
  const buffer = Buffer.alloc(
    header + position.byteLength + normal.byteLength + fibre.byteLength +
      bytePadded * 2 + index.byteLength,
  );

  buffer.write('ARCBODY2', 0, 'ascii');
  buffer.writeUInt32LE(vc, 8);
  buffer.writeUInt32LE(ic, 12);

  let o = header;
  const put = (typed) => {
    Buffer.from(typed.buffer, typed.byteOffset, typed.byteLength).copy(buffer, o);
    o += typed.byteLength;
  };
  put(position);
  put(normal);
  put(fibre);
  Buffer.from(muscleId.buffer, 0, vc).copy(buffer, o);
  o += bytePadded;
  Buffer.from(border.buffer, 0, vc).copy(buffer, o);
  o += bytePadded;
  put(index);

  writeFileSync(OUT, buffer);

  // Report by *area*, not by vertex count. The source mesh puts most of its
  // topology in the face, hands and feet, so vertex share says almost nothing
  // about how much body a region covers — and the renderer samples particles
  // by area, so area is what actually reaches the screen.
  const area = new Map();
  let total = 0;
  for (const [i0, i1, i2] of tris) {
    const n = cross(sub(verts[i1], verts[i0]), sub(verts[i2], verts[i0]));
    const a = Math.hypot(n[0], n[1], n[2]) / 2;
    total += a;
    // A triangle's area is split between whichever groups its corners hold, so
    // boundary triangles are credited to both rather than to whichever vertex
    // happened to come first.
    for (const v of [i0, i1, i2]) {
      area.set(muscleId[v], (area.get(muscleId[v]) || 0) + a / 3);
    }
  }

  const label = (i) => (i === STRUCTURAL ? 'structural' : MUSCLE_IDS[i]);
  const sorted = [...area.entries()].sort((a, b) => b[1] - a[1]);
  console.log(`${vc} vertices, ${tris.length} triangles, ${capped} holes capped`);
  console.log('surface area by group:');
  for (const [m, a] of sorted) {
    const pct = ((a / total) * 100).toFixed(1).padStart(5);
    const bar = '#'.repeat(Math.max(1, Math.round((a / total) * 120)));
    console.log(`  ${pct}%  ${label(m).padEnd(11)} ${bar}`);
  }
  console.log(`\nwrote ${OUT} (${(buffer.length / 1024).toFixed(0)} KB)`);
}

main();
