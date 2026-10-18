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

// Seedat brus så att testerna är deterministiska.
let seed = 1;
const noise = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648 - 0.5) * 0.01;

// Syntetisk ton med inharmonicitet B; grundtonen dämpad i basen som på ett piano.
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

test('tangentigenkänning alla 88 tangenter, två pianostorlekar, i stäm och 20 cent lågt', () => {
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
