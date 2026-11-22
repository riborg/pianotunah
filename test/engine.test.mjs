// Unit tests for engine.js: the tuner without the page. Scenarios feed it
// frames of a synthetic piano, struck at given times, and check the state and
// events that come out. Deterministic: seeded noise and a fixed clock.
// Run with: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Engine, FRAME_MS, SPEC_COLS, clampRef, clampSize, clampStrings, clampPartial, stepRange } from '../web/js/engine.js';
import { DEFAULT_SETTINGS, computeTargets, partialFreq, centsBetween, defaultPartial } from '../web/js/theory.js';

const SR = 48000;
const N = 32768; // what the microphone's ring buffer gives each frame
const DT = FRAME_MS / 1000;
const WALL = Date.UTC(2026, 10, 1); // wall clock at time 0
const T = computeTargets(DEFAULT_SETTINGS);

const piano = (settings = {}, extra = {}) => ({
  id: 'test', name: 'Test', notes: '', createdAt: '2026-10-01T00:00:00.000Z', passStartedAt: '2026-10-01T00:00:00.000Z',
  settings: { ...DEFAULT_SETTINGS, ...settings }, inharmonicity: {}, partials: {}, keys: {}, history: [], order: { step: 0, i: 0 }, rev: 1, ...extra,
});

// The frequency of key k's measured partial n, c cents off the target T.
const hzAt = (k, c, n = 1, t = T) => partialFreq(t.freq[k], t.B[k], n) * 2 ** (c / 1200);

// An engine on a piano, listening at 48 kHz, with every event recorded.
function setup(p = piano()) {
  const events = [];
  const e = new Engine({ emit: (type, data) => events.push({ type, ...data }) });
  e.open(p);
  e.startAudio(SR);
  events.length = 0;
  return { e, events };
}

// A room with a piano in it. strike(k, c, at, unison) sounds key k c cents
// off its target from time `at` (s), with a second string `unison` cents
// above it if given, and damps the previous note 0.3 s before. Faint seeded
// noise, so the noise floor has something to follow.
function room() {
  const voices = [];
  let seed = 7;
  const noise = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648 - 0.5) * 0.0004;
  return {
    strike(k, c, at, unison = 0) {
      for (const v of voices) v.damp ??= at - 0.3;
      const f1 = T.freq[k] * 2 ** (c / 1200);
      const ps = [];
      for (let p = 1; p <= 10; p++) {
        const f = partialFreq(f1, T.B[k], p);
        if (f > SR / 2.2) break;
        ps.push([f, 1 / p, p]);
        if (unison) ps.push([f * 2 ** (unison / 1200), 1 / p, 2 * p]);
      }
      voices.push({ ps, at, damp: null });
    },
    // The latest N samples, ending at time t.
    buf(t) {
      const b = new Float32Array(N);
      for (let i = 0; i < N; i++) {
        const ti = t - (N - 1 - i) / SR;
        let x = noise();
        for (const v of voices) {
          const age = ti - v.at;
          if (age < 0) continue;
          let env = 0.25 * Math.exp(-age * 0.6) * Math.min(1, age * 200);
          if (v.damp !== null && ti > v.damp) env *= Math.exp(-(ti - v.damp) / 0.03);
          if (env < 1e-6) continue;
          for (const [f, a, ph] of v.ps) x += a * env * Math.sin(2 * Math.PI * f * age + ph);
        }
        b[i] = x;
      }
      return b;
    },
  };
}

// Frames every FRAME_MS from t0 to t1 (s); ref: a reference tone is audible.
// Returns the frames' results with their times.
function listen(e, r, t0, t1, { ref = false, until } = {}) {
  const out = [];
  for (let t = t0; t < t1 - 1e-9; t += DT) {
    const res = e.frame(r.buf(t), { time: t, now: t * 1000, wall: WALL + t * 1000, ref });
    out.push({ t, ...res });
    if (until?.(res)) break;
  }
  return out;
}

const types = (frames) => frames.flatMap((f) => f.events.map((x) => x.type));
const near = (a, b, tol, what) => assert.ok(Math.abs(a - b) <= tol, `${what}: ${a} not within ${tol} of ${b}`);

// ---------------------------------------------------------------------------
// Clamping rules

test('clamping: reference, size, strings, partial', () => {
  assert.equal(clampRef(379), 380);
  assert.equal(clampRef(500), 480);
  assert.equal(clampRef(440.06), 440.1);
  assert.equal(clampRef(441.94), 441.9);
  assert.equal(clampSize('upright', 'x'), 120); // not a number: the kind's default
  assert.equal(clampSize('upright', '200'), 150);
  assert.equal(clampSize('grand', 139.6), 140);
  assert.equal(clampSize('grand', '212.4'), 212);
  assert.deepEqual(clampStrings(88, '100', '120'), { two: 88, one: 88 });
  assert.deepEqual(clampStrings(88, '20', '30'), { two: 20, one: 20 }); // one string never above two
  assert.deepEqual(clampStrings(85, '', '-3'), { two: 0, one: 0 });
  assert.deepEqual(clampStrings(88, '24.6', '9.4'), { two: 25, one: 9 });
  assert.equal(clampPartial(0), 1);
  assert.equal(clampPartial(9), 8);
  assert.equal(clampPartial(3), 3);
});

test('step ranges name the keys of the order steps', () => {
  assert.deepEqual(stepRange('strip', 88), [33, 49]);
  assert.deepEqual(stepRange('pull', 88), [49, 33]);
  assert.deepEqual(stepRange('temperament', 88), [33, 44]);
  assert.deepEqual(stepRange('upper', 88), [45, 48]);
  assert.deepEqual(stepRange('treble', 85), [50, 85]);
  assert.deepEqual(stepRange('bass', 88), [32, 1]);
  assert.equal(stepRange('pitch', 88), null);
});

// ---------------------------------------------------------------------------
// Deviations and status

test('deviations: now, before, overpull goal and status', () => {
  const { e } = setup(piano({ overpull: 25, tolerance: 1 }, { keys: { 49: { hz: hzAt(49, 4.5), n: 1, bhz: hzAt(49, -20), bn: 1 } } }));
  near(e.curDev(49), 4.5, 1e-9, 'now');
  near(e.beforeDev(49), -20, 1e-9, 'before');
  near(e.goal(49), 5, 1e-9, 'goal: 25 % of 20 cents flat');
  near(e.statusDev(49), -0.5, 1e-9, 'status');
  assert.equal(e.statusClass(e.statusDev(49)), 'good');
  assert.ok(Number.isNaN(e.curDev(50)));
  assert.equal(e.goal(50), 0);
  assert.equal(e.statusClass(NaN), 'none');
  assert.equal(e.statusClass(1.5), 'warn');
  assert.equal(e.statusClass(-5), 'warn');
  assert.equal(e.statusClass(5.1), 'bad');
  e.settings.tolerance = 3;
  assert.equal(e.statusClass(5.9), 'warn'); // twice the tolerance
  assert.equal(e.statusClass(6.1), 'bad');
  // A measurement of another partial counts against that partial's target.
  e.tuning.keys[25] = { hz: hzAt(25, -3, 4), n: 4 };
  near(e.curDev(25), -3, 1e-9, 'partial 4');
  const h = e.heardDevs();
  assert.equal(h.length, 89);
  near(h[49], 4.5, 1e-9, 'heard');
});

test('reference tone frequencies include overpull and the partial', () => {
  const { e } = setup(piano({ overpull: 50 }, { keys: { 25: { hz: hzAt(25, 0, 4), n: 4, bhz: hzAt(25, -10, 4), bn: 4 } } }));
  near(centsBetween(e.goalF1(25), T.freq[25]), 5, 1e-9, 'goalF1');
  e.selectKey(25);
  const n = defaultPartial(25);
  near(e.sineFreq(), partialFreq(e.goalF1(25), T.B[25], n), 1e-9, 'sine at the measured partial');
});

test('the middle before tuning: ref advice, pitch advice, overpull, fitting the reference', () => {
  const keys = (c, ks) => Object.fromEntries(ks.map((k) => [k, { hz: hzAt(k, c), n: 1, bhz: hzAt(k, c), bn: 1 }]));
  let { e } = setup(piano({}, { keys: keys(-12, [40, 44]) }));
  assert.deepEqual(e.refAdvice(), { kind: 'none' });
  assert.equal(e.pitchAdvice(), null);
  assert.equal(e.suggestedOverpull(), 0);
  assert.ok(Number.isNaN(e.fitRefHz()), 'no input');

  ({ e } = setup(piano({}, { keys: keys(-12, [20, 40, 44, 49, 70]) }))); // 20 and 70 are outside the middle
  assert.equal(e.midBefore().length, 3);
  const a = e.refAdvice();
  assert.equal(a.kind, 'off');
  near(a.m, -12, 1e-9, 'm');
  assert.equal(a.p, 25);
  near(a.o, 3, 1e-9, 'overpulled');
  near(a.hz, 440 * 2 ** (-12 / 1200), 1e-9, 'hz');
  near(a.ohz, 440 * 2 ** (3 / 1200), 1e-9, 'ohz');
  assert.equal(a.big, false);
  assert.deepEqual(e.pitchAdvice(), { m: a.m, off: true });
  assert.equal(e.suggestedOverpull(), 25);
  near(e.fitRefHz(), 440 * 2 ** (-12 / 1200), 1e-9, 'fit');

  ({ e } = setup(piano({ refA4: 442 }, { keys: keys(-30, [40, 41, 42]) })));
  assert.equal(e.refAdvice().big, true);
  ({ e } = setup(piano({}, { keys: keys(6, [40, 41, 42]) })));
  assert.deepEqual({ ...e.refAdvice(), m: 0, hz: 0 }, { kind: 'off', m: 0, hz: 0, p: 0 }); // sharp: no overpull
  assert.equal(e.pitchAdvice().off, false);
  ({ e } = setup(piano({}, { keys: keys(-2, [40, 41, 42]) })));
  assert.equal(e.refAdvice().kind, 'near');

  // Without a middle, the key sounding now.
  ({ e } = setup(piano({ refA4: 441 })));
  Object.assign(e, { signal: true, display: 6 });
  near(e.fitRefHz(), 441 * 2 ** (6 / 1200), 1e-9, 'from the reading');
});

test('pass stats, keys to recheck and the new-pass summary', () => {
  const keys = {
    40: { hz: hzAt(40, 0.5), n: 1, bhz: hzAt(40, -10), bn: 1 },
    41: { hz: hzAt(41, 3), n: 1, bhz: hzAt(41, -6), bn: 1 },
    42: { hz: hzAt(42, -8), n: 1, bhz: hzAt(42, -8), bn: 1 },
  };
  const { e, events } = setup(piano({}, { keys, order: { step: 5, i: 2 }, history: Array.from({ length: 30 }, (_, i) => ({ startedAt: String(i) })) }));
  assert.deepEqual(e.passStats(), { measured: 3, ok: 1 });
  assert.deepEqual(e.recheckKeys(), [41, 42]);
  e.newPass(WALL);
  const h = e.tuning.history;
  assert.equal(h.length, 30, 'the history keeps 30 passes');
  assert.equal(h[0].startedAt, '1');
  const last = h[29];
  assert.equal(last.startedAt, '2026-10-01T00:00:00.000Z');
  assert.equal(last.endedAt, new Date(WALL).toISOString());
  assert.equal(last.refA4, 440);
  assert.equal(last.measured, 3);
  near(last.meanAbsBefore, 8, 1e-9, 'before');
  near(last.meanAbsAfter, 11.5 / 3, 1e-9, 'after');
  assert.deepEqual(e.tuning.keys, {});
  assert.equal(e.tuning.passStartedAt, new Date(WALL).toISOString());
  assert.deepEqual(e.tuning.order, { step: 0, i: 0 });
  assert.deepEqual(e.orderPos, { step: 0, i: 0 });
  assert.deepEqual(events.map((x) => x.type), ['targets']);
  // Nothing measured: no summary.
  e.newPass(WALL + 1000);
  assert.equal(e.tuning.history.length, 30);
  assert.equal(e.tuning.history[29].endedAt, new Date(WALL).toISOString());
});

test('settings through the engine: strings and partial', () => {
  const { e } = setup(piano({ keyCount: 85 }));
  assert.equal(e.top(), 85);
  assert.deepEqual(e.setStrings('100', '30'), { two: 85, one: 30 });
  assert.equal(e.settings.twoStringsTo, 85);
  assert.equal(e.strings(30), 1);
  assert.equal(e.strings(31), 2);
  assert.ok(e.order.length > 0);
  e.selectKey(49);
  e.setPartial(1);
  assert.equal(e.tuning.partials[49], 2);
  e.setPartial(-1);
  assert.equal(49 in e.tuning.partials, false, 'the default partial is not stored');
  for (let i = 0; i < 10; i++) e.setPartial(1);
  assert.equal(e.partialOf(49), 8);
});

// ---------------------------------------------------------------------------
// Key and mode

test('selecting keys: clamped, manual leaves auto, events', () => {
  const { e, events } = setup(piano({ keyCount: 85 }));
  assert.equal(e.mode, 'auto');
  e.selectKey(100);
  assert.equal(e.key, 85);
  assert.equal(e.mode, 'lock');
  assert.deepEqual(events.map((x) => x.type), ['log', 'mode', 'log', 'key']);
  assert.deepEqual(events[3], { type: 'key', k: 85, manual: true });
  events.length = 0;
  e.selectKey(85);
  assert.deepEqual(events, [], 'the same key again: nothing');
  e.setMode('auto');
  e.selectKey(40, false);
  assert.equal(e.mode, 'auto', 'not manual: stays in auto');
});

// ---------------------------------------------------------------------------
// Frames

test('frame analysis: noise floor, gate, attacks and the spectrogram', () => {
  const { e } = setup();
  const r = room();
  const quiet = listen(e, r, 0, 1);
  assert.ok(quiet.every((f) => f.idle === 'quiet'));
  assert.ok(e.noise < -70 && e.noise > -80, `noise floor ${e.noise}`);
  near(e.gate(), Math.max(e.noise + 10, -72), 1e-12, 'gate');
  assert.equal(e.attacks, 0);
  assert.equal(e.spec.length, quiet.length);
  assert.ok(e.spec.every((c) => c === null));

  r.strike(49, 0, 1.05);
  const n = quiet.length + listen(e, r, 1, 2).length;
  assert.equal(e.attacks, 1, 'one attack, though it shows for a few frames');
  assert.equal(e.signal, true);
  assert.ok(e.inAttack === false);
  r.strike(49, 0, 2.5);
  const m = listen(e, r, 2, 3).length;
  assert.equal(e.attacks, 2);
  assert.equal(e.stats.frames, n + m);
  listen(e, r, 3, 12);
  assert.equal(e.spec.length, SPEC_COLS);
  const col = e.spec.findLast((c) => c);
  assert.equal(col.col.length, 48);
  near(col.c, e.display, 1e-12, 'column at the reading');
});

test('lock: a steady note is saved, Before stays the first measurement', () => {
  const { e } = setup();
  e.selectKey(49);
  const r = room();
  r.strike(49, 5, 0.5);
  const frames = listen(e, r, 0.4, 3);
  const first = frames.findIndex((f) => f.events.some((x) => x.type === 'saved'));
  const heard = frames.findIndex((f) => !f.idle);
  assert.ok(first - heard >= 8, `saved after ${first - heard + 1} readings, not before 9 are steady`);
  assert.ok(frames.slice(first).every((f) => f.events.some((x) => x.type === 'saved' && x.k === 49)), 'saved every steady frame');
  near(e.display, 5, 0.1, 'display');
  near(centsBetween(e.measHz, hzAt(49, 0)), 5, 0.1, 'measured Hz');
  const rec = e.tuning.keys[49];
  near(e.curDev(49), 5, 0.1, 'now');
  assert.equal(rec.n, 1);
  assert.equal(rec.at, Math.round(WALL + frames.at(-1).t * 1000));
  const before = rec.bhz;
  near(e.beforeDev(49), 5, 0.1, 'before');
  assert.equal(e.strobe.length, 3);
  assert.deepEqual(e.strobe.map((s) => s.p), [1, 2, 4]);
  near(e.strobe[1].c, 5, 0.3, 'strobe band of partial 2');
  near(e.partialDevs[0], 5, 0.1, 'partial 1');
  near(e.beatHz, hzAt(49, 0) * (2 ** (e.display / 1200) - 1), 1e-9, 'beat rate against the target');

  r.strike(49, -2, 3.5);
  listen(e, r, 3, 6);
  near(e.curDev(49), -2, 0.1, 'now after tuning');
  assert.equal(e.tuning.keys[49].bhz, before, 'Before is kept');
});

test('lock: nothing is saved while a reference tone is heard', () => {
  const { e } = setup();
  e.selectKey(49);
  const r = room();
  r.strike(49, 3, 0.5);
  const frames = listen(e, r, 0.4, 3, { ref: true });
  assert.ok(!types(frames).includes('saved'));
  assert.equal(e.stable, false);
  assert.equal(e.signal, true, 'still shown');
  assert.equal(e.tuning.keys[49], undefined);
  // Once the tone stops, its readings are dropped before a steady reading counts.
  const after = listen(e, r, 3, 3.5);
  assert.equal(e.readings.length, after.length);
});

test('auto: follows the key struck and saves it', () => {
  const { e } = setup();
  assert.equal(e.key, 49);
  const r = room();
  r.strike(40, -3, 0.5);
  const frames = listen(e, r, 0.4, 3);
  const ev = frames.flatMap((f) => f.events);
  assert.deepEqual(ev.find((x) => x.type === 'key'), { type: 'key', k: 40, manual: false });
  assert.equal(e.key, 40);
  assert.equal(e.mode, 'auto');
  assert.ok(ev.some((x) => x.type === 'saved' && x.k === 40));
  near(e.curDev(40), -3, 0.1, 'saved reading');
  assert.equal(e.tuning.keys[49], undefined);
});

test('auto: the reference tone is not followed', () => {
  const { e } = setup();
  const r = room();
  r.strike(40, 0, 0.5);
  const frames = listen(e, r, 0.4, 2, { ref: true });
  assert.equal(e.key, 49);
  assert.ok(frames.every((f) => f.idle === 'hears C4' || f.idle === 'quiet'), frames.map((f) => f.idle).join(','));
});

test('a jump of more than 50 cents is saved only after a new attack', () => {
  const { e } = setup(piano({}, { keys: { 49: { hz: hzAt(49, 0), n: 1, bhz: hzAt(49, 0), bn: 1 } } }));
  e.selectKey(49);
  const r = room();
  r.strike(49, 60, 0.5);
  const frames = listen(e, r, 0.4, 3);
  const ev = frames.flatMap((f) => f.events);
  assert.ok(!ev.some((x) => x.type === 'saved'));
  const msgs = ev.filter((x) => x.type === 'message');
  assert.equal(msgs.length, 1, 'said once');
  assert.equal(msgs[0].id, 'jump');
  assert.equal(msgs[0].k, 49);
  near(msgs[0].c, 60, 0.2, 'jump');
  near(e.curDev(49), 0, 1e-9, 'unchanged');

  r.strike(49, 60, 3.5);
  const again = listen(e, r, 3, 6);
  assert.ok(types(again).includes('saved'));
  near(e.curDev(49), 60, 0.2, 'saved after the new attack');
});

// ---------------------------------------------------------------------------
// Beats

test('beats: a unison 10 cents out beats, a single string does not', () => {
  let { e } = setup();
  e.selectKey(49);
  let r = room();
  r.strike(49, 0, 0.5, 10);
  listen(e, r, 0.4, 4.5);
  assert.equal(e.beatKnown, true);
  assert.equal(e.beating, true);

  ({ e } = setup());
  e.selectKey(49);
  r = room();
  r.strike(49, 0, 0.5);
  listen(e, r, 0.4, 4.5);
  assert.equal(e.beatKnown, true);
  assert.equal(e.beating, false);
  // A new key starts the check over.
  e.selectKey(50);
  assert.equal(e.beatKnown, false);
  assert.equal(e.beatUnheard(), false);
});

// ---------------------------------------------------------------------------
// Measuring B

test('measure B: readings for 4 s, then stored with a message', () => {
  const { e } = setup();
  e.selectKey(37);
  const r = room();
  r.strike(37, 0, 0.5);
  listen(e, r, 0.4, 0.6);
  const run = e.startMeasureB(600);
  assert.deepEqual(run, { k: 37, until: 4600 });
  const frames = listen(e, r, 0.6, 6, { until: () => !e.measureB });
  const ev = frames.flatMap((f) => f.events);
  assert.equal(e.measureB, null);
  assert.ok(frames.at(-1).t > 4.6);
  assert.deepEqual(ev.filter((x) => x.type === 'measureB'), [{ type: 'measureB', on: false }]);
  const msg = ev.find((x) => x.type === 'message');
  assert.equal(msg.id, 'bMeasured');
  assert.equal(msg.k, 37);
  near(msg.B / T.B[37], 1, 0.05, 'B against the model the tone was made with');
  assert.equal(e.tuning.inharmonicity[37], Number(msg.B.toPrecision(4)));
  assert.ok(ev.some((x) => x.type === 'targets'));
  near(e.T.B[37], e.tuning.inharmonicity[37], 1e-12, 'the targets use it');
});

test('measure B: too few readings fail', () => {
  const { e, events } = setup();
  e.startMeasureB(0);
  e.finishMeasureB();
  assert.deepEqual(events.slice(-3).map((x) => x.id || x.type), ['measureB', 'measureB', 'bFailed']);
  assert.deepEqual(e.tuning.inharmonicity, {});
});

// ---------------------------------------------------------------------------
// Survey

// Strike the key the survey asks for (or `play(k)` instead) until it moves on.
function surveyKey(e, r, t, play = (k) => k) {
  const k = e.key;
  const struck = play(k);
  r.strike(struck, 0, t + 0.05);
  const frames = listen(e, r, t, t + 8, { until: () => e.key !== k || e.mode !== 'survey' });
  return { frames, t: frames.at(-1).t + DT };
}

test('survey of all A: asks for each A, skips, notices a wrong key, ends on A4', () => {
  const { e, events } = setup(piano({ keyCount: 85 }));
  const r = room();
  let t = 0;
  listen(e, r, t, (t += 0.5));
  e.setSurveyPlan('quick');
  e.setMode('survey');
  assert.deepEqual(e.planKeys(), [1, 13, 25, 37, 49, 61, 73, 85]);
  assert.equal(e.key, 1);
  assert.ok(e.survey.waitAttack);
  assert.deepEqual(events.filter((x) => x.type !== 'log').map((x) => x.type), ['key', 'mode']);
  // Nothing is taken before the first attack.
  const waiting = listen(e, r, t, (t += 0.5));
  assert.ok(waiting.every((f) => f.idle === 'waiting for attack'));

  const asked = [];
  const wrong = [];
  while (e.mode === 'survey') {
    const k = e.key;
    asked.push(k);
    if (k === 13) {
      e.skipSurveyKey();
      continue;
    }
    if (k === 37) {
      // C♯4 for A3: noticed, and nothing of it is kept.
      r.strike(41, 0, t + 0.05);
      const f = listen(e, r, t, (t += 1.5));
      wrong.push(e.survey.wrong);
      assert.equal(e.key, 37);
      assert.equal(e.survey.pitch.length, 0);
      assert.ok(f.some((x) => x.events.some((y) => y.type === 'survey')));
    }
    ({ t } = surveyKey(e, r, t));
    if (e.mode === 'survey') assert.notEqual(e.key, k, `moved on from ${k}`);
  }
  assert.deepEqual(asked, [1, 13, 25, 37, 49, 61, 73, 85]);
  assert.deepEqual(wrong, [41]);
  assert.equal(e.mode, 'lock');
  assert.equal(e.key, 49);
  for (const k of [1, 25, 37, 49, 61, 73, 85]) {
    assert.equal(e.tuning.keys[k]?.mapped, true, `${k} surveyed`);
    near(e.curDev(k), 0, 0.5, `${k} on target`);
  }
  assert.equal(e.tuning.keys[13], undefined);
  const done = events.find((x) => x.type === 'message');
  assert.deepEqual({ ...done, b: 0 }, { type: 'message', id: 'surveyDone', quick: true, b: 0, n: 8, skipped: [13], outliers: [...e.bBad] });
  assert.ok(done.b >= 5, `B measured on ${done.b} keys`);
  assert.equal(done.b, Object.keys(e.tuning.inharmonicity).length);
  assert.deepEqual(events.filter((x) => x.type === 'flash').map((x) => x.k), [1, 25, 37, 49, 61, 73, 85]);
});

test('a full survey continues where the last one stopped', () => {
  const keys = Object.fromEntries([1, 2, 3].map((k) => [k, { hz: hzAt(k, 0, 1), n: 1, mapped: true }]));
  const { e } = setup(piano({}, { keys }));
  e.setSurveyPlan('full');
  e.setMode('survey');
  assert.equal(e.key, 4);
  assert.equal(e.needsB(4), true);
  e.tuning.inharmonicity[5] = T.B[5];
  assert.equal(e.needsB(5), false, 'a full survey keeps a measured B');
  e.setSurveyPlan('quick');
  assert.equal(e.key, 1, 'the run starts over with the new plan');
  assert.equal(e.needsB(5), true, 'the quick survey always remeasures B');
});

// ---------------------------------------------------------------------------
// Tuning order

test('order: on in Lock, two strikes in tune move on, sharp does not', () => {
  const { e, events } = setup();
  e.setOrderOn(true);
  assert.equal(e.mode, 'lock');
  assert.deepEqual(e.orderPos, { step: 0, i: 0 });
  assert.equal(e.orderTask(), null, 'the pitch check has no task');
  e.goOrder({ step: e.orderStepIndex('middle'), i: 0 });
  assert.equal(e.key, 49);
  assert.deepEqual(e.tuning.order, { step: 3, i: 0 });
  assert.ok(events.some((x) => x.type === 'dirty') && events.some((x) => x.type === 'order'));

  const r = room();
  let t = 0;
  for (let i = 0; i < 3; i++) {
    r.strike(49, 8, t + 0.05);
    listen(e, r, t, (t += 2.5));
  }
  assert.deepEqual(e.orderPos, { step: 3, i: 0 }, '8 cents sharp does not move on');
  assert.equal(e.orderAdvice, null);

  events.length = 0;
  r.strike(49, 0.2, t + 0.05);
  listen(e, r, t, (t += 2.5));
  assert.deepEqual(e.orderPos, { step: 3, i: 0 }, 'one strike is not enough');
  assert.ok(events.some((x) => x.type === 'orderState'));
  r.strike(49, -0.2, t + 0.05);
  listen(e, r, t, (t += 2.5));
  assert.deepEqual(e.orderPos, { step: 3, i: 1 });
  assert.equal(e.key, 37);
  assert.ok(events.some((x) => x.type === 'flash' && x.k === 49));
});

test('order: a clean unison off target gets advice', () => {
  const { e } = setup();
  e.setOrderOn(true);
  const treble = e.orderStepIndex('treble');
  e.goOrder({ step: treble, i: 1 });
  assert.deepEqual(e.orderTask(), { k: 50, what: 'unison' });
  const r = room();
  r.strike(50, 3, 0.05);
  listen(e, r, 0, 4);
  assert.equal(e.beating, false);
  assert.equal(e.orderAdvice, 'shift3');
  assert.deepEqual(e.orderPos, { step: treble, i: 1 });
});

test('order: next, previous, skip, the last step and DSU', () => {
  const keys = { 40: { hz: hzAt(40, 4), n: 1, bhz: hzAt(40, 4), bn: 1 }, 41: { hz: hzAt(41, 0), n: 1, bhz: hzAt(41, 0), bn: 1 } };
  const { e, events } = setup(piano({}, { keys }));
  e.setOrderOn(true);
  e.orderNext();
  assert.deepEqual(e.orderPos, { step: 1, i: 0 });
  assert.equal(e.key, 37, 'the pitch raise starts at A3');
  e.orderPrev();
  assert.deepEqual(e.orderPos, { step: 0, i: 0 });
  e.orderPrev();
  assert.deepEqual(e.orderPos, { step: 0, i: 0 });
  e.orderSkip();
  e.orderSkip();
  assert.deepEqual(e.orderPos, { step: 2, i: 0 });

  // Off the order's key and back.
  e.goOrder({ step: e.orderStepIndex('treble'), i: 0 });
  e.setMode('auto');
  e.selectKey(20, false);
  e.orderBack();
  assert.equal(e.mode, 'lock');
  assert.equal(e.key, 50);

  // DSU: the treble gets other tasks, the order stays on its key.
  e.goOrder({ step: e.orderStepIndex('treble'), i: 4 });
  const k = e.orderTask().k;
  e.setUnisons('dsu');
  assert.equal(e.orderTask().k, k);
  assert.equal(e.orderTask().what, 'pair');

  // The last step lists the keys outside tolerance as it begins.
  const finish = e.orderStepIndex('finish');
  e.goOrder({ step: finish, i: 0 });
  assert.deepEqual(e.orderRecheck, [40]);
  assert.deepEqual(e.orderTask(), { k: 40, what: 'recheck' });
  events.length = 0;
  e.orderNext();
  assert.deepEqual(events.filter((x) => x.type === 'message'), [{ type: 'message', id: 'orderDone' }]);
  e.goOrder({ step: 0, i: 0 });
  assert.equal(e.orderRecheck, null);

  // Off: the order no longer selects keys.
  e.setOrderOn(false);
  assert.equal(e.orderActive(), false);
  e.goOrder({ step: e.orderStepIndex('middle'), i: 1 });
  assert.equal(e.key, 40);
});

test('order: opened on the last step lists the keys to recheck', () => {
  const keys = { 45: { hz: hzAt(45, -7), n: 1 } };
  const finish = 9;
  const { e } = setup(piano({}, { keys, order: { step: finish, i: 0 } }));
  e.rebuildOrder();
  assert.equal(e.order[finish].id, 'finish');
  assert.deepEqual(e.orderRecheck, [45]);
  assert.deepEqual(e.orderTask(), { k: 45, what: 'recheck' });
});
