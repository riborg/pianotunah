// Enhetstester för stämteori och signalbehandling. Körs med: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  computeTargets, temperamentOffsets, partialFreq, centsBetween, noteName,
  migrateSettings, DEFAULT_SETTINGS,
} from '../web/js/theory.js';
import { Analyzer } from '../web/js/dsp.js';

const SR = 48000;
const N = 32768;
const T = computeTargets(DEFAULT_SETTINGS);

// Syntetisk ton med inharmonicitet B; grundtonen dämpad i basen som på ett piano.
function tone(k, detune = 0, B = T.B[k]) {
  const f0 = (T.freq[k] * 2 ** (detune / 1200)) / Math.sqrt(1 + B);
  const buf = new Float32Array(N);
  for (let p = 1; p <= 16; p++) {
    const f = p * f0 * Math.sqrt(1 + B * p * p);
    if (f > SR / 2.2) break;
    const a = (k < 20 && p === 1 ? 0.05 : 1) / p ** 0.8;
    for (let i = 0; i < N; i++) buf[i] += a * Math.sin((2 * Math.PI * f * i) / SR + p);
  }
  for (let i = 0; i < N; i++) buf[i] += (Math.random() - 0.5) * 0.01;
  return buf;
}

const analyse = (buf) => {
  const A = new Analyzer(SR);
  A.load(buf);
  return A;
};

test('temperaturer: Werckmeister III mot publicerade värden (A = 0)', () => {
  const w = temperamentOffsets('werckmeister3').map((x) => Math.round(x * 10) / 10);
  assert.deepEqual(w, [11.7, 2, 3.9, 5.9, 2, 9.8, 0, 7.8, 3.9, 0, 7.8, 3.9]);
});

test('liksvävande utan stretch ger exakt 12-TET', () => {
  const t = computeTargets({ ...DEFAULT_SETTINGS, stretch: 'none' });
  assert.ok(Math.abs(t.freq[49] - 440) < 1e-9);
  assert.ok(Math.abs(t.freq[1] - 27.5) < 1e-9);
});

test('stretch: basen lägre, diskanten högre, mer för mindre pianon', () => {
  const small = computeTargets({ ...DEFAULT_SETTINGS, sizeCm: 100 });
  const grand = computeTargets({ ...DEFAULT_SETTINGS, pianoKind: 'grand', sizeCm: 274 });
  assert.ok(small.cents[1] < grand.cents[1] && grand.cents[1] < 0);
  assert.ok(small.cents[88] > grand.cents[88] && grand.cents[88] > 0);
});

test('gamla instrumentval översätts', () => {
  assert.deepEqual(migrateSettings({ pianoType: 'old85' }), { pianoKind: 'upright', sizeCm: 120, keyCount: 85 });
});

test('tangentigenkänning A0–C8, även med svag grundton i basen', () => {
  for (const k of [1, 6, 13, 20, 25, 32, 37, 44, 49, 56, 61, 68, 73, 80, 85, 88]) {
    const d = analyse(tone(k)).detectKey(T);
    assert.equal(noteName(d.key), noteName(k));
  }
});

test('mätning av delton på hundradels cent', () => {
  for (const [k, n, det] of [[49, 1, 3], [13, 6, -7.5], [25, 4, 1.2], [76, 1, -2]]) {
    const target = partialFreq(T.freq[k], T.B[k], n);
    const m = analyse(tone(k, det)).measure(target, 150, 8);
    assert.ok(Math.abs(centsBetween(m.freq, target) - det) < 0.05, `${noteName(k)}`);
  }
});

test('kraftigt nedstämd ton hittas med brett fönster', () => {
  const target = T.freq[49];
  const m = analyse(tone(49, -140)).measure(target, 150, 8);
  assert.ok(Math.abs(centsBetween(m.freq, target) + 140) < 0.1);
});

test('inharmonicitet skattas ur deltonerna', () => {
  for (const [k, B] of [[13, 0.0003], [49, 0.0004], [76, 0.003]]) {
    const r = analyse(tone(k, 0, B)).inharmonicity(T.freq[k], T.B[k]);
    assert.ok(Math.abs(r.B / B - 1) < 0.02, `${noteName(k)}: ${r.B}`);
  }
});
