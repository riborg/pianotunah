// Writes the parity fixtures for the Swift core (mac/) from the web JS.
// See docs/macos-port.md, step 1. Run with:
//   docker run --rm -v "$PWD":/app -w /app node:26-alpine node test/fixtures.mjs
// The output is byte-stable: run it twice and git sees no change. CI checks
// that the committed fixtures match the JS.
//
// The two piano documents are sanitized copies of real pianos in data/,
// which is not in git. To take new copies (replaces piano/a and piano/b):
//   docker run --rm -v "$PWD":/app -w /app node:26-alpine node test/fixtures.mjs --pianos data
//
// Numbers that JSON cannot hold are strings: "NaN", "Infinity", "-Infinity"
// and "-0". Typed arrays are written as plain arrays, Sets as sorted arrays.

import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// i18n.js reads the stored language when it is imported; format.js imports it.
const storage = new Map();
const localStorageStub = {
  getItem: (k) => (storage.has(k) ? storage.get(k) : null),
  setItem: (k, v) => storage.set(k, String(v)),
  removeItem: (k) => storage.delete(k),
};
Object.defineProperty(globalThis, 'localStorage', { value: localStorageStub, configurable: true, writable: true });

const theory = await import('../web/js/theory.js');
const dsp = await import('../web/js/dsp.js');
const survey = await import('../web/js/survey.js');
const order = await import('../web/js/order.js');
const format = await import('../web/js/format.js');
const i18n = await import('../web/js/i18n.js');
const store = await import('../web/js/store.js');

const { computeTargets, temperamentOffsets, migrateSettings, bOutliers, DEFAULT_SETTINGS, TEMPERAMENTS, partialFreq, defaultPartial } = theory;

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'mac/Tests/PianoTunahCoreTests/Fixtures');

// ---------------------------------------------------------------------------
// Writing

const enc = (v) => {
  if (typeof v === 'number') {
    if (Number.isNaN(v)) return 'NaN';
    if (v === Infinity) return 'Infinity';
    if (v === -Infinity) return '-Infinity';
    if (Object.is(v, -0)) return '-0';
  }
  return v;
};

// Arrays of scalars on one line, and anything else that fits in WIDTH
// characters; otherwise one element or key per line.
const WIDTH = 160;
function serialize(v, ind = '') {
  if (ArrayBuffer.isView(v)) v = Array.from(v);
  if (v instanceof Set) v = [...v].sort((a, b) => a - b);
  if (v === undefined) v = null;
  if (v === null || typeof v !== 'object') return JSON.stringify(enc(v));
  const inner = ind + '  ';
  const short = (parts, open, close) => {
    const one = open + parts.join(', ') + close;
    return one.length <= WIDTH && !one.includes('\n') ? one : null;
  };
  if (Array.isArray(v)) {
    if (!v.length) return '[]';
    const parts = v.map((x) => serialize(x, inner));
    if (v.every((x) => x === null || x === undefined || typeof x !== 'object')) return '[' + parts.join(', ') + ']';
    return short(parts, '[', ']') ?? '[\n' + parts.map((x) => inner + x).join(',\n') + '\n' + ind + ']';
  }
  const keys = Object.keys(v).filter((k) => v[k] !== undefined);
  if (!keys.length) return '{}';
  const parts = keys.map((k) => JSON.stringify(k) + ': ' + serialize(v[k], inner));
  return short(parts, '{', '}') ?? '{\n' + parts.map((x) => inner + x).join(',\n') + '\n' + ind + '}';
}

const written = [];
function write(path, data) {
  const file = join(OUT, path);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, typeof data === 'string' ? data : serialize(data) + '\n');
  written.push(path);
}

function writeF32(path, buf) {
  const v = new DataView(new ArrayBuffer(buf.length * 4));
  buf.forEach((x, i) => v.setFloat32(i * 4, x, true));
  const file = join(OUT, path);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, new Uint8Array(v.buffer));
  written.push(path);
}

const sorted = (xs) => [...xs].sort((a, b) => a - b);

// ---------------------------------------------------------------------------
// Piano documents: sanitized copies of the real ones, then normalize.

const FAKE_IDS = { a: '00000000-0000-4000-8000-00000000000a', b: '00000000-0000-4000-8000-00000000000b' };

const pianosFrom = process.argv.includes('--pianos') ? process.argv[process.argv.indexOf('--pianos') + 1] : null;
if (pianosFrom) {
  const files = readdirSync(join(ROOT, pianosFrom)).filter((f) => f.endsWith('.json')).sort().slice(0, 2);
  if (files.length !== 2) throw new Error(`need two pianos in ${pianosFrom}, found ${files.length}`);
  files.forEach((f, i) => {
    const which = 'ab'[i];
    const doc = JSON.parse(readFileSync(join(ROOT, pianosFrom, f), 'utf8'));
    // Replaced in place, so the key order is the file's.
    doc.id = FAKE_IDS[which];
    doc.name = `Fixture piano ${which.toUpperCase()}`;
    doc.notes = '';
    write(`piano/${which}.input.json`, doc);
  });
}

// Saved before kind, size and unisons existed, without most of the fields,
// and with a field the web does not know (kept on a round trip).
const legacy = {
  id: '00000000-0000-4000-8000-00000000000c',
  name: 'Fixture piano C',
  createdAt: '2025-01-02T03:04:05.006Z',
  updatedAt: '2025-01-02T03:04:05.006Z',
  passStartedAt: '2025-01-02T03:04:05.006Z',
  settings: { refA4: 442, temperament: 'vallotti', root: 2, stretch: 'light', pianoType: 'concert', tolerance: 2 },
  inharmonicity: { 1: 0.00041, 49: 0.00052, 88: 0.0161 },
  keys: { 49: { hz: 441.3, n: 1, at: 1735787045006 } },
  extra: { kept: true, list: [1, 'two', null] },
};
write('piano/c.input.json', legacy);

const pianos = {};
for (const which of ['a', 'b', 'c']) {
  const input = JSON.parse(readFileSync(join(OUT, `piano/${which}.input.json`), 'utf8'));
  const out = store.normalize(JSON.parse(JSON.stringify(input)));
  // normalize fills in a new id and the time for fields that are missing;
  // the inputs have them all, so the result does not depend on the clock.
  for (const f of ['id', 'createdAt', 'updatedAt', 'passStartedAt']) {
    if (out[f] !== input[f]) throw new Error(`piano ${which}: ${f} is generated, the fixture would not be stable`);
  }
  pianos[which] = out;
  write(`piano/${which}.normalized.json`, {
    about: 'store.normalize(input): settings through migrateSettings and over DEFAULT_SETTINGS, missing fields filled in. Decoding the input must give these values; encoding again must give the input back, key order aside.',
    input: `piano/${which}.input.json`,
    normalized: out,
    migratedSettings: migrateSettings(input.settings),
  });
}

// ---------------------------------------------------------------------------
// jsRound: Math.round, which rounds halves up (towards +∞).

{
  const xs = [
    0, -0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, -0.49999999999999994, 0.4, -0.4, 0.6, -0.6,
    0.5000000000000001, -0.5000000000000001, 1.4999999999999998, -1.4999999999999998, 3.7, -3.7, 12.345, -12.345,
    1e-300, -1e-300, 5e-324, -5e-324, 2 ** 52 - 0.5, -(2 ** 52 - 0.5), 2 ** 52, -(2 ** 52), 2 ** 52 + 1, 2 ** 53, -(2 ** 53),
    2 ** 53 + 2, 1e20, -1e20, 123456789.5, -123456789.5, 4503599627370495.5, -4503599627370495.5, Number.MAX_VALUE,
    -Number.MAX_VALUE, Number.MAX_SAFE_INTEGER, Number.MIN_VALUE, Infinity, -Infinity, NaN,
    0.1 + 0.2, 10.5, -10.5, 99.5, -99.5, 1e15 + 0.5, -1e15 - 0.5,
  ];
  write('jsround.json', {
    about: 'jsRound(x) must equal Math.round(x) exactly, including the sign of zero.',
    cases: xs.map((x) => ({ x, round: Math.round(x) })),
  });
}

// ---------------------------------------------------------------------------
// Theory

// Measured on a 120 cm upright (unit.test.mjs).
const JEHLE_A = { 1: 5.62e-4, 13: 2.26e-4, 25: 1.87e-4, 37: 3.28e-4, 49: 7.9e-4, 61: 2.41e-3, 73: 4.85e-3, 85: 9.96e-3 };
const OUTLIERS = { 12: 2.51e-4, 13: 2.26e-4, 14: 1.86e-3, 15: 2.48e-4, 16: 2.41e-4, 29: 1.92e-4, 30: 1.92e-4, 31: 1.78e-4, 32: 4.33e-4, 33: 4.13e-4, 34: 3.8e-4 };
const BREAKS = (() => {
  const model = computeTargets(DEFAULT_SETTINGS).B;
  const m = {};
  for (let k = 1; k <= 88; k++) m[k] = model[k] * (k >= 56 ? 2.4 * 1.8 : k >= 32 ? 2.4 : 1);
  return m;
})();
// Values bCurve has to leave out: zero, negative, off the keyboard.
const INVALID = { 0: 3e-4, 5: 0, 20: -1e-4, 49: 6e-4, 89: 1e-2, 90: 0.02 };
const LOW_OUTLIER = { 40: 4e-4, 41: 4.2e-4, 42: 0.5e-4, 43: 4.1e-4, 44: 4.3e-4 };

{
  const cases = [];
  const add = (name, settings, measuredB = {}) => {
    const T = computeTargets(settings, measuredB);
    cases.push({ name, settings, measuredB, B: T.B, stretch: T.stretch, temper: T.temper, cents: T.cents, freq: T.freq });
  };
  add('defaults', DEFAULT_SETTINGS);
  add('empty settings', {});
  for (const stretch of ['none', 'light', 'normal', 'wide', 'railsback']) add(`stretch ${stretch}`, { ...DEFAULT_SETTINGS, stretch });
  add('stretch unknown (normal)', { ...DEFAULT_SETTINGS, stretch: 'nonsense' });
  for (const [mid, treble, bass] of [['2:1', '2:1', '2:1'], ['4:2', '6:3', '8:4'], ['6:3', '2:1', '4:2'], ['8:4', '8:4', '8:4']]) {
    add(`custom ${mid} ${treble} ${bass}`, { ...DEFAULT_SETTINGS, stretch: 'custom', midOctave: mid, trebleOctave: treble, bassOctave: bass });
  }
  add('custom with unknown octave type (4:2)', { ...DEFAULT_SETTINGS, stretch: 'custom', midOctave: '3:1' });
  add('extra treble and bass', { ...DEFAULT_SETTINGS, extraTreble: 6, extraBass: 4 });
  add('wide with extra treble', { ...DEFAULT_SETTINGS, stretch: 'wide', extraTreble: 3 });
  add('none with extras', { ...DEFAULT_SETTINGS, stretch: 'none', extraTreble: 2, extraBass: -3 });
  add('railsback with extras', { ...DEFAULT_SETTINGS, stretch: 'railsback', extraTreble: 2, extraBass: 2 });
  for (const cm of [80, 90, 100, 110, 120, 130, 140, 150, 160]) add(`upright ${cm}`, { ...DEFAULT_SETTINGS, pianoKind: 'upright', sizeCm: cm });
  for (const cm of [140, 150, 165, 180, 220, 274, 275, 310]) add(`grand ${cm}`, { ...DEFAULT_SETTINGS, pianoKind: 'grand', sizeCm: cm });
  add('unknown kind (upright)', { ...DEFAULT_SETTINGS, pianoKind: 'harpsichord', sizeCm: 100 });
  add('size 0 (kind default)', { ...DEFAULT_SETTINGS, pianoKind: 'grand', sizeCm: 0 });
  add('85 keys', { ...DEFAULT_SETTINGS, keyCount: 85 });
  for (const id of Object.keys(TEMPERAMENTS)) {
    for (const root of [0, 5]) add(`${id} root ${root}`, { ...DEFAULT_SETTINGS, temperament: id, root });
  }
  add('unknown temperament (et)', { ...DEFAULT_SETTINGS, temperament: 'pythagorean' });
  for (const refA4 of [415, 435.5, 442, 466]) add(`refA4 ${refA4}`, { ...DEFAULT_SETTINGS, refA4 });
  add('measured All A', DEFAULT_SETTINGS, JEHLE_A);
  add('measured All A, grand 274', { ...DEFAULT_SETTINGS, pianoKind: 'grand', sizeCm: 274 }, JEHLE_A);
  add('measured with an outlier and a break', DEFAULT_SETTINGS, OUTLIERS);
  add('measured with a low outlier', DEFAULT_SETTINGS, LOW_OUTLIER);
  add('measured with breaks on every key', DEFAULT_SETTINGS, BREAKS);
  add('measured with breaks, wide, kirnberger3 root 5', { ...DEFAULT_SETTINGS, stretch: 'wide', temperament: 'kirnberger3', root: 5 }, BREAKS);
  add('measured invalid values', DEFAULT_SETTINGS, INVALID);
  add('measured one key', DEFAULT_SETTINGS, { 30: 2.5e-4 });
  for (const which of ['a', 'b', 'c']) add(`piano ${which}`, pianos[which].settings, pianos[which].inharmonicity);
  write('theory-targets.json', {
    about: 'computeTargets(settings, measuredB). Arrays are indexed by key, 0..88; index 0 is unused (0). Exact or within 1e-12 (relative for freq and B).',
    cases,
  });
}

{
  const ids = [...Object.keys(TEMPERAMENTS), 'unknown'];
  const offsets = {};
  for (const id of ids) offsets[id] = Array.from({ length: 12 }, (_, root) => temperamentOffsets(id, root));
  write('theory-temperaments.json', {
    about: 'temperamentOffsets(id, root) for every root 0..11: cents per pitch class (0 = C), A = 0. "unknown" falls back to et.',
    ids,
    offsets,
  });
}

{
  const migrate = [
    undefined, {}, { pianoType: 'concert' }, { pianoType: 'grand' }, { pianoType: 'upright' }, { pianoType: 'spinet' },
    { pianoType: 'old85' }, { pianoType: 'unknown' }, { pianoType: 'grand', pianoKind: 'upright', sizeCm: 110 },
    { refA4: 442, pianoType: 'old85', temperament: 'vallotti', sizeCm: 999 }, { pianoKind: 'grand', sizeCm: 200 },
  ].map((input) => ({ input: input ?? null, output: migrateSettings(input) }));
  const outliers = [
    JEHLE_A, OUTLIERS, LOW_OUTLIER, BREAKS, INVALID, {},
    { 10: 3e-4, 11: 9e-4, 13: 3e-4 }, // gap of two keys still counts as a neighbour
    { 10: 3e-4, 11: 9e-4, 15: 3e-4 }, // too far above: not judged
    { 1: 9e-4, 2: 3e-4, 3: 3e-4 }, // lowest key has no left side
    { 20: 2e-4, 21: 2e-4, 22: 4.1e-4, 23: 2e-4, 24: 2e-4 }, // just over twice
    { 20: 2e-4, 21: 2e-4, 22: 4e-4, 23: 2e-4, 24: 2e-4 }, // exactly twice: kept
  ].map((measured) => ({ measured, outliers: sorted(bOutliers(measured)) }));
  const keys = Array.from({ length: 88 }, (_, i) => i + 1);
  write('theory-misc.json', {
    about: 'migrateSettings (input null = called without an argument), bOutliers (as sorted keys) and small helpers. Exact.',
    migrateSettings: migrate,
    bOutliers: outliers,
    noteName: keys.map(theory.noteName),
    pitchClass: keys.map(theory.pitchClass),
    octave: keys.map(theory.octave),
    isBlack: keys.map(theory.isBlack),
    defaultPartial: keys.map(defaultPartial),
    sizeClass: [['upright', 100], ['upright', 110], ['upright', 124], ['upright', 125], ['grand', 169], ['grand', 170], ['grand', 219], ['grand', 220], ['other', 90]]
      .map(([kind, cm]) => ({ kind, cm, cls: theory.sizeClass(kind, cm) })),
    recommendedOverpull: [-15.7, -10, -9.99, 0, 15, NaN].map((cents) => ({ cents, percent: theory.recommendedOverpull(cents) })),
    octaveStretch: [[3e-4, 8e-4], [1.5e-4, 3e-4], [5e-3, 1.2e-2], [0, 0]].flatMap(([lo, up]) =>
      ['2:1', '4:2', '6:3', '8:4', 'unknown'].map((type) => ({ Blow: lo, Bup: up, type, cents: theory.octaveStretch(lo, up, type) }))),
    partialFreq: [[440, 4e-4, 1], [440, 4e-4, 4], [27.5, 5.6e-4, 6], [4186, 0.016, 2]].map(([f1, B, n]) => ({ f1, B, n, freq: partialFreq(f1, B, n) })),
    intervalBeat: (() => {
      const T = computeTargets(DEFAULT_SETTINGS);
      return [[33, 37], [33, 40], [37, 42], [37, 49], [33, 49], [25, 44], [61, 65], [13, 41], [40, 52, [4, 2]], [20, 32, [6, 3]]]
        .map(([lo, hi, p]) => ({ settings: 'defaults', lo, hi, p: p ?? theory.COINCIDENT[hi - lo], beat: theory.intervalBeat(T, lo, hi, p) }));
    })(),
  });
}

// ---------------------------------------------------------------------------
// Survey

{
  const runs = [];
  // Measures or skips the keys the run asks for, as the app does.
  const play = (name, plan, top, surveyed, skip = []) => {
    const run = survey.newRun(plan, top, (k) => surveyed.includes(k));
    const start = { done: sorted(run.done), skipped: sorted(run.skipped) };
    const steps = [];
    let k = survey.nextPending(run, plan, top, 0);
    while (k !== null) {
      const action = skip.includes(k) ? 'skip' : 'done';
      (action === 'skip' ? run.skipped : run.done).add(k);
      const next = survey.nextPending(run, plan, top, k);
      steps.push({ key: k, action, handled: survey.handled(run, k), next });
      k = next;
    }
    runs.push({ name, plan, top, surveyed, start, firstFrom0: steps[0]?.key ?? null, steps, end: { done: sorted(run.done), skipped: sorted(run.skipped) } });
  };
  const all = Array.from({ length: 88 }, (_, i) => i + 1);
  play('quick, earlier surveys do not count', 'quick', 88, all, [37]);
  play('quick on 85 keys', 'quick', 85, [], [1, 85]);
  play('full resumes after the surveyed keys', 'full', 88, [...all.slice(0, 10), 50], [12, 88]);
  play('full on 85 keys, all surveyed: starts over', 'full', 85, all, []);
  play('full, nothing surveyed', 'full', 88, [], [2, 3, 4]);

  // nextPending from any key, without changing the run.
  const probes = [];
  {
    const run = survey.newRun('full', 88, (k) => k <= 10 || k === 50);
    run.skipped.add(11);
    for (const from of [0, 5, 10, 11, 49, 50, 87, 88, 100]) probes.push({ plan: 'full', top: 88, done: sorted(run.done), skipped: [11], from, next: survey.nextPending(run, 'full', 88, from) });
    const q = survey.newRun('quick', 85, () => false);
    for (const x of [1, 13, 25, 37, 49, 61, 73]) q.done.add(x);
    for (const from of [0, 73, 85]) probes.push({ plan: 'quick', top: 85, done: sorted(q.done), skipped: [], from, next: survey.nextPending(q, 'quick', 85, from) });
    q.skipped.add(85);
    probes.push({ plan: 'quick', top: 85, done: sorted(q.done), skipped: [85], from: 0, next: survey.nextPending(q, 'quick', 85, 0) });
  }

  const clear = (key, score = 20, margin = 10) => ({ key, score, margin });
  const wrong = [
    [clear(37), 25, -5, NaN, []], [clear(50), 49, 100, 0, []], [null, 49, 100, 0, []], [clear(48), 49, -80, -75, []],
    [clear(48), 49, -80, NaN, []], [clear(49), 49, 0, 0, []], [clear(25), 37, 0, 0, [25]], [clear(51), 49, 0, 0, []],
    [clear(50), 49, 0, 0, []], [clear(50), 49, 71, 0, []], [clear(50), 49, 70, 0, []], [clear(47, 8, 10), 49, 0, 0, []],
    [clear(47, 8.01, 10), 49, 0, 0, []], [clear(47, 20, 5.99), 49, 0, 0, []], [clear(47, 20, 6), 49, 0, 0, []],
    [clear(47, 20, 5), 49, -100, 0, []], [clear(51, 20, 10), 49, 100, 0, [51]], [null, 49, 0, Infinity, []],
    [{ key: 0, score: -Infinity, margin: 0 }, 49, 100, 0, []],
  ].map(([d, k, raw, ref, done]) => ({ d, k, raw, ref, done, result: survey.wrongKey(d, k, raw, ref, new Set(done)) }));

  const keyStates = [];
  for (const plan of ['quick', 'full']) {
    for (const [pitch, bs, ms] of [[0, 0, 0], [7, 5, 0], [8, 4, 2999], [8, 4, 3000], [8, 4, 5999], [8, 4, 6000], [8, 5, 0], [20, 0, 10000], [7, 0, 10000]]) {
      const sk = { ...survey.newKeyState(), pitch: Array(pitch).fill(0), bs: Array(bs).fill(0), ms };
      keyStates.push({ plan, pitch, bs, ms, bGivenUp: survey.bGivenUp(sk, plan), keyDoneNeedB: survey.keyDone(sk, true, plan), keyDoneNoB: survey.keyDone(sk, false, plan) });
    }
  }

  write('survey.json', {
    about: 'Survey runs (newRun, nextPending, handled), wrongKey (d null = no detection; done = keys measured in the run), bGivenUp and keyDone (pitch and bs are counts of readings). Exact.',
    constants: { PITCH_READINGS: survey.PITCH_READINGS, B_READINGS: survey.B_READINGS, QUICK_KEYS: survey.QUICK_KEYS, OFFSET_LIMIT: survey.OFFSET_LIMIT },
    planKeys: [['quick', 88], ['quick', 85], ['quick', 60], ['full', 85], ['full', 88]].map(([plan, top]) => ({ plan, top, keys: survey.planKeys(plan, top) })),
    bTimeoutMs: { quick: survey.bTimeoutMs('quick'), full: survey.bTimeoutMs('full') },
    newKeyState: survey.newKeyState(),
    runs,
    nextPending: probes,
    wrongKey: wrong,
    keyStates,
  });
}

// ---------------------------------------------------------------------------
// Order

const ORDER_SETTINGS = [
  { top: 85, twoStringsTo: 32, oneStringTo: 8, dsu: false },
  { top: 88, twoStringsTo: 32, oneStringTo: 8, dsu: false },
  { top: 85, twoStringsTo: 32, oneStringTo: 8, dsu: true },
  { top: 88, twoStringsTo: 32, oneStringTo: 8, dsu: true },
];

{
  const builds = [
    ...ORDER_SETTINGS.map((s) => ({ settings: s, recheck: [] })),
    { settings: { top: 88, twoStringsTo: 20, oneStringTo: 0, dsu: true }, recheck: [] },
    { settings: { top: 88, twoStringsTo: 21, oneStringTo: 0, dsu: true }, recheck: [] },
    { settings: { top: 88 }, recheck: [12, 60] },
  ].map((b) => ({ ...b, order: order.buildOrder(b.settings, b.recheck) }));

  // Every position of the last build, stepped forwards with nextPos.
  const o = builds[builds.length - 1].order;
  const walk = [];
  for (let pos = { step: 0, i: 0 }; pos; pos = order.nextPos(o, pos)) {
    const t = order.taskAt(o, pos);
    walk.push({ step: pos.step, i: pos.i, progress: order.progress(o, pos), task: t ? `${t.k} ${t.what}` : null, prev: order.prevPos(o, pos) });
  }
  const clamp = [{ step: 99, i: 5 }, { step: -1, i: -1 }, null, { step: 3 }, { step: 6, i: 1000 }, { step: 4, i: 3.7 }, { step: NaN, i: NaN }]
    .map((pos) => ({ pos, clamped: order.clampPos(o, pos) }));

  const confirm = [
    { since: 5, strikes: [[5, true], [6, true], [6, false], [7, true], [8, true]] },
    { since: 0, strikes: [[1, true], [2, true], [3, true], [3, false], [4, true], [5, true]] },
    { since: 0, strikes: [[1, false], [1, true], [2, false], [3, true], [3, true], [4, true], [4, false], [4, true]] },
    { since: 10, strikes: [[9, true], [10, true], [11, false], [12, false], [13, true], [13, true], [14, false], [15, true], [16, true]] },
    { since: 2, strikes: [[3, true], [5, true], [5, true], [6, false], [8, true], [9, true]] },
  ].map(({ since, strikes }) => {
    const c = order.newConfirm(since);
    return { since, steps: strikes.map(([attack, ok]) => ({ attack, ok, done: order.confirmReading(c, attack, ok), state: { ...c } })) };
  });

  const stringsOf = (two, one) => (k) => (k <= one ? 1 : k <= two ? 2 : 3);
  const advice = [];
  for (const what of ['unison', 'pull', 'pair', 'third', 'one', 'middle', 'raise', 'recheck']) {
    for (const k of [5, 20, 50]) {
      for (const [clean, status] of [[true, 'warn'], [true, 'bad'], [true, 'good'], [true, 'none'], [false, 'warn']]) {
        advice.push({ task: { k, what }, twoStringsTo: 32, oneStringTo: 8, clean, status, advice: order.unisonAdvice({ k, what }, stringsOf(32, 8), { clean, status }) });
      }
    }
  }
  advice.push({ task: null, twoStringsTo: 32, oneStringTo: 8, clean: true, status: 'warn', advice: order.unisonAdvice(null, stringsOf(32, 8), { clean: true, status: 'warn' }) });

  write('order.json', {
    about: 'buildOrder(settings, recheck) as built; positions of the last build (walk: nextPos from {0,0}, with progress, taskAt as "key what" and prevPos), clampPos, confirmReading sequences (state after each strike), unisonAdvice. Exact, progress within 1e-12.',
    strip: order.STRIP,
    builds,
    walk,
    clampPos: clamp,
    confirmReading: confirm,
    unisonAdvice: advice,
  });
}

{
  // checkRows for every task with a key, with and without the keys tuned
  // before it (tunedBefore). Targets: the defaults, and the unit tests'
  // 12-TET without inharmonicity.
  const targets = {
    defaults: computeTargets(DEFAULT_SETTINGS),
    plain: (() => {
      const t = computeTargets({ ...DEFAULT_SETTINGS, stretch: 'none' });
      t.B.fill(0);
      return t;
    })(),
  };
  const rowsOf = (rows) => rows.map((r) => ({ ...r }));
  const sets = [];
  for (const [settings, tname] of [[ORDER_SETTINGS[1], 'defaults'], [ORDER_SETTINGS[3], 'defaults'], [ORDER_SETTINGS[0], 'plain']]) {
    const o = order.buildOrder(settings);
    const T = targets[tname];
    const tasks = [];
    o.forEach((s, step) => {
      if (s.id === 'raise') return;
      s.tasks.forEach((task, i) => {
        const tuned = order.tunedBefore(o, { step, i });
        const rows = rowsOf(order.checkRows(T, task, settings.top));
        const rowsTuned = rowsOf(order.checkRows(T, task, settings.top, tuned));
        const same = JSON.stringify(rows) === JSON.stringify(rowsTuned);
        tasks.push({ step, i, tunedBefore: sorted(tuned), rows, ...(!same && { rowsTuned }) });
      });
    });
    sets.push({ settings, targets: tname, tasks });
  }
  // One built by hand: a neighbour never holds the key being tuned.
  const lone = { k: 39, from: 34, what: 'middle', checks: [[35, 39]] };
  write('order-checks.json', {
    about: 'checkRows(T, task, top[, tuned]) and tunedBefore (sorted keys) at every task of buildOrder(settings) but the pitch raise; rowsTuned (with tuned = tunedBefore) only where it differs from rows. targets "defaults" = computeTargets(DEFAULT_SETTINGS); "plain" = computeTargets({...DEFAULT_SETTINGS, stretch: "none"}) with B set to 0. Rows exact, beat within 1e-9 absolute (some are ~1e-13 where 0 is meant).',
    sets,
    extra: [{ task: lone, top: 88, targets: 'plain', tuned: [34, 35, 38, 43], rows: rowsOf(order.checkRows(targets.plain, lone, 88, new Set([34, 35, 38, 43]))) }],
  });
}

// ---------------------------------------------------------------------------
// Format, in both languages

{
  const values = [
    1.23, -0.44, 0.04, -0.04, 0.05, -0.05, 0.25, -0.25, 0.15, 0.35, 0.45, 0.3, -0.3, 0.6, -12.4, 0.5, -0.5, 1.5, 2.5, -2.5,
    1.005, 1.045, 0.125, -0.125, 99.95, 999.995, 0, -0, 7, 1234.5678, 0.0001, -0.0049, -0.005, NaN, Infinity, -Infinity,
  ];
  const freqs = [440, 27.5, 4186.009044809578, 261.6255653005986, 0.005, 1.005, 0.125, 0.135, 12345.675, 0];
  const bs = [1.234e-4, 1.235e-4, 1.245e-4, 3.5e-4, 5.62e-4, 9.995e-4, 9.994e-4, 0.0125, 1, 0, 3e-7, 0.016, 2.5e-10, 12345];
  const shorts = [0.5, 1, 440, 441.5, -1.5, 0.1 + 0.2, 0.000001, 1e-7, 25, 0];
  const strings = [
    '441,5', '441.5', ' 440 ', '440,', ',5', '.5', '-0,5', '-.5', '-3', '-0', '0', '00012', '12.', '\t3\n', ' 1,25 ',
    '', ' ', 'abc', '441,5,1', '4e2', '441 Hz', '1.2.3', '+1', '--1', '- 1', '1 000', '0x10', 'Infinity', 'NaN', '.', ',', '-',
    '١٢', '１２', '1٫5', ' 12', '12 ',
  ];
  const langs = {};
  for (const l of ['en', 'sv']) {
    i18n.setLang(l);
    langs[l] = {
      decimal: i18n.decimal(),
      fmtC: values.flatMap((c) => [0, 1, 2].map((d) => ({ c, d, s: format.fmtC(c, d) }))),
      num: values.filter(Number.isFinite).flatMap((x) => [0, 1, 2].map((d) => ({ x, d, s: format.num(x, d) }))),
      fmtHz: freqs.flatMap((f) => [1, 2].map((d) => ({ f, d, s: format.fmtHz(f, d) }))),
      fmtB: bs.map((b) => ({ b, s: format.fmtB(b) })),
      short: shorts.map((x) => ({ x, s: format.short(x) })),
      parseNum: strings.map((s) => ({ s, x: format.parseNum(s) })),
    };
  }
  i18n.setLang('en');
  write('format.json', {
    about: 'format.js with the decimal separator of each language (en ".", sv ","). The minus sign is U+2212, NaN is "–" (U+2013). JS toFixed rounds an exact tie up, away from zero. parseNum takes ASCII digits only. Exact.',
    langs,
  });
}

// ---------------------------------------------------------------------------
// steady, median and the BeatMeter's decision logic (no sound)

{
  // Seeded, so the sequences are the same on every run.
  let s = 7;
  const rnd = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;
  const f4 = [2.9, 3.5, 2.7, 1.3, 4.1, 3.5, 0.6, 2.2, 2.6];
  const seqs = [
    f4, [2.6, 34.7, 2.5, 4.1, 2.9, 3, 0.2, 2.4, 2.1], [0, 0.4, 0.8, 1.2, 1.6, 2, 2.4, 2.8, 3.2], [3, 3, 3, 3, 3, 3, 3, 3],
    [40, -30, ...f4], [], [1], [0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0, 2], [0, 0, 0, 0, 0, 0, 0, 1.99, 1.99],
    [0, 0, 1.99, 1.99, 1.99, 1.99, 1.99, 0, 0], [0, 0, 2, 2, 2, 2, 2, 0, 0], [0, 0, 0, 0, 1.5, 1.5, 1.5, 1.5, 1.5],
    [0, 0, 0, 0, 1.49, 1.49, 1.49, 1.49, 1.49], [-5, -5.5, -4.8, -5.1, -5.2, -4.9, -5, -5.3, -4.7, -5.05],
  ];
  for (let n = 0; n < 40; n++) {
    const len = 6 + Math.floor(rnd() * 10);
    const spread = [0.5, 1, 2, 3, 6][n % 5];
    const drift = [0, 0.1, 0.25, -0.2][n % 4];
    const base = rnd() * 20 - 10;
    seqs.push(Array.from({ length: len }, (_, i) => Math.round((base + drift * i + (rnd() - 0.5) * spread) * 10) / 10));
  }
  const medians = [[], [3], [3, 1], [5, 1, 3], [4, 1, 3, 2], [2.5, -1, 7, 7, 0.1, 3], [-0, 0], [1e-9, -1e-9, 0]];

  // beats() with pulse() replaced: null before enough of the note, then { rate, db }.
  const P = (rate, db) => ({ rate, db });
  const pulseSeqs = [
    [P(3, 3), P(3, 3), P(3, 3), P(0.7, 3), P(0.7, 3), P(0.7, 3)],
    [null, null, P(3, 1.5), P(2, 1.5), P(2, 1.49), P(1.99, 2), P(3, 2), P(3, 2), P(3, 2), P(3, 2)],
    [P(3, 3), P(0.5, 0), P(3, 3), P(3, 3), P(3, 3), P(0.5, 0), P(3, 3), P(0.5, 0), P(0.5, 0), P(0.5, 0), P(3, 3)],
    [P(0, 0), P(0, 0), null, P(0, 0)],
  ].map((pulses) => {
    const bm = new dsp.BeatMeter();
    const steps = pulses.map((p) => {
      bm.pulse = () => p;
      const verdict = bm.beats();
      return { pulse: p, verdict, hits: bm.hits, misses: bm.misses, on: bm.on };
    });
    return { steps };
  });

  write('steady.json', {
    about: 'steady(readings), median(values) and BeatMeter.beats() with pulse() replaced by the given values (null = before enough of the note). Exact.',
    STEADY_N: dsp.STEADY_N,
    steady: seqs.map((cs) => ({ cs, steady: dsp.steady(cs) })),
    median: medians.map((a) => ({ a, median: dsp.median(a) })),
    beats: pulseSeqs,
  });
}

// ---------------------------------------------------------------------------
// DSP: synthetic sound as the unit tests make it, stored as Float32.

{
  const N = 32768;
  // Seeded noise, as in unit.test.mjs.
  let seed = 1;
  const noise = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648 - 0.5) * 0.01;

  // Synthetic tone with inharmonicity B; the fundamental damped in the bass.
  function toneFor(t, k, detune, B, sr) {
    const f0 = (t.freq[k] * 2 ** (detune / 1200)) / Math.sqrt(1 + B);
    const buf = new Float32Array(N);
    for (let p = 1; p <= 16; p++) {
      const f = p * f0 * Math.sqrt(1 + B * p * p);
      if (f > sr / 2.2) break;
      const a = (k < 20 && p === 1 ? 0.05 : 1) / p ** 0.8;
      for (let i = 0; i < N; i++) buf[i] += a * Math.sin((2 * Math.PI * f * i) / sr + p);
    }
    for (let i = 0; i < N; i++) buf[i] += noise();
    return buf;
  }

  const targetSettings = { defaults: DEFAULT_SETTINGS, small: { ...DEFAULT_SETTINGS, sizeCm: 100 } };
  const targets = Object.fromEntries(Object.entries(targetSettings).map(([n, s]) => [n, computeTargets(s)]));

  rmSync(join(OUT, 'dsp'), { recursive: true, force: true });
  const sounds = [];
  const result = (x) => (x ? { ...x } : null);

  const analyse = (file, buf, sr, info, calls) => {
    writeF32(`dsp/${file}`, buf);
    const A = new dsp.Analyzer(sr);
    A.load(buf);
    const out = { file, sampleRate: sr, length: buf.length, ...info, rmsDb: dsp.rmsDb(buf) };
    out.detectKey = calls.detectKey.map((c) => {
      const T = targets[c.targets];
      const heard = c.heard ? Float64Array.from({ length: 89 }, (_, k) => (k in c.heard ? c.heard[k] : NaN)) : null;
      return { ...c, result: A.detectKey(T, c.prevKey ?? 0, c.top ?? 88, heard) };
    });
    out.measure = (calls.measure || []).map((c) => ({ ...c, result: result(A.measure(c.target, c.cents, c.minProm)) }));
    out.inharmonicity = (calls.inharmonicity || []).map((c) => ({ ...c, result: result(A.inharmonicity(c.f1, c.Bguess)) }));
    out.zoom = (calls.zoom || []).map((c) => ({ ...c, db: A.zoom(c.fc, c.cents, c.bins) }));
    sounds.push(out);
    return A;
  };

  // A sample of keys over the range, at both sample rates.
  const plan = [
    // [sr, targets, key, detune, B factor]
    [48000, 'defaults', 1, 0, 1], [48000, 'defaults', 13, -7.5, 1.3], [48000, 'defaults', 25, 1.2, 1], [48000, 'defaults', 40, -20, 0.8],
    [48000, 'defaults', 49, 3, 1], [48000, 'defaults', 68, -2, 1.5], [48000, 'defaults', 88, 0, 1],
    [44100, 'small', 2, -20, 1], [44100, 'small', 14, 0, 1], [44100, 'small', 30, 4, 1.2], [44100, 'small', 45, 0, 1],
    [44100, 'small', 56, -1, 0.9], [44100, 'small', 76, -2, 1], [44100, 'small', 85, -20, 1],
  ];
  let a4buf = null;
  for (const [sr, tname, k, detune, bf] of plan) {
    const T = targets[tname];
    const B = T.B[k] * bf;
    const buf = toneFor(T, k, detune, B, sr);
    if (sr === 48000 && k === 49) a4buf = buf;
    const n = defaultPartial(k);
    const tgt = (m) => partialFreq(T.freq[k], T.B[k], m);
    const measure = [{ partial: n, target: tgt(n), cents: 150, minProm: 8 }, { partial: n, target: tgt(n), cents: 60, minProm: 10 }];
    if (n !== 1) measure.push({ partial: 1, target: tgt(1), cents: 60, minProm: 10 });
    measure.push({ partial: n + 1, target: tgt(n + 1), cents: 30, minProm: 12 });
    analyse(`tone-${sr}-k${k}.f32`, buf, sr, { key: k, detune, B, targets: tname }, {
      detectKey: [{ targets: tname }, { targets: tname, prevKey: Math.max(1, k - 1) }, { targets: tname === 'defaults' ? 'small' : 'defaults' }, { targets: tname, top: 85 }],
      measure,
      inharmonicity: [{ f1: T.freq[k], Bguess: T.B[k] }],
      zoom: k === 49 || k === 25 ? [{ fc: tgt(n), cents: 30, bins: 64 }] : [],
    });
  }

  // A4 60 cents flat: A♭4 by default, A4 where it was last heard.
  {
    const T = targets.defaults;
    const buf = toneFor(T, 49, -60, T.B[49], 48000);
    analyse('tone-48000-k49-flat60.f32', buf, 48000, { key: 49, detune: -60, B: T.B[49], targets: 'defaults' }, {
      detectKey: [{ targets: 'defaults' }, { targets: 'defaults', heard: { 49: -58 } }, { targets: 'defaults', heard: { 48: 9.99, 49: -58 } }],
      measure: [{ partial: 1, target: T.freq[49], cents: 150, minProm: 8 }],
    });
  }

  // B♭0 recorded with a laptop microphone: peaks (Hz, amplitude), where
  // detection once picked D3 (unit.test.mjs).
  {
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
    analyse('bflat0-peaks-44100.f32', buf, sr, { key: 2, peaks }, {
      detectKey: [{ targets: 'defaults' }, { targets: 'small' }],
      measure: [{ partial: 6, target: partialFreq(targets.defaults.freq[2], targets.defaults.B[2], 6), cents: 60, minProm: 10 }],
    });
  }

  // TODO: a few seconds cut from one or two real recordings
  // (pianotunah-*.wav, not in git), with the readings the web gives for them.

  // BeatMeter on the strings of A4: one at 440 Hz and others [Hz apart,
  // strength], in frames of N samples 90 ms apart, as unit.test.mjs does.
  const SR = 48000;
  const hop = Math.round(0.09 * SR);
  const meters = [];
  for (const [name, others, secs] of [
    ['one string', [], 2.5],
    ['a weak beat 3 a second', [[3, 0.3]], 2.5],
    ['a slow pulse and a beat 3 a second', [[0.7, 0.3], [3, 0.7]], 2.5],
  ]) {
    const f = 440;
    const x = new Float32Array(Math.round((secs + 0.7) * SR));
    for (let i = 0; i < x.length; i++) {
      const t = i / SR;
      let y = Math.sin(2 * Math.PI * f * t);
      others.forEach(([d, a], j) => (y += a * Math.sin(2 * Math.PI * (f + d) * t + 1 + j)));
      x[i] = Math.exp(-t / 2.5) * y + noise();
    }
    const file = `beat-${meters.length + 1}.f32`;
    writeF32(`dsp/${file}`, x);
    const bm = new dsp.BeatMeter();
    const frames = [];
    for (let end = N; end <= x.length; end += hop) {
      const t = end / SR;
      bm.add(x.subarray(end - N, end), SR, f, t);
      const pulse = bm.pulse();
      const verdict = bm.beats();
      frames.push({ end, t, levels: bm.ts.length, span: bm.span, pulse: pulse && { ...pulse }, verdict, quiet: bm.quiet });
    }
    meters.push({ name, file, sampleRate: SR, length: x.length, f, others, frameSize: N, hop, frames, ts: bm.ts, ys: bm.ys });
  }

  // A gap the buffer cannot fill starts the meter again.
  const g = new dsp.BeatMeter();
  g.add(a4buf, 48000, 440, 10);
  const ts10 = [...g.ts];
  g.add(a4buf, 48000, 440, 12);
  const gap = { file: 'tone-48000-k49.f32', sampleRate: 48000, f: 440, adds: [{ t: 10, ts: ts10 }, { t: 12, ts: [...g.ts], ys: [...g.ys] }] };

  write('dsp.json', {
    about: 'Analyzer on the Float32 little-endian sound in dsp/ (the whole file is the buffer). measure/inharmonicity results within 0.01 cent in freq (B and f0 within 1e-6 relative); detectKey key and shift exact, score and margin within 1e-6 dB; zoom and rmsDb within 1e-6 dB. targets: computeTargets of targetSettings. heard: cents per key, NaN elsewhere. BeatMeter: frames of frameSize samples ending at end, every hop samples, t = end / sampleRate; pulse() before beats(); verdicts exact, rate exact (a 0.05 grid), db within 1e-6.',
    targetSettings,
    targets: Object.fromEntries(Object.entries(targets).map(([n, t]) => [n, { freq: t.freq, B: t.B }])),
    sounds,
    beatMeter: meters,
    beatMeterGap: gap,
  });
}

console.log(`Wrote ${written.length} files to ${OUT.slice(ROOT.length + 1)}`);
