// Unit tests for tuning theory and signal processing. Run with: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  computeTargets, temperamentOffsets, partialFreq, centsBetween, noteName,
  migrateSettings, recommendedOverpull, DEFAULT_SETTINGS,
} from '../web/js/theory.js';
import { Analyzer } from '../web/js/dsp.js';
import { wavBlob } from '../web/js/mic.js';
import { newRun, nextPending, handled, wrongKey } from '../web/js/mapping.js';

const SR = 48000;
const N = 32768;
const T = computeTargets(DEFAULT_SETTINGS);

// Seeded noise so the tests are deterministic.
let seed = 1;
const noise = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648 - 0.5) * 0.01;

// Synthetic tone with inharmonicity B; the fundamental damped in the bass as on a piano.
const tone = (k, detune = 0, B = T.B[k]) => toneFor(T, k, detune, B);

function toneFor(t, k, detune = 0, B = t.B[k]) {
  const f0 = (t.freq[k] * 2 ** (detune / 1200)) / Math.sqrt(1 + B);
  const buf = new Float32Array(N);
  for (let p = 1; p <= 16; p++) {
    const f = p * f0 * Math.sqrt(1 + B * p * p);
    if (f > SR / 2.2) break;
    const a = (k < 20 && p === 1 ? 0.05 : 1) / p ** 0.8;
    for (let i = 0; i < N; i++) buf[i] += a * Math.sin((2 * Math.PI * f * i) / SR + p);
  }
  for (let i = 0; i < N; i++) buf[i] += noise();
  return buf;
}

const analyse = (buf) => {
  const A = new Analyzer(SR);
  A.load(buf);
  return A;
};

test('temperaments: Werckmeister III against published values (A = 0)', () => {
  const w = temperamentOffsets('werckmeister3').map((x) => Math.round(x * 10) / 10);
  assert.deepEqual(w, [11.7, 2, 3.9, 5.9, 2, 9.8, 0, 7.8, 3.9, 0, 7.8, 3.9]);
});

test('equal temperament without stretch gives exact 12-TET', () => {
  const t = computeTargets({ ...DEFAULT_SETTINGS, stretch: 'none' });
  assert.ok(Math.abs(t.freq[49] - 440) < 1e-9);
  assert.ok(Math.abs(t.freq[1] - 27.5) < 1e-9);
});

test('stretch: bass lower, treble higher, more for smaller pianos', () => {
  const small = computeTargets({ ...DEFAULT_SETTINGS, sizeCm: 100 });
  const grand = computeTargets({ ...DEFAULT_SETTINGS, pianoKind: 'grand', sizeCm: 274 });
  assert.ok(small.cents[1] < grand.cents[1] && grand.cents[1] < 0);
  assert.ok(small.cents[88] > grand.cents[88] && grand.cents[88] > 0);
});

test('old instrument choices are migrated', () => {
  assert.deepEqual(migrateSettings({ pianoType: 'old85' }), { pianoKind: 'upright', sizeCm: 120, keyCount: 85 });
});

test('recommended overpull: none for small deviations, 25% when flat', () => {
  assert.equal(recommendedOverpull(-5), 0);
  assert.equal(recommendedOverpull(15), 0);
  assert.equal(recommendedOverpull(-15.7), 25); // 436 Hz against 440 Hz
});

test('key detection on all 88 keys, two piano sizes, in tune and 20 cents flat', () => {
  for (const settings of [DEFAULT_SETTINGS, { ...DEFAULT_SETTINGS, sizeCm: 100 }]) {
    const t = computeTargets(settings);
    for (let k = 1; k <= 88; k++) {
      for (const det of [0, -20]) {
        const A = analyse(toneFor(t, k, det));
        assert.equal(noteName(A.detectKey(t).key), noteName(k), `${noteName(k)} ${det} cent`);
      }
    }
  }
});

test('B♭0 with a strong 5th partial is not taken for D3', () => {
  // Peaks (Hz, amplitude) of B♭0 recorded with a laptop microphone, where
  // detection picked D3, the key 28 semitones up.
  const peaks = [
    [84.72, 0.0048], [113.38, 0.0061], [141.59, 0.0062], [171.19, 0.0015], [200.06, 0.00083],
    [230.4, 0.00061], [260.12, 0.00058], [290.83, 0.0017], [321.41, 0.0021], [352.63, 0.0057],
    [384.16, 0.0021], [416.63, 0.00062], [449.45, 0.0022], [482.87, 0.00039], [517.07, 0.00015],
    [550.53, 0.00027], [586.02, 0.0015], [621.2, 0.0018], [658.2, 0.0004], [694.64, 0.0013],
    [737.03, 0.00036], [800.93, 0.00015], [809.39, 0.00012], [833.6, 0.00017], [865.89, 0.00015],
    [889.36, 0.00013], [899.36, 0.00027], [931.1, 0.00025], [972.54, 0.00049], [1015.1, 0.00044],
    [1033.25, 0.00026], [1058.33, 0.00023], [1102.12, 0.00034], [1147.54, 0.00028], [1192.89, 8.9e-05],
    [1244.48, 4.6e-05], [1279.09, 6.6e-05], [1286.27, 7.9e-05], [1334.49, 3.2e-05], [1353.75, 6.2e-05],
    [1383.18, 0.00013], [1433.78, 9.1e-05], [1485.37, 2.2e-05], [1547.12, 1.6e-05], [1590.2, 1.3e-05],
    [1698.11, 1.3e-05],
  ];
  const sr = 44100;
  const buf = new Float32Array(N);
  peaks.forEach(([f, a], j) => {
    for (let i = 0; i < N; i++) buf[i] += a * Math.sin((2 * Math.PI * f * i) / sr + j);
  });
  for (let i = 0; i < N; i++) buf[i] += noise() * 0.16;
  const A = new Analyzer(sr);
  A.load(buf);
  assert.equal(noteName(A.detectKey(T).key), 'B♭0');
});

test('partial measured to a hundredth of a cent', () => {
  for (const [k, n, det] of [[49, 1, 3], [13, 6, -7.5], [25, 4, 1.2], [76, 1, -2]]) {
    const target = partialFreq(T.freq[k], T.B[k], n);
    const m = analyse(tone(k, det)).measure(target, 150, 8);
    assert.ok(Math.abs(centsBetween(m.freq, target) - det) < 0.05, `${noteName(k)}`);
  }
});

test('badly flat note is found with a wide window', () => {
  const target = T.freq[49];
  const m = analyse(tone(49, -140)).measure(target, 150, 8);
  assert.ok(Math.abs(centsBetween(m.freq, target) + 140) < 0.1);
});

test('inharmonicity is estimated from the partials', () => {
  for (const [k, B] of [[13, 0.0003], [49, 0.0004], [76, 0.003]]) {
    const r = analyse(tone(k, 0, B)).inharmonicity(T.freq[k], T.B[k]);
    assert.ok(Math.abs(r.B / B - 1) < 0.02, `${noteName(k)}: ${r.B}`);
  }
});

test('survey run: ends when every planned key is measured or skipped', () => {
  const run = newRun('quick', 88, () => true); // earlier surveys do not count for the quick plan
  const seen = [];
  for (let k = nextPending(run, 'quick', 88, 0); k; k = nextPending(run, 'quick', 88, k)) {
    seen.push(k);
    (k === 37 ? run.skipped : run.done).add(k);
  }
  assert.deepEqual(seen, [1, 13, 25, 37, 49, 61, 73, 85]);
  assert.ok(handled(run, 37) && run.skipped.size === 1);
});

test('survey run: a full survey resumes, wraps around and starts over when complete', () => {
  const mapped = (k) => k <= 10 || k === 50;
  const run = newRun('full', 88, mapped);
  assert.equal(nextPending(run, 'full', 88, 0), 11);
  assert.equal(nextPending(run, 'full', 88, 49), 51);
  assert.equal(nextPending(run, 'full', 88, 88), 11);
  assert.equal(newRun('full', 88, () => true).done.size, 0);
});

test('survey: wrong key is recognised, a flat piano is not', () => {
  const clear = (key) => ({ key, score: 20, margin: 10 });
  const T2 = computeTargets(DEFAULT_SETTINGS);
  // A3 struck when A2 is asked for: detection hears A3.
  const heard = analyse(toneFor(T2, 37)).detectKey(T2);
  assert.equal(wrongKey(heard, 25, -5, NaN), 37);
  // B♭4 instead of A4 on a piano that is otherwise in tune.
  assert.equal(wrongKey(clear(50), 49, 100, 0), 50);
  // B♭4 again, but detection is unsure: the pitch alone gives it away.
  assert.equal(wrongKey(null, 49, 100, 0), -1);
  // A4 on a piano 80 cents flat: detection picks A♭4, the other keys lay as low.
  assert.equal(wrongKey(clear(48), 49, -80, -75), 0);
  // First key of a run on a flat piano: no reference yet, so a neighbour is accepted.
  assert.equal(wrongKey(clear(48), 49, -80, NaN), 0);
  assert.equal(wrongKey(clear(49), 49, 0, 0), 0);
  // A2 still ringing when A3 is struck.
  assert.equal(wrongKey(clear(25), 37, 0, 0, new Set([25])), 0);
});

test('recording: mono 32-bit float WAV', async () => {
  const v = new DataView(await wavBlob([new Float32Array([0.5, -0.25]), new Float32Array([1])], 44100).arrayBuffer());
  const str = (o) => String.fromCharCode(...[0, 1, 2, 3].map((i) => v.getUint8(o + i)));
  assert.deepEqual([str(0), str(8), str(12), str(36)], ['RIFF', 'WAVE', 'fmt ', 'data']);
  assert.equal(v.getUint32(4, true), v.byteLength - 8);
  assert.deepEqual([v.getUint16(20, true), v.getUint16(22, true), v.getUint32(24, true), v.getUint16(34, true)], [3, 1, 44100, 32]);
  assert.equal(v.getUint32(40, true), 12);
  assert.deepEqual([0, 1, 2].map((i) => v.getFloat32(44 + i * 4, true)), [0.5, -0.25, 1]);
});
