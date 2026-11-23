// The tuner without the page: what each frame of sound means for the piano.
// Deviations and status, attacks and the noise gate, following the key,
// measuring, beats, the survey and the tuning order. No DOM, texts, storage,
// audio or timers: the frame's samples and times come in as arguments, and
// what the page must show goes out as events (see Engine.emit). app.js draws
// and binds; theory.js, dsp.js, survey.js and order.js do the sums.

import { KEY_COUNT, A4, PIANO_KINDS, computeTargets, bOutliers, recommendedOverpull, defaultPartial, partialFreq, centsBetween, noteName } from './theory.js';
import { Analyzer, rmsDb, median, steady, STEADY_N, BeatMeter } from './dsp.js';
import * as survey from './survey.js';
import * as order from './order.js';

export const FRAME_MS = 90; // analysis interval
export const SPEC_COLS = 100; // spectrogram history, ≈ 9 s
export const SPEC_BINS = 48;
export const SPEC_CENTS = 30;

// ---------------------------------------------------------------------------
// Clamping rules for settings typed or stepped on the page

// The reference: 380–480 Hz, to 0.1 Hz.
export const clampRef = (hz) => Math.round(Math.max(380, Math.min(480, hz)) * 10) / 10;

// The size in cm within the piano kind's range; anything not a number gives its default.
export function clampSize(kind, v) {
  const k = PIANO_KINDS[kind];
  return Math.round(Math.max(k.min, Math.min(k.max, Number(v) || k.def)));
}

// Strings per key: within the keyboard, one string never above two.
export function clampStrings(top, two, one) {
  const clamp = (v) => Math.max(0, Math.min(top, Math.round(Number(v) || 0)));
  const t = clamp(two);
  return { two: t, one: Math.min(clamp(one), t) };
}

// The measured partial: 1–8.
export const clampPartial = (n) => Math.max(1, Math.min(8, n));

// The keys a step of the tuning order names in its title and text, [from, to].
export function stepRange(id, top) {
  return {
    strip: order.STRIP, pull: [order.STRIP[1], order.STRIP[0]], temperament: [33, 44], upper: [45, order.STRIP[1] - 1],
    treble: [order.STRIP[1] + 1, top], bass: [order.STRIP[0] - 1, 1],
  }[id] || null;
}

// Cents with sign for the debug log, which is not translated.
function logC(c, d = 1) {
  if (!Number.isFinite(c)) return '–';
  const zero = Number(Math.abs(c).toFixed(d)) === 0;
  return (zero ? '±' : c > 0 ? '+' : '−') + Math.abs(c).toFixed(d);
}

// A reading more than JUMP cents from the key's last one is saved only when
// a new attack gives it again, see jumpConfirmed.
const JUMP = 50;

// ---------------------------------------------------------------------------

// Events, as emit(type, data), in the order things happen:
//   key { k, manual }  another key is selected
//   mode { mode }      the mode changed (auto, lock, survey)
//   targets            the targets were computed again
//   dirty              the piano changed and should be saved
//   saved { k }        a measurement of k was saved (the piano is dirty)
//   flash { k }        k is done (surveyed, or a task of the order)
//   survey             the survey's state for the key changed
//   order              the order moved to another position
//   orderState         a strike on the order's key was judged
//   measureB { on }    the manual B measurement started or ended
//   message { id, … }  something to tell: jump, bMeasured, bOutlier, bFailed, surveyDone, orderDone
//   log { line }       a line for the debug log
export class Engine {
  constructor({ emit = () => {}, frameMs = FRAME_MS } = {}) {
    this.listener = emit;
    this.frameMs = frameMs;
    this.events = null; // collected during frame()
    this.beatMeter = new BeatMeter(); // the beat check of the current note, see trackBeating
    Object.assign(this, {
      tuning: null, // the piano
      T: null, // targets from computeTargets
      bBad: new Set(), // keys whose measured B is left out, see bOutliers
      key: A4,
      mode: 'auto', // auto | lock | survey
      analyzer: null,
      level: -100,
      prevLevel: -100,
      levels: [], // levels of the latest frames, for attack detection
      noise: -70,
      signal: false,
      readings: [], // latest readings for the current key: { c, hz }
      display: NaN, // deviation from the (possibly overpulled) target
      measHz: NaN, // measured frequency of the partial, the same readings as display
      stable: false,
      spec: [], // spectrogram columns, see drawSpectro
      frameCol: null,
      beatHz: NaN,
      partialDevs: [],
      strobe: [], // [{ p, c }] per strobe band: partial and deviation from its goal
      strobeReadings: [[], []], // recent readings of the two upper bands
      cand: 0, // candidate key in auto mode and frames in a row
      candCount: 0,
      autoFrames: 0, // frames in a row the current key has been a clear winner
      shift: 0, // auto mode: cents from the target where the current key was heard
      unisonSkip: 0,
      beating: false,
      beatKnown: false, // the beat check has decided for the current note
      beatFedAt: 0, // audio clock when the beat check last heard the note
      frameTime: 0, // audio clock at the end of the latest frame (s)
      now: 0, // steady clock of the latest frame (ms)
      wall: 0, // wall clock of the latest frame (ms since 1970)
      ref: false, // a reference tone is audible in the latest frame
      bReadings: [],
      attacks: 0, // attacks heard, see jumpConfirmed
      inAttack: false,
      jump: null, // { k, hz, attack } a reading far from the last one, waiting for a new attack
      stats: { frames: 0, readings: 0, idle: {}, savedKey: 0, savedAt: 0 }, // counts for the debug log
      measureB: null, // { k, until } during manual B measurement
      survey: null, // the current key in a survey, see survey.newKeyState
      run: null, // the survey as a whole, see survey.newRun
      surveyPlan: 'quick',
      orderOn: false, // the tuning order is shown and followed
      order: null, // steps from order.buildOrder
      orderPos: { step: 0, i: 0 },
      orderConfirm: null, // strikes towards the current task, see order.confirmReading
      orderRecheck: null, // keys outside tolerance when the last step began
      orderAdvice: null, // order.unisonAdvice for the latest strike
      refTainted: false,
    });
  }

  emit(type, data = {}) {
    this.events?.push({ type, ...data });
    this.listener(type, data);
  }

  log(line) {
    this.emit('log', { line });
  }

  // -------------------------------------------------------------------------
  // Derived values

  get settings() {
    return this.tuning.settings;
  }

  tolerance() {
    return Number(this.settings.tolerance) || 1;
  }

  // A7 on older pianos, otherwise C8.
  top() {
    return Number(this.settings.keyCount) === 85 ? 85 : KEY_COUNT;
  }

  partialOf(k) {
    return this.tuning.partials[k] || defaultPartial(k);
  }

  strings(k) {
    const s = this.settings;
    return k <= Number(s.oneStringTo) ? 1 : k <= Number(s.twoStringsTo) ? 2 : 3;
  }

  // Measurements are stored as the frequency of the measured partial, so they
  // stay valid when reference, temperament, stretch or B change.
  keyRec(k) {
    return this.tuning.keys[k];
  }

  devOf(k, hz, n) {
    return hz && n ? centsBetween(hz, partialFreq(this.T.freq[k], this.T.B[k], n)) : NaN;
  }

  curDev(k) {
    return this.devOf(k, this.keyRec(k)?.hz, this.keyRec(k)?.n);
  }

  beforeDev(k) {
    return this.devOf(k, this.keyRec(k)?.bhz, this.keyRec(k)?.bn);
  }

  heardDevs() {
    return Float64Array.from({ length: KEY_COUNT + 1 }, (_, k) => this.curDev(k));
  }

  // Overpull: tune past the target by a share of how far off the key started.
  goal(k) {
    const b = this.beforeDev(k);
    const p = Number(this.settings.overpull) || 0;
    return Number.isFinite(b) && p ? (-p / 100) * b : 0;
  }

  statusDev(k) {
    return this.curDev(k) - this.goal(k);
  }

  // good: within tolerance; warn: within 5 cents or twice the tolerance; bad; none: no value.
  statusClass(d) {
    if (!Number.isFinite(d)) return 'none';
    const a = Math.abs(d);
    if (a <= this.tolerance()) return 'good';
    return a <= Math.max(5, this.tolerance() * 2) ? 'warn' : 'bad';
  }

  // Before values in the middle of the piano (C3–C6).
  midBefore() {
    const d = [];
    for (let k = 28; k <= 64; k++) if (Number.isFinite(this.beforeDev(k))) d.push(this.beforeDev(k));
    return d;
  }

  // Where the middle of the piano was before tuning: the median of midBefore,
  // or NaN with fewer than three of them.
  midShift() {
    const mid = this.midBefore();
    return mid.length >= 3 ? median(mid) : NaN;
  }

  // The fundamental to play as a reference tone, including overpull, and the
  // sine's frequency at the measured partial.
  goalF1(k) {
    return this.T.freq[k] * 2 ** (this.goal(k) / 1200);
  }

  sineFreq(k = this.key) {
    return partialFreq(this.goalF1(k), this.T.B[k], this.partialOf(k));
  }

  // Keys measured in the pass and in tolerance, for the Pass tab.
  passStats() {
    let measured = 0;
    let ok = 0;
    for (let k = 1; k <= this.top(); k++) {
      const d = this.statusDev(k);
      if (!Number.isFinite(d)) continue;
      measured++;
      if (this.statusClass(d) === 'good') ok++;
    }
    return { measured, ok };
  }

  // The advice under the reference: none (too few keys measured), near (within
  // 3 cents) or off, with the median m, the reference that would fit (hz),
  // and the overpull p to use when raising (with the overpulled shift o and
  // its reference ohz; big below −25 cents).
  refAdvice() {
    const m = this.midShift();
    if (!Number.isFinite(m)) return { kind: 'none' };
    if (Math.abs(m) < 3) return { kind: 'near', m };
    const ref = Number(this.settings.refA4);
    const p = recommendedOverpull(m);
    const a = { kind: 'off', m, hz: ref * 2 ** (m / 1200), p };
    if (p) {
      a.o = (-p / 100) * m;
      a.ohz = ref * 2 ** (a.o / 1200);
      a.big = m < -25;
    }
    return a;
  }

  // The overpull to suggest for the pitch raise: 0 when none or unknown.
  suggestedOverpull() {
    const m = this.midShift();
    return Number.isFinite(m) ? recommendedOverpull(m) : 0;
  }

  // Where the piano is, for the order's first two steps: null when unknown,
  // off when 10 cents or more.
  pitchAdvice() {
    const m = this.midShift();
    return Number.isFinite(m) ? { m, off: Math.abs(m) >= 10 } : null;
  }

  // The reference that puts the middle of the piano on target: from the
  // before values in the middle, otherwise the key sounding now. NaN when
  // there is neither (before clampRef).
  fitRefHz() {
    let shift = this.midShift();
    if (!Number.isFinite(shift)) {
      if (this.signal && Number.isFinite(this.display)) shift = this.display + this.goal(this.key);
      else return NaN;
    }
    return Number(this.settings.refA4) * 2 ** (shift / 1200);
  }

  // -------------------------------------------------------------------------
  // The piano

  // A normalized piano (store.normalize) becomes the current one, with its
  // targets and tuning order.
  open(tuning) {
    this.tuning = tuning;
    this.orderRecheck = null;
    this.resetReadings();
    this.computeTargets();
    this.rebuildOrder();
    this.emit('targets');
  }

  computeTargets() {
    this.T = computeTargets(this.settings, this.tuning.inharmonicity);
    this.bBad = bOutliers(this.tuning.inharmonicity);
  }

  // The settings or the measured B changed.
  recompute() {
    this.computeTargets();
    this.emit('targets');
  }

  // The microphone started with this sample rate, or stopped.
  startAudio(sampleRate) {
    this.analyzer = new Analyzer(sampleRate);
    this.noise = -70;
  }

  stopAudio() {
    this.signal = false;
  }

  // A step up or down of the measured partial of the current key.
  setPartial(delta) {
    const k = this.key;
    const n = clampPartial(this.partialOf(k) + delta);
    if (n === defaultPartial(k)) delete this.tuning.partials[k];
    else this.tuning.partials[k] = n;
    this.resetReadings();
  }

  // Strings per key, clamped; the order is built again. Returns what was set.
  setStrings(two, one) {
    const c = clampStrings(this.top(), two, one);
    this.settings.twoStringsTo = c.two;
    this.settings.oneStringTo = c.one;
    this.rebuildOrder();
    return c;
  }

  // End the pass: save a summary to the history and clear the measurements.
  // Inharmonicity and settings are kept. wall: ms since 1970.
  newPass(wall) {
    const t = this.tuning;
    const ks = Array.from({ length: this.top() }, (_, i) => i + 1);
    const after = ks.map((k) => this.statusDev(k)).filter(Number.isFinite);
    const before = ks.map((k) => this.beforeDev(k)).filter(Number.isFinite);
    const meanAbs = (a) => (a.length ? a.reduce((s, x) => s + Math.abs(x), 0) / a.length : 0);
    const now = new Date(wall).toISOString();
    if (after.length) {
      t.history = [
        ...t.history,
        { startedAt: t.passStartedAt, endedAt: now, refA4: Number(this.settings.refA4), measured: after.length, meanAbsBefore: meanAbs(before), meanAbsAfter: meanAbs(after) },
      ].slice(-30);
    }
    t.keys = {};
    t.passStartedAt = now;
    t.order = { step: 0, i: 0 };
    this.orderRecheck = null;
    this.rebuildOrder();
    this.resetReadings();
    this.recompute();
  }

  // -------------------------------------------------------------------------
  // Key and mode

  resetReadings() {
    Object.assign(this, { readings: [], spec: [], beatHz: NaN, display: NaN, measHz: NaN, stable: false, partialDevs: [], strobe: [], strobeReadings: [[], []], bReadings: [], autoFrames: 0 });
    this.resetBeating();
  }

  // manual: chosen on the page, which leaves auto mode.
  selectKey(k, manual = true) {
    k = Math.max(1, Math.min(this.top(), k));
    if (manual && this.mode === 'auto') this.setMode('lock');
    if (k === this.key) return;
    this.log(`key ${noteName(k)} (${manual ? 'chosen' : this.mode})`);
    this.key = k;
    this.resetReadings();
    if (this.survey) this.survey = survey.newKeyState();
    this.emit('key', { k, manual });
  }

  setMode(m) {
    if (m !== this.mode) this.log(`mode ${m}`);
    this.mode = m;
    this.survey = m === 'survey' ? survey.newKeyState() : null;
    this.run = m === 'survey' ? this.newRun() : null;
    this.bReadings = [];
    if (m === 'survey') this.selectKey(this.nextPending(0), false);
    this.emit('mode', { mode: m });
  }

  // -------------------------------------------------------------------------
  // A frame of sound

  // buf: the latest samples (at least the analyzer's size); time: the audio
  // clock when buf ends (s); now: a steady clock (ms) for the B measurement;
  // wall: ms since 1970 for saved measurements; ref: a reference tone is
  // audible, so nothing is saved and the key is not followed. Returns why
  // no reading was taken ('' if one was), and the events of the frame.
  frame(buf, { time, now = 0, wall = 0, ref = false }) {
    this.events = [];
    Object.assign(this, { now, wall, ref });
    this.stats.frames++;
    this.frameCol = null;
    const idle = this.analyseFrame(buf, time);
    this.spec.push(this.frameCol);
    if (this.spec.length > SPEC_COLS) this.spec.shift();
    const events = this.events;
    this.events = null;
    return { idle, events };
  }

  analyseFrame(buf, time) {
    this.frameTime = time; // when buf ends, for the beat check
    const lvl = rmsDb(buf);
    this.prevLevel = this.level;
    this.level = lvl;
    this.levels.push(lvl);
    if (this.levels.length > 4) this.levels.shift();
    const attack = lvl - Math.min(...this.levels) > 12;
    if (attack && !this.inAttack) this.attacks++; // once per attack, though it shows for a few frames
    this.inAttack = attack;
    // A new attack: the previous note's tail is not part of this one's reading.
    if (attack) {
      Object.assign(this, { readings: [], unisonSkip: 0, beatKnown: false, beatFedAt: this.frameTime });
      this.beatMeter.reset();
    }
    // Noise floor: follows quickly down, slowly up, and hardly at all while a
    // note is heard, so a long decay is not mistaken for noise.
    const up = this.signal ? 0.02 : 0.15;
    this.noise = lvl < this.noise ? lvl : this.noise + Math.min(up, (lvl - this.noise) * 0.01);
    // The survey waits for an attack so the previous key's decay is not measured.
    if (this.survey?.waitAttack) {
      if (lvl - this.prevLevel <= 6) return this.idle('waiting for attack');
      this.survey.waitAttack = false;
    }
    // A note starts 10 dB above the noise and is followed down to 5 dB.
    if (lvl < this.gate()) return this.idle('quiet');

    const A = this.analyzer;
    A.load(buf);
    if (this.mode === 'auto') {
      // Keys measured in this pass are also looked for where they were heard,
      // so a key far from its target is not taken for its neighbour.
      const d = A.detectKey(this.T, this.key, this.top(), this.heardDevs());
      // The microphone hears the reference tone too; following it would move
      // the key, and the sine with it, to whatever the speaker plays.
      if (!this.ref) this.followDetectedKey(d);
      // Only the current key's own sound gives a reading, not noise between
      // notes or a note halfway between two keys.
      if (d.key !== this.key || d.margin < 2) return this.idle(d.key !== this.key ? `hears ${noteName(d.key)}` : 'unsure');
      this.shift = d.shift;
    } else if (this.survey) this.survey.heard = A.detectKey(this.T, this.key, this.top());
    return this.measureCurrent(A);
  }

  // The level a note must reach to be heard (dB).
  gate() {
    return Math.max(this.noise + (this.signal ? 5 : 10), -72);
  }

  // Switch key when the same candidate wins two frames in a row by at least 3 dB
  // over its neighbours; as a note dies out, noise peaks win by less. Right
  // after an attack (6 dB up within four frames), one frame with a 10 dB lead
  // is enough. Count how long the current key has been a clear winner; only
  // then does auto mode save.
  followDetectedKey(d) {
    this.autoFrames = d.score > 8 && d.margin >= 6 && d.key === this.key ? this.autoFrames + 1 : 0;
    if (d.score <= 8) return;
    this.candCount = d.key === this.cand ? this.candCount + 1 : 1;
    this.cand = d.key;
    const attack = this.level - Math.min(...this.levels) > 6;
    const frames = attack && d.margin >= 10 ? 1 : 2;
    if (this.candCount >= frames && d.margin >= 3 && d.key !== this.key) this.selectKey(d.key, false);
  }

  idle(why) {
    this.stats.idle[why] = (this.stats.idle[why] || 0) + 1;
    this.signal = false;
    if (this.survey && !this.survey.waitAttack && this.survey.pitch.length) this.survey.lost = true;
    return why;
  }

  measureCurrent(A) {
    const k = this.key;
    const T = this.T;
    const n = this.partialOf(k);
    const target = partialFreq(T.freq[k], T.B[k], n);
    // Auto: around where detection heard the key. Locked key: wide window so
    // that even a badly flat piano is found.
    const auto = this.mode === 'auto';
    const m = A.measure(target * 2 ** ((auto ? this.shift : 0) / 1200), auto ? 50 : 150, 8);
    if (!m) {
      // A key far away has no partial near the target, but detection still hears it.
      if (this.survey && !this.ref) this.trackWrongKey(survey.wrongKey(this.survey.heard, k, NaN, NaN, this.run.done));
      return this.idle('no partial');
    }

    const raw = centsBetween(m.freq, target);
    const ref = this.ref;
    if (!ref && this.refTainted) this.readings = []; // drop readings of the reference tone
    this.refTainted = ref;
    this.readings.push({ c: raw, hz: m.freq });
    if (!ref) this.trackBeating(A, m.freq, m.prom);
    if (this.readings.length > STEADY_N) this.readings.shift();
    const last = this.readings.slice(-5);
    const cs = last.map((r) => r.c);
    const sure = !auto || this.autoFrames >= 3;
    this.stable = !ref && sure && steady(this.readings.map((r) => r.c));
    this.signal = true;
    this.stats.readings++;

    const g = this.goal(k);
    this.display = median(cs) - g;
    this.measHz = median(last.map((r) => r.hz));
    const center = target * 2 ** (g / 1200); // the beat view is centred on the target including overpull
    this.beatHz = center * (2 ** (this.display / 1200) - 1);
    this.frameCol = { col: A.zoom(center, SPEC_CENTS, SPEC_BINS), c: this.display };
    this.partialDevs = Array.from({ length: 8 }, (_, i) => {
      const fi = partialFreq(T.freq[k], T.B[k], i + 1);
      if (fi > A.sr * 0.45 || fi < 40) return null;
      const mi = i + 1 === n ? m : A.measure(fi, 50, 8);
      return mi ? centsBetween(mi.freq, fi) : null;
    });

    // Strobe: the measured partial and the two octaves above it, each against
    // its own target. The upper ones are searched where the measured partial
    // says they should be and smoothed like the main reading.
    this.strobe = [{ p: n, c: this.display }];
    [2 * n, 4 * n].forEach((p, i) => {
      const fp = partialFreq(T.freq[k], T.B[k], p);
      const sk = fp < A.sr * 0.45 ? A.measure(fp * 2 ** (raw / 1200), 30, 8) : null;
      const rs = this.strobeReadings[i];
      rs.push(sk ? centsBetween(sk.freq, fp) - g : NaN);
      if (rs.length > 5) rs.shift();
      const ok = rs.filter(Number.isFinite);
      this.strobe.push({ p, c: ok.length >= 3 ? median(ok) : NaN });
    });

    if (this.stable && this.orderActive()) this.trackOrder(k);

    // Save the value that is shown. During a survey, collectSurvey saves instead.
    if (this.stable && !this.survey) {
      const hz = median(last.map((r) => r.hz));
      if (this.jumpConfirmed(k, n, hz)) this.recordKey(k, n, hz);
    }

    const f1 = T.freq[k] * 2 ** (raw / 1200);
    if (!ref && this.measureB?.k === k) {
      const r = A.inharmonicity(f1, T.B[k]);
      if (r) this.bReadings.push(r.B);
    }
    if (this.survey && !ref) this.collectSurvey(A, k, m.freq, f1, raw);
    if (this.measureB && this.now > this.measureB.until) this.finishMeasureB();
    return '';
  }

  // -------------------------------------------------------------------------
  // Beats

  // A unison out of tune beats: the measured partial pulses (BeatMeter). Its
  // level is followed from 0.5 s after the attack, while the note is clearly
  // heard and not being damped. The hint stays until a later note on the key
  // is clean. A note that fades before the check has 1.5 s of it (short
  // strikes high up) cannot be judged; beatUnheard tells the order so, if the
  // check heard at least 0.5 s of it and found no beat starting.
  trackBeating(A, f, prom) {
    if (prom < 25 || this.level < Math.max(...this.levels) - 12) return;
    this.beatFedAt = this.frameTime;
    if (this.unisonSkip < 6) return void this.unisonSkip++;
    this.beatMeter.add(A.buf, A.sr, f, this.frameTime);
    const b = this.beatMeter.beats();
    if (b !== null) Object.assign(this, { beating: b, beatKnown: true });
  }

  beatUnheard() {
    return !this.beatKnown && this.beatMeter.quiet && this.frameTime - this.beatFedAt > 0.3;
  }

  resetBeating() {
    this.beatMeter.reset();
    Object.assign(this, { unisonSkip: 0, beating: false, beatKnown: false, beatFedAt: this.frameTime });
  }

  // -------------------------------------------------------------------------
  // Saving measurements

  // A reading more than JUMP cents from the key's last one is saved only when a
  // new attack gives it again (within 10 cents). Another note still ringing or
  // a neighbour struck by mistake was saved as A4 at −94 cents. Tuning moves
  // the reading in smaller steps between strikes, so it is not held up.
  jumpConfirmed(k, n, hz) {
    const rec = this.tuning.keys[k];
    if (!rec?.hz || rec.n !== n || Math.abs(centsBetween(hz, rec.hz)) <= JUMP) {
      this.jump = null;
      return true;
    }
    const j = this.jump;
    const same = j && j.k === k && Math.abs(centsBetween(hz, j.hz)) < 10;
    if (same && this.attacks > j.attack) {
      this.jump = null;
      return true;
    }
    if (!same) {
      this.jump = { k, hz, attack: this.attacks };
      const c = centsBetween(hz, rec.hz);
      this.log(`not saved: ${noteName(k)} ${logC(c, 0)} cents from its last reading, waiting for a new attack`);
      this.emit('message', { id: 'jump', k, c });
    }
    return false;
  }

  recordKey(k, n, hz) {
    const rec = this.tuning.keys[k] || {};
    if (!rec.bhz) Object.assign(rec, { bhz: hz, bn: n }); // first measurement in the pass
    Object.assign(rec, { hz, n, at: this.wall });
    this.tuning.keys[k] = rec;
    if (k !== this.stats.savedKey || this.wall - this.stats.savedAt > 2000) {
      this.log(`saved ${noteName(k)} ${logC(centsBetween(hz, partialFreq(this.T.freq[k], this.T.B[k], n)))} cents`);
      Object.assign(this.stats, { savedKey: k, savedAt: this.wall });
    }
    this.emit('saved', { k });
  }

  storeB(k, B) {
    this.log(`B ${noteName(k)} = ${B.toExponential(2)}`);
    this.tuning.inharmonicity[k] = Number(B.toPrecision(4));
    this.emit('dirty');
    this.recompute();
  }

  // Measure B of the current key from the readings of the next 4 s. now: ms
  // on the clock frame() gets. Returns the run, for a timeout that calls
  // finishMeasureB if the note dies away first.
  startMeasureB(now) {
    this.bReadings = [];
    this.measureB = { k: this.key, until: now + 4000 };
    this.emit('measureB', { on: true });
    return this.measureB;
  }

  finishMeasureB() {
    const k = this.measureB.k;
    this.measureB = null;
    this.emit('measureB', { on: false });
    if (this.bReadings.length >= 3) {
      const B = median(this.bReadings);
      this.storeB(k, B);
      this.emit('message', { id: this.bBad.has(k) ? 'bOutlier' : 'bMeasured', k, B });
    } else {
      this.emit('message', { id: 'bFailed' });
    }
    this.bReadings = [];
  }

  // -------------------------------------------------------------------------
  // Survey

  isSurveyed(k) {
    return !!this.keyRec(k)?.mapped;
  }

  isQuick() {
    return this.surveyPlan === 'quick';
  }

  // The quick survey always remeasures B.
  needsB(k) {
    return this.isQuick() || !this.tuning.inharmonicity[k];
  }

  planKeys() {
    return survey.planKeys(this.surveyPlan, this.top());
  }

  newRun() {
    return survey.newRun(this.surveyPlan, this.top(), (k) => this.isSurveyed(k));
  }

  nextPending(k) {
    return survey.nextPending(this.run, this.surveyPlan, this.top(), k);
  }

  // Choose the plan; a running survey starts over with it.
  setSurveyPlan(p) {
    this.surveyPlan = p;
    if (!this.survey) return;
    this.survey = survey.newKeyState();
    this.run = this.newRun();
    this.selectKey(this.nextPending(0), false);
  }

  // Nothing from another key is kept; the hint shows after a few frames in a row.
  trackWrongKey(other) {
    const sk = this.survey;
    sk.wrongFrames = other ? sk.wrongFrames + 1 : 0;
    sk.wrong = sk.wrongFrames >= 3 ? other : 0;
    // Drop what was collected: the start of a wrong note can look right.
    if (other) Object.assign(sk, { pitch: [], bs: [], ms: 0 });
    return other;
  }

  collectSurvey(A, k, partialHz, f1, raw) {
    const sk = this.survey;
    if (this.trackWrongKey(survey.wrongKey(sk.heard, k, raw, median(this.run.offsets), this.run.done))) return this.emit('survey');
    sk.pitch.push(partialHz);
    sk.ms += this.frameMs;
    sk.lost = false;
    if (this.needsB(k) && sk.bs.length < survey.B_READINGS) {
      const r = A.inharmonicity(f1, this.T.B[k]);
      if (r) sk.bs.push(r.B);
    }
    if (!survey.keyDone(sk, this.needsB(k), this.surveyPlan)) return this.emit('survey');

    const hz = median(sk.pitch);
    const n = this.partialOf(k);
    this.run.offsets.push(centsBetween(hz, partialFreq(this.T.freq[k], this.T.B[k], n)));
    // Before stays the first measurement in the pass, as in recordKey.
    this.tuning.keys[k] = { bhz: hz, bn: n, ...this.keyRec(k), hz, n, at: this.wall, mapped: true };
    if (sk.bs.length >= 3) this.storeB(k, median(sk.bs));
    else {
      this.emit('dirty');
      this.recompute();
    }
    this.emit('flash', { k });
    this.run.done.add(k);
    this.advanceSurvey(k);
  }

  skipSurveyKey() {
    this.run.skipped.add(this.key);
    this.advanceSurvey(this.key);
  }

  // Measure the current key again from the start.
  redoSurveyKey() {
    this.survey = survey.newKeyState();
  }

  advanceSurvey(k) {
    const next = this.nextPending(k);
    if (next) this.selectKey(next, false);
    else this.finishSurvey();
  }

  // The survey is over: back to Lock at A4, where tuning starts. The message
  // has what was measured: quick, b (keys with measured B) of n (the plan's
  // keys, or the keys surveyed in a full survey), and the keys skipped and
  // the B outliers.
  finishSurvey() {
    const withB = (ks) => ks.filter((k) => this.tuning.inharmonicity[k]).length;
    const all = Array.from({ length: this.top() }, (_, i) => i + 1);
    const quick = this.isQuick();
    const done = {
      id: 'surveyDone',
      quick,
      b: withB(quick ? this.planKeys() : all),
      n: quick ? this.planKeys().length : all.filter((k) => this.isSurveyed(k)).length,
      skipped: [...this.run.skipped].sort((a, b) => a - b),
      outliers: [...this.bBad].sort((a, b) => a - b),
    };
    this.setMode('lock');
    this.selectKey(A4, false); // tuning starts in the temperament octave
    this.emit('message', done);
  }

  // -------------------------------------------------------------------------
  // Tuning order: optional. Any other key or mode can be used meanwhile, and
  // the order waits for its key.

  orderActive() {
    return this.orderOn && this.mode !== 'survey' && !!this.order;
  }

  orderTask() {
    return this.order ? order.taskAt(this.order, this.orderPos) : null;
  }

  orderStepIndex(id) {
    return this.order.findIndex((s) => s.id === id);
  }

  // Keys measured and outside tolerance, for the last step.
  recheckKeys() {
    return Array.from({ length: this.top() }, (_, i) => i + 1).filter((k) => Number.isFinite(this.curDev(k)) && this.statusClass(this.statusDev(k)) !== 'good');
  }

  rebuildOrder() {
    if (!this.tuning) return;
    const s = this.settings;
    const build = () => {
      this.order = order.buildOrder({ top: this.top(), twoStringsTo: Number(s.twoStringsTo) || 0, oneStringTo: Number(s.oneStringTo) || 0, dsu: s.unisons === 'dsu' }, this.orderRecheck || []);
      this.orderPos = order.clampPos(this.order, this.tuning.order);
    };
    build();
    if (this.order[this.orderPos.step].id === 'finish' && !this.orderRecheck) {
      this.orderRecheck = this.recheckKeys(); // opened on the last step
      build();
    }
    this.orderConfirm = order.newConfirm(this.attacks);
    this.orderAdvice = null;
  }

  // Select the key the order is on.
  followOrder() {
    const t = this.orderTask();
    if (t && this.orderActive()) this.selectKey(t.k, false);
    this.emit('order');
  }

  setOrderOn(on) {
    this.orderOn = on;
    this.log(`tuning order ${on ? 'on' : 'off'}`);
    if (on && this.mode === 'auto') this.setMode('lock');
    this.followOrder();
  }

  // Move to a position and select its key. The last step lists the keys
  // outside tolerance as it begins.
  goOrder(pos) {
    const finish = this.orderStepIndex('finish');
    if (pos.step === finish && this.orderPos.step !== finish) this.orderRecheck = this.recheckKeys();
    else if (pos.step !== finish) this.orderRecheck = null;
    this.tuning.order = { step: pos.step, i: pos.i };
    this.rebuildOrder();
    this.emit('dirty');
    this.followOrder();
  }

  orderDone() {
    this.log('tuning order done');
    this.emit('message', { id: 'orderDone' });
  }

  orderNext() {
    const next = order.nextPos(this.order, this.orderPos);
    if (next) this.goOrder(next);
    else this.orderDone();
  }

  orderPrev() {
    this.goOrder(order.prevPos(this.order, this.orderPos) || this.orderPos);
  }

  // On to the next step.
  orderSkip() {
    const step = this.orderPos.step + 1;
    if (step < this.order.length) this.goOrder({ step, i: 0 });
    else this.orderDone();
  }

  // Back to the order's key from another one.
  orderBack() {
    if (this.mode === 'auto') this.setMode('lock');
    this.selectKey(this.orderTask().k, false);
  }

  // The treble and the bass get other tasks: the order stays on the key it was on.
  setUnisons(v) {
    const k = this.orderTask()?.k;
    const { step } = this.orderPos;
    this.settings.unisons = v;
    this.rebuildOrder();
    const i = this.order[step].tasks.findIndex((t) => t.k === k);
    this.goOrder({ step, i: Math.max(0, i) });
  }

  // A steady reading on the order's key: in tune counts, and two strikes in a
  // row move on. Unisons also need the beat check to have seen the note clean.
  trackOrder(k) {
    const t = this.orderTask();
    if (!t || t.k !== k || this.ref) return;
    const s = this.statusClass(this.display);
    // Tasks with more than one string sounding must also be clean, not only on pitch.
    const unison = order.UNISON_TASKS.has(t.what);
    // A note too short for the beat check counts on pitch alone.
    const clean = !this.beating && (this.beatKnown || this.beatUnheard());
    const loose = this.order[this.orderPos.step].loose;
    const ok = loose ? s !== 'bad' : s === 'good' && !(unison && !clean);
    // A clean unison off target gets a hint on moving it as a whole.
    this.orderAdvice = loose ? null : order.unisonAdvice(t, (x) => this.strings(x), { clean, status: s });
    const done = order.confirmReading(this.orderConfirm, this.attacks, ok);
    this.emit('orderState');
    if (!done) return;
    this.log(`order: ${t.what} ${noteName(k)} done`);
    this.emit('flash', { k });
    const next = order.nextPos(this.order, this.orderPos);
    if (next) this.goOrder(next);
    else this.orderDone();
  }
}
