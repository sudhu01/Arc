// Writes Arc's default rest alarm.
//
// Not a chime. Arc's voice is a training partner who counts your reps and does
// not compliment you, so the alarm is three flat beeps that mean "go" — an
// interval timer at the track, not a meditation app. A 1245 Hz fundamental sits
// in the band that carries over gym noise without being shrill, and a short
// linear ramp on each edge keeps the transition off the speaker's click.
//
// The file is written twice, byte for byte:
//   assets/sound/arc_rest.wav          — what audioplayers plays in-app
//   android/.../res/raw/arc_rest.wav   — what the notification channel plays
//                                        once Android has killed the process
// They have to be the same sound, so they are the same bytes.
//
//   node tool/make_rest_tone.mjs

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const RATE = 44100;
const FREQ = 1245; // ~D#6
const BEEP = 0.12; // seconds of tone
const GAP = 0.09; // seconds of silence between beeps
const BEEPS = 3;
const EDGE = 0.006; // fade in/out, kills the click
const PEAK = 0.62; // headroom under full scale

/** One beep followed by its gap, as float samples in [-1, 1]. */
function beep() {
  const tone = Math.round(RATE * BEEP);
  const gap = Math.round(RATE * GAP);
  const edge = Math.round(RATE * EDGE);
  const out = new Float32Array(tone + gap);

  for (let i = 0; i < tone; i++) {
    // Fundamental plus a quiet octave: the harmonic is what gives the beep an
    // edge on a phone speaker, where a pure sine reads as soft.
    const t = i / RATE;
    const s =
      Math.sin(2 * Math.PI * FREQ * t) + 0.28 * Math.sin(4 * Math.PI * FREQ * t);
    const ramp = Math.min(1, i / edge, (tone - i) / edge);
    out[i] = (s / 1.28) * PEAK * ramp;
  }
  return out;
}

function render() {
  const one = beep();
  const out = new Float32Array(one.length * BEEPS);
  for (let n = 0; n < BEEPS; n++) out.set(one, n * one.length);
  return out;
}

/** 16-bit mono PCM in a canonical 44-byte WAV header. */
function wav(samples) {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    data.writeInt16LE(Math.round(clamped * 32767), i * 2);
  }

  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16); // PCM chunk size
  header.writeUInt16LE(1, 20); // format: PCM
  header.writeUInt16LE(1, 22); // channels
  header.writeUInt32LE(RATE, 24);
  header.writeUInt32LE(RATE * 2, 28); // byte rate
  header.writeUInt16LE(2, 32); // block align
  header.writeUInt16LE(16, 34); // bits per sample
  header.write('data', 36);
  header.writeUInt32LE(data.length, 40);

  return Buffer.concat([header, data]);
}

const bytes = wav(render());
const targets = [
  'assets/sound/arc_rest.wav',
  'android/app/src/main/res/raw/arc_rest.wav',
];

for (const rel of targets) {
  const path = resolve(root, rel);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
  console.log(`wrote ${rel} (${bytes.length} bytes)`);
}
