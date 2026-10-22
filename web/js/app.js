// Piano Tunah: state, DOM and events. Calculations live in theory.js and
// dsp.js, drawing in draw.js, audio in mic.js/tone.js, saving in saver.js.

import {
  KEY_COUNT, A4, TEMPERAMENTS, PIANO_KINDS, STRETCH_PRESETS, OCTAVE_TYPES, sizeClass,
  computeTargets, bOutliers, recommendedOverpull, defaultPartial, partialFreq, centsBetween, noteName, pcName, pitchClass, isBlack,
} from './theory.js';
import { Analyzer, rmsDb, median } from './dsp.js';
import { listTunings, getTuning, saveTuning, deleteTuning, newTuning, normalize, duplicateTuning } from './store.js';
import { num, short, fmtC, fmtHz, fmtB } from './format.js';
import { tr, trNodes, lang, locale, setLang, translateDom } from './i18n.js';
import { Mic } from './mic.js';
import { TonePlayer } from './tone.js';
import { Saver } from './saver.js';
import { enableDiag, diagOn, diag } from './diag.js';
import { readColors, drawDial, drawSpectro, drawBeat, drawChart } from './draw.js';
import * as mapping from './mapping.js';

const $ = (id) => document.getElementById(id);

const FRAME_MS = 90; // analysis interval
const SPEC_COLS = 100; // spectrogram history, ≈ 9 s
const SPEC_BINS = 48;
const SPEC_CENTS = 30;
const REC_MAX_S = 120;
const LS = { tuning: 'pianotunah.lastTuning', tone: 'pianotunah.toneMode', theme: 'pianotunah.theme', plan: 'pianotunah.mapPlan', tab: 'pianotunah.tab', curve: 'pianotunah.curve', partials: 'pianotunah.partials', beats: 'pianotunah.beats', mic: 'pianotunah.mic' };

const mic = new Mic();
const tones = new TonePlayer();

const state = {
  tuning: null,
  T: null, // targets from computeTargets
  list: [],
  key: A4,
  mode: 'auto', // auto | lock | map
  analyzer: null,
  timer: 0,
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
  beatPhase: 0,
  partialDevs: [],
  strobe: [], // [{ p, c }] per strobe band: partial and deviation from its goal
  strobeReadings: [[], []], // recent readings of the two upper bands
  micId: '', // chosen input, '' = system default
  cand: 0, // candidate key in auto mode and frames in a row
  candCount: 0,
  autoFrames: 0, // frames in a row the current key has been a clear winner
  shift: 0, // auto mode: cents from the target where the current key was heard
  unison: [], // readings for the beat check, see trackBeating
  unisonSkip: 0,
  beating: false,
  bReadings: [],
  bBad: new Set(), // keys whose measured B is left out, see bOutliers
  version: '', // the server's version when the page loaded, see checkVersion
  attacks: 0, // attacks heard, see jumpConfirmed
  inAttack: false,
  jump: null, // { k, hz, attack } a reading far from the last one, waiting for a new attack
  diag: { frames: 0, readings: 0, idle: {}, savedKey: 0, savedAt: 0 }, // counts for the debug log, see diagStatus
  measureB: null, // { k, until } during manual B measurement
  map: null, // survey of the current key, see mapping.newKeyState
  run: null, // the survey as a whole, see mapping.newRun
  mapPlan: 'quick',
  toneMode: 'off', // off | piano | sine
  refUntil: 0, // reference tone audible in the microphone until this time
  refTainted: false,
  wakeLock: null,
  recTimer: 0,
  ringPhase: [0, 0, 0],
  lastAnim: 0,
  colors: {},
  chartGeo: null,
};

// ---------------------------------------------------------------------------
// Derived values

const S = () => state.tuning.settings;
const kName = (k) => noteName(k);
const tolerance = () => Number(S().tolerance) || 1;
const top = () => (Number(S().keyCount) === 85 ? 85 : KEY_COUNT); // A7 on older pianos, otherwise C8
const partialOf = (k) => state.tuning.partials[k] || defaultPartial(k);
const bSource = (k) => tr(!state.tuning.inharmonicity[k] ? 'b.model' : state.bBad.has(k) ? 'b.outlier' : 'b.measured');
const fmtDate = (d) => d.toLocaleDateString(locale(), { dateStyle: 'medium' });

// Measurements are stored as the frequency of the measured partial, so they
// stay valid when reference, temperament, stretch or B change.
const keyRec = (k) => state.tuning.keys[k];
const devOf = (k, hz, n) => (hz && n ? centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n)) : NaN);
const curDev = (k) => devOf(k, keyRec(k)?.hz, keyRec(k)?.n);
const beforeDev = (k) => devOf(k, keyRec(k)?.bhz, keyRec(k)?.bn);
const heardDevs = () => Float64Array.from({ length: KEY_COUNT + 1 }, (_, k) => curDev(k));

// Overpull: tune past the target by a share of how far off the key started.
function goal(k) {
  const b = beforeDev(k);
  const p = Number(S().overpull) || 0;
  return Number.isFinite(b) && p ? (-p / 100) * b : 0;
}
const statusDev = (k) => curDev(k) - goal(k);

function statusClass(d) {
  if (!Number.isFinite(d)) return 'none';
  const a = Math.abs(d);
  if (a <= tolerance()) return 'good';
  return a <= Math.max(5, tolerance() * 2) ? 'warn' : 'bad';
}

// The microphone hears the speaker (no echo cancellation). Nothing is saved
// while a reference tone sounds.
const refPlaying = () => tones.sineOn || performance.now() < state.refUntil;

function midBefore() {
  const d = [];
  for (let k = 28; k <= 64; k++) if (Number.isFinite(beforeDev(k))) d.push(beforeDev(k));
  return d;
}

// ---------------------------------------------------------------------------
// Messages. ms = 0: stays until closed. tag: lets it be removed when the
// cause goes away.

let msgTimer = 0;
// action: { label, run } shows a button in the message.
function message(text, kind = 'info', ms = 6000, tag = '', action = null) {
  const el = $('message');
  $('message-text').textContent = text;
  const btn = $('message-action');
  btn.hidden = !action;
  if (action) Object.assign(btn, { textContent: action.label, onclick: action.run });
  Object.assign(el.dataset, { kind, tag });
  el.hidden = false;
  clearTimeout(msgTimer);
  if (ms) msgTimer = setTimeout(() => (el.hidden = true), ms);
}

function clearMessage(tag) {
  if (!$('message').hidden && $('message').dataset.tag === tag) $('message').hidden = true;
}

// ---------------------------------------------------------------------------
// Saving

const saver = new Saver({
  current: () => state.tuning,
  onState: setSaveState,
  onSaved(t) {
    clearMessage('server');
    const item = state.list.find((x) => x.id === t.id);
    if (item && item.name !== t.name) {
      item.name = t.name;
      renderTuningSelect();
    }
  },
  onConflict: reloadAfterConflict,
});
const markDirty = () => saver.markDirty();

// Every label is in the chip, stacked, so it is as wide as the longest one and
// the top bar does not shift when the state changes.
function setSaveState(s) {
  const el = $('save-status');
  el.dataset.state = s;
  el.replaceChildren(...['idle', 'dirty', 'saving', 'error'].map((x) => {
    const span = document.createElement('span');
    span.textContent = tr('save.' + x);
    span.classList.toggle('on', x === s);
    return span;
  }));
  el.title = s === 'error' ? tr('save.errorTitle') : '';
}

async function reloadAfterConflict(t) {
  try {
    const latest = await getTuning(t.id);
    saver.dirty = false;
    await openTuning(latest);
    message(tr('msg.conflict'), 'warn', 0);
  } catch {
    setSaveState('error');
    message(tr('msg.conflictFailed'), 'error', 0);
  }
}

// ---------------------------------------------------------------------------
// Saved tunings

async function refreshList() {
  state.list = await listTunings();
  renderTuningSelect();
}

function renderTuningSelect() {
  const sel = $('tuning-select');
  sel.replaceChildren(...state.list.map((t) => option(t.id, t.name || tr('name.untitled'))));
  if (state.tuning) sel.value = state.tuning.id;
}

async function openTuning(t) {
  await saver.flush();
  state.tuning = normalize(t);
  try { localStorage.setItem(LS.tuning, t.id); } catch { /* optional */ }
  resetReadings();
  recompute();
  renderSettings();
  renderTuningSelect();
  setSaveState('idle');
}

async function createAndOpen(t) {
  t.rev = (await saveTuning(t)).rev;
  await refreshList();
  await openTuning(t);
}

// ---------------------------------------------------------------------------
// Rendering

const option = (value, text) => Object.assign(document.createElement('option'), { value, textContent: text });

function recompute() {
  state.T = computeTargets(S(), state.tuning.inharmonicity);
  state.bBad = bOutliers(state.tuning.inharmonicity);
  renderKeyInfo();
  renderKeyboard();
  renderRef();
  renderPass();
  renderChart();
  if ($('table-details').open) renderTable();
}

// Language-dependent parts of the static markup. Run again when the language changes.
function buildStaticUi() {
  translateDom();
  $('set-lang').value = lang();
  $('set-kind').replaceChildren(...Object.keys(PIANO_KINDS).map((k) => option(k, tr('kind.' + k))));
  $('set-temperament').replaceChildren(...Object.keys(TEMPERAMENTS).map((k) => option(k, tr('temperament.' + k))));
  $('set-stretch').replaceChildren(...Object.keys(STRETCH_PRESETS).map((k) => option(k, tr('stretch.' + k))));
  for (const id of ['set-bass', 'set-mid', 'set-treble']) $(id).replaceChildren(...Object.keys(OCTAVE_TYPES).map((k) => option(k, k)));
  $('set-root').replaceChildren(...Array.from({ length: 12 }, (_, pc) => option(pc, pcName(pc))));
  renderMicList();
  for (const o of $('set-tolerance').options) o.textContent = tr('tuning.cents', { n: short(Number(o.value)) });
  document.querySelectorAll('[data-ref]').forEach((b) => (b.textContent = (b.dataset.ref < 0 ? '−' : '+') + short(Math.abs(b.dataset.ref))));
}

// White keys in a flex row, black keys absolutely positioned between them.
// Rebuilt only when the number of keys changes.
function buildKeyboard(n) {
  const kb = $('keyboard');
  if (kb.children.length === n) return;
  let whites = 0;
  for (let k = 1; k <= n; k++) if (!isBlack(k)) whites++;
  const keys = [];
  let wi = 0;
  for (let k = 1; k <= n; k++) {
    const b = Object.assign(document.createElement('button'), { type: 'button', className: 'key ' + (isBlack(k) ? 'black' : 'white') });
    b.dataset.k = k;
    if (isBlack(k)) {
      b.style.left = `${(wi / whites) * 100}%`;
      b.dataset.cx = (wi / whites) * 100;
    } else {
      b.dataset.cx = ((wi++ + 0.5) / whites) * 100;
      b.append(Object.assign(document.createElement('span'), { className: 'klabel' }));
    }
    keys.push(b);
  }
  kb.replaceChildren(...keys);
}

function applyKeyCount() {
  buildKeyboard(top());
  if (state.key > top()) selectKey(top(), false);
  renderKeyboard();
  renderChart();
}

function renderSettings() {
  const s = S();
  applyKeyCount();
  $('set-name').value = state.tuning.name;
  $('set-kind').value = s.pianoKind;
  $('set-size').value = s.sizeCm;
  $('set-keys').value = String(top());
  $('set-temperament').value = s.temperament;
  $('set-root').value = s.root;
  if (s.temperament !== 'et') $('temper-details').open = true; // never hide an active historical temperament
  $('set-stretch').value = s.stretch;
  $('set-bass').value = s.bassOctave;
  $('set-mid').value = s.midOctave;
  $('set-treble').value = s.trebleOctave;
  $('set-extra-treble').value = s.extraTreble;
  $('set-extra-bass').value = s.extraBass;
  $('set-overpull').value = s.overpull;
  $('set-tolerance').value = String(s.tolerance);
  $('set-notes').value = state.tuning.notes || '';
  renderSettingDescs();
}

function renderSettingDescs() {
  const s = S();
  const kindId = s.pianoKind in PIANO_KINDS ? s.pianoKind : 'upright';
  const kind = PIANO_KINDS[kindId];
  $('temperament-desc').textContent = s.temperament in TEMPERAMENTS ? tr(`temperament.${s.temperament}.desc`) : '';
  $('stretch-desc').textContent = s.stretch in STRETCH_PRESETS ? tr(`stretch.${s.stretch}.desc`) : '';
  $('custom-oct').hidden = s.stretch !== 'custom';
  $('set-root').disabled = s.temperament === 'et';
  $('size-label').textContent = tr(`kind.${kindId}.size`);
  Object.assign($('set-size'), { min: kind.min, max: kind.max });
  $('out-size').textContent = tr('size.' + sizeClass(s.pianoKind, Number(s.sizeCm)));
  $('size-desc').textContent = tr('piano.sizeDesc', { how: tr(`kind.${kindId}.how`) });
  $('out-extra-treble').textContent = tr('tuning.atC8', { c: fmtC(Number(s.extraTreble), 0) });
  $('out-extra-bass').textContent = tr('tuning.atA0', { c: Number(s.extraBass) ? '−' + num(Number(s.extraBass), 0) : '±0' });
  $('out-overpull').textContent = s.overpull + (lang() === 'sv' ? ' %' : '%');
}

function renderRef() {
  const ref = Number(S().refA4);
  if (document.activeElement !== $('set-ref')) $('set-ref').value = ref.toFixed(1);
  $('btn-ref-chip').textContent = `A4 = ${fmtHz(ref, 1)}`;
  const c = centsBetween(ref, 440);
  $('ref-cents').textContent = Math.abs(c) < 0.05 ? tr('ref.standard') : tr('ref.vs440', { c: fmtC(c) });
  for (const b of $('ref-presets').children) b.classList.toggle('on', Number(b.dataset.hz) === ref);

  const mid = midBefore();
  $('btn-overpull').hidden = true;
  if (mid.length < 3) {
    $('ref-advice').textContent = tr('ref.adviceNone');
    return;
  }
  const m = median(mid);
  if (Math.abs(m) < 3) {
    $('ref-advice').textContent = tr('ref.adviceNear', { c: fmtC(m) });
    return;
  }
  const p = recommendedOverpull(m);
  let text = tr('ref.adviceOff', { c: fmtC(m), hz: fmtHz(ref * 2 ** (m / 1200), 1) });
  if (p) {
    const o = (-p / 100) * m;
    text += tr('ref.overpull', { p, c: fmtC(m, 0), o: fmtC(o, 0), hz: fmtHz(ref * 2 ** (o / 1200), 1) });
    if (m < -50) text += ' ' + tr('ref.overpullBig');
    $('btn-overpull').textContent = tr('ref.useOverpull', { p });
    $('btn-overpull').dataset.p = p;
    $('btn-overpull').hidden = Number(S().overpull) === p;
  } else {
    text += tr(m > 0 ? 'ref.adviceSharp' : 'ref.adviceSmall');
  }
  $('ref-advice').textContent = text;
}

// The note in the hub: accidental raised and octave lowered (B♭₄), as in
// chord symbols and scientific pitch notation.
function renderNoteName(k) {
  const [, letter, acc, oct] = kName(k).match(/^([A-G])(\D?)(\d)$/);
  const span = (cls, text) => Object.assign(document.createElement('span'), { className: cls, textContent: text });
  $('note-name').replaceChildren(letter, ...(acc ? [span('acc', acc)] : []), span('oct', oct));
}

function renderKeyInfo() {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const g = goal(k);
  renderNoteName(k);
  $('note-sub').replaceChildren(...trNodes('key.sub', { k, c: fmtC(T.cents[k]) }));
  $('targetline').replaceChildren(
    ...trNodes('target.fund', { hz: fmtHz(T.freq[k]) }),
    ...(n > 1 ? trNodes('target.partial', { n, hz: fmtHz(partialFreq(T.freq[k], T.B[k], n)) }) : []),
    ...(g ? trNodes('target.overpull', { c: fmtC(g) }) : []),
  );
  $('partial-val').textContent = n;
  $('bval').textContent = tr('measure.bval', { b: fmtB(T.B[k]), src: bSource(k) });
  if (tones.sineOn) {
    diag(`sine ${kName(k)} partial ${n}, ${fmtHz(sineFreq())}`);
    tones.setSine(sineFreq());
  }
  renderToneButton();
}

function renderKeyboard() {
  buildKeyboard(top());
  const cur = Math.min(state.key, top());
  const quickPlan = state.map && state.mapPlan === 'quick';
  for (const el of $('keyboard').children) {
    const k = Number(el.dataset.k);
    const label = tr('key.label', { name: kName(k), dev: Number.isFinite(curDev(k)) ? fmtC(statusDev(k)) + ' ' + tr('unit.cents') : tr('key.unmeasured') });
    el.classList.toggle('current', k === cur);
    el.classList.toggle('has-b', !!state.tuning.inharmonicity[k]);
    el.classList.toggle('plan', !!quickPlan && mapping.QUICK_KEYS.includes(k));
    if (el.firstChild) el.firstChild.textContent = pitchClass(k) === 0 || k === 1 ? kName(k) : '';
    el.setAttribute('aria-label', label);
    el.setAttribute('aria-current', k === cur);
    el.title = label;
  }
  const curEl = $('keyboard').children[cur - 1];
  const marker = $('kb-marker');
  marker.style.left = `calc(6px + (100% - 12px) * ${Number(curEl.dataset.cx) / 100})`;
  marker.dataset.s = statusClass(statusDev(cur));
  $('kb-marker-name').textContent = kName(cur);
}

function renderPass() {
  let measured = 0;
  let ok = 0;
  for (let k = 1; k <= top(); k++) {
    const d = statusDev(k);
    if (!Number.isFinite(d)) continue;
    measured++;
    if (statusClass(d) === 'good') ok++;
  }
  const since = new Date(state.tuning.passStartedAt || state.tuning.createdAt);
  $('pass-stats').replaceChildren(
    stat(`${ok}/${top()}`, tr('pass.inTol')),
    stat(`${measured}`, tr('pass.measured')),
    stat(fmtDate(since), tr('pass.started')),
  );
  $('history').replaceChildren(
    ...[...state.tuning.history].reverse().map((p) =>
      Object.assign(document.createElement('li'), {
        textContent: tr('pass.entry', {
          date: fmtDate(new Date(p.startedAt)), n: p.measured, ref: num(p.refA4, 1), before: num(p.meanAbsBefore), after: num(p.meanAbsAfter),
        }),
      }),
    ),
  );
}

function stat(value, label) {
  const d = Object.assign(document.createElement('div'), { className: 'stat' });
  d.append(Object.assign(document.createElement('b'), { textContent: value }), Object.assign(document.createElement('span'), { textContent: label }));
  return d;
}

function renderTable() {
  const T = state.T;
  const head = document.createElement('thead');
  const hrow = document.createElement('tr');
  for (const h of ['table.key', 'table.note', 'table.targetC', 'table.targetHz', 'B', 'table.partial', 'table.before', 'table.now']) {
    hrow.append(Object.assign(document.createElement('th'), { textContent: tr(h) }));
  }
  head.append(hrow);
  const body = document.createElement('tbody');
  for (let k = top(); k >= 1; k--) {
    const row = document.createElement('tr');
    const cells = [
      k, kName(k), fmtC(T.cents[k]), num(T.freq[k], 2),
      fmtB(T.B[k]) + (state.bBad.has(k) ? ' ?' : state.tuning.inharmonicity[k] ? ' *' : ''), partialOf(k), fmtC(beforeDev(k)), fmtC(statusDev(k)),
    ];
    for (const c of cells) row.append(Object.assign(document.createElement('td'), { textContent: c }));
    row.lastChild.dataset.s = statusClass(statusDev(k));
    if (k === state.key) row.className = 'current';
    body.append(row);
  }
  $('ktable').replaceChildren(head, body);
}

function renderChart() {
  if (!state.T) return;
  const T = state.T;
  const points = [];
  const ticks = [];
  for (let k = 1; k <= top(); k++) {
    const d = curDev(k);
    if (Number.isFinite(d)) points.push({ k, c: T.cents[k] + d, status: statusClass(statusDev(k)) });
    if (pitchClass(k) === 0) ticks.push({ k, label: kName(k) });
  }
  // The keyboard's key positions are the x axis.
  const xs = [0, ...[...$('keyboard').children].map((el) => el.dataset.cx / 100)];
  const c = $('minichart');
  state.chartGeo = c.clientWidth ? drawChart(c, { top: top(), target: T.cents, points, ticks, current: state.key, xs }, state.colors) : null;
  renderCurveHint();
}

// Until some inharmonicity is measured, the curve comes from the model.
function renderCurveHint() {
  $('curve-hint').hidden = $('curve-row').hidden || state.mode === 'map' || Object.keys(state.tuning.inharmonicity).length > 0;
}

function setCurveOpen(open) {
  $('curve-row').hidden = $('table-details').hidden = !open;
  document.querySelector('.lg-curve').hidden = !open;
  $('curve-toggle').setAttribute('aria-expanded', open);
  if (open) renderChart(); // not drawn while folded
  else renderCurveHint();
}

// Folds under the dial: beats and partials. Not drawn while closed.
function setFoldOpen(name, open) {
  $(name + '-row').hidden = !open;
  $(name + '-toggle').setAttribute('aria-expanded', open);
  if (name === 'partials') renderPartials();
}

// Update key status at most once per frame, even if readings are saved more often.
let statusRaf = 0;
function renderKeyStatus() {
  statusRaf ||= requestAnimationFrame(() => {
    statusRaf = 0;
    renderKeyboard();
    renderPass();
    renderChart();
  });
}

function chartKeyAt(e) {
  const c = e.currentTarget;
  const k = state.chartGeo?.keyAt(e.clientX - c.getBoundingClientRect().left);
  return k >= 1 && k <= top() ? k : 0;
}

function chartHover(e) {
  const k = chartKeyAt(e);
  const geo = state.chartGeo;
  const tip = $('minitip');
  tip.hidden = !k;
  if (!k) return;
  const T = state.T;
  const rows = [
    [kName(k), tr('tip.key', { k })],
    [tr('tip.target'), `${fmtC(T.cents[k])} ${tr('unit.cents')} · ${fmtHz(T.freq[k])}`],
    ['B', `${fmtB(T.B[k])} ${bSource(k)}`],
  ];
  if (Number.isFinite(curDev(k))) rows.push([tr('tip.dev'), `${fmtC(statusDev(k))} ${tr('unit.cents')}`]);
  tip.replaceChildren(
    ...rows.map(([a, b]) => {
      const row = document.createElement('div');
      row.append(Object.assign(document.createElement('b'), { textContent: a }), Object.assign(document.createElement('span'), { textContent: b }));
      return row;
    }),
  );
  // Keep the tooltip within the curve.
  tip.style.left = Math.max(4, Math.min(geo.xOf(k) + 12, $('minichart').clientWidth - tip.offsetWidth - 4)) + 'px';
  tip.style.top = Math.max(4, geo.yOf(T.cents[k]) - tip.offsetHeight - 10) + 'px';
}

// ---------------------------------------------------------------------------
// Key and mode

function resetReadings() {
  Object.assign(state, { readings: [], spec: [], beatHz: NaN, display: NaN, measHz: NaN, stable: false, partialDevs: [], strobe: [], strobeReadings: [[], []], bReadings: [], autoFrames: 0 });
  resetBeating();
}

function selectKey(k, manual = true) {
  k = Math.max(1, Math.min(top(), k));
  if (manual && state.mode === 'auto') setMode('lock');
  if (k === state.key) return;
  diag(`key ${kName(k)} (${manual ? 'chosen' : state.mode})`);
  state.key = k;
  resetReadings();
  if (state.map) state.map = mapping.newKeyState();
  renderMapPanel();
  renderKeyInfo();
  renderKeyboard();
  renderChart();
  if ($('table-details').open) renderTable();
}

function setMode(m) {
  if (m !== state.mode) diag(`mode ${m}`);
  state.mode = m;
  for (const id of ['auto', 'lock', 'map']) $('mode-' + id).setAttribute('aria-pressed', m === id);
  state.map = m === 'map' ? mapping.newKeyState() : null;
  state.run = m === 'map' ? newRun() : null;
  state.bReadings = [];
  $('map-panel').hidden = m !== 'map';
  if (m === 'map') selectKey(nextPending(0), false);
  renderKeyboard();
  renderMapPanel();
  renderCurveHint();
}

// ---------------------------------------------------------------------------
// Measuring

async function startMic() {
  try {
    try {
      await mic.start(state.micId);
    } catch (e) {
      if (!state.micId || !['OverconstrainedError', 'NotFoundError'].includes(e.name)) throw e;
      // The chosen input is unplugged. Keep the choice for when it is back.
      message(tr('mic.missing'), 'warn');
      await mic.start();
    }
  } catch (e) {
    diag(`mic failed: ${e.name} ${e.message}`);
    const key = { insecure: 'mic.insecure', NotAllowedError: 'mic.denied' }[e.name];
    message(key ? tr(key) : tr('mic.failed', { err: e.message }), 'error', 0);
    return;
  }
  state.analyzer = new Analyzer(mic.sampleRate);
  state.noise = -70;
  watchMic();
  state.timer = setInterval(processFrame, FRAME_MS);
  renderMicButton();
  renderMicList(); // names are known now
  requestWakeLock();
}

// Debug log: what the browser does with the microphone, so a stop shows why.
function watchMic() {
  const track = mic.stream.getAudioTracks()[0];
  diag(`mic on: ${mic.label || 'default input'}, ${mic.sampleRate} Hz, audio ${mic.ctx.state}`);
  mic.ctx.addEventListener('statechange', () => diag(`audio ${mic.ctx?.state}`));
  for (const ev of ['mute', 'unmute', 'ended']) track?.addEventListener(ev, () => diag(`mic track ${ev}`));
}

// Every 5 s while the microphone runs: frames analysed, readings, and why the
// other frames gave none.
function diagStatus() {
  const d = state.diag;
  if (mic.running && diagOn()) {
    const track = mic.stream?.getAudioTracks()[0];
    const idle = Object.entries(d.idle).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ') || '–';
    const gate = Math.max(state.noise + (state.signal ? 5 : 10), -72);
    diag(
      `status: ${d.frames} frames, ${d.readings} readings; idle: ${idle}; level ${state.level.toFixed(0)} dB, noise ${state.noise.toFixed(0)}, gate ${gate.toFixed(0)}; ` +
        `${state.mode} ${kName(state.key)}; audio ${mic.ctx.state}, track ${track?.readyState}${track?.muted ? ' muted' : ''}, page ${document.visibilityState}` +
        (refPlaying() ? ', reference tone' : ''),
    );
  }
  Object.assign(d, { frames: 0, readings: 0, idle: {} });
}

// An installed app has no reload button and can stay open for days, so it
// says when the server runs a newer version: when shown again and every 30 min.
function checkVersion() {
  if (!state.version) return;
  fetch('api/version')
    .then((r) => r.json())
    .then(({ version }) => {
      if (version === state.version) return;
      diag(`new version ${version} (running ${state.version})`);
      message(tr('msg.update', { v: version }), 'info', 0, 'update', { label: tr('msg.reload'), run: () => location.reload() });
    })
    .catch(() => {});
}

function stopMic() {
  diag('mic off');
  if (mic.recording) finishRecording();
  clearInterval(state.timer);
  mic.stop();
  state.signal = false;
  state.wakeLock?.release?.().catch(() => {});
  state.wakeLock = null;
  renderMicButton();
  updateReadout();
}

async function renderMicList() {
  let inputs = [];
  try { inputs = await Mic.inputs(); } catch { /* listed as default only */ }
  const id = state.micId;
  const opts = [option('', tr('mic.default')), ...inputs.map((d, i) => option(d.deviceId, d.label || tr('mic.n', { n: i + 1 })))];
  if (id && !inputs.some((d) => d.deviceId === id)) opts.push(option(id, tr('mic.notConnected')));
  $('set-mic').replaceChildren(...opts);
  $('set-mic').value = id;
  $('mic-desc').textContent = !inputs.some((d) => d.label) ? tr('mic.namesHint') : mic.running ? tr('mic.inUse', { name: mic.label }) : '';
}

function renderMicButton() {
  $('btn-mic').textContent = tr(mic.running ? 'mic.stop' : 'mic.start');
  $('btn-mic').classList.toggle('primary', !mic.running);
  renderRecButton();
}

async function toggleRecording() {
  if (mic.recording) return finishRecording();
  try {
    await mic.startRecording();
  } catch (e) {
    message(tr('rec.failed', { err: e.message }), 'error');
    return;
  }
  state.recTimer = setInterval(() => (mic.recordedSeconds >= REC_MAX_S ? finishRecording() : renderRecButton()), 250);
  renderRecButton();
}

function finishRecording() {
  clearInterval(state.recTimer);
  const p = (x) => String(x).padStart(2, '0');
  const d = new Date();
  const name = `pianotunah-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.wav`;
  download(mic.stopRecording(), name);
  message(tr('rec.saved', { name }), 'ok');
  renderRecButton();
}

function renderRecButton() {
  const s = mic.recordedSeconds;
  const t = `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const b = $('btn-rec');
  b.textContent = tr(mic.recording ? 'rec.stop' : 'rec.start', { t });
  b.disabled = !mic.running;
  b.classList.toggle('danger', mic.recording);
  $('rec-desc').textContent = mic.running ? tr('rec.desc', { max: REC_MAX_S / 60 }) : tr('rec.needMic');
  Object.assign($('btn-rec-stop'), { hidden: !mic.recording, textContent: `● ${t}`, title: tr('rec.chipTitle') });
}

async function requestWakeLock() {
  try { state.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* optional */ }
}

function processFrame() {
  state.diag.frames++;
  state.frameCol = null;
  analyseFrame();
  state.spec.push(state.frameCol);
  if (state.spec.length > SPEC_COLS) state.spec.shift();
}

function analyseFrame() {
  const buf = mic.read();
  const lvl = rmsDb(buf);
  state.prevLevel = state.level;
  state.level = lvl;
  state.levels.push(lvl);
  if (state.levels.length > 4) state.levels.shift();
  const attack = lvl - Math.min(...state.levels) > 12;
  if (attack && !state.inAttack) state.attacks++; // once per attack, though it shows for a few frames
  state.inAttack = attack;
  if (attack) Object.assign(state, { unison: [], unisonSkip: 0 }); // a new attack
  // Noise floor: follows quickly down, slowly up, and hardly at all while a
  // note is heard, so a long decay is not mistaken for noise.
  const up = state.signal ? 0.02 : 0.15;
  state.noise = lvl < state.noise ? lvl : state.noise + Math.min(up, (lvl - state.noise) * 0.01);
  // The survey waits for an attack so the previous key's decay is not measured.
  if (state.map?.waitAttack) {
    if (lvl - state.prevLevel <= 6) return idle('waiting for attack');
    state.map.waitAttack = false;
  }
  // A note starts 10 dB above the noise and is followed down to 5 dB.
  if (lvl < Math.max(state.noise + (state.signal ? 5 : 10), -72)) return idle('quiet');

  const A = state.analyzer;
  A.load(buf);
  if (state.mode === 'auto') {
    // Keys measured in this pass are also looked for where they were heard,
    // so a key far from its target is not taken for its neighbour.
    const d = A.detectKey(state.T, state.key, top(), heardDevs());
    // The microphone hears the reference tone too; following it would move
    // the key, and the sine with it, to whatever the speaker plays.
    if (!refPlaying()) followDetectedKey(d);
    // Only the current key's own sound gives a reading, not noise between
    // notes or a note halfway between two keys.
    if (d.key !== state.key || d.margin < 2) return idle(d.key !== state.key ? `hears ${kName(d.key)}` : 'unsure');
    state.shift = d.shift;
  } else if (state.map) state.map.heard = A.detectKey(state.T, state.key, top());
  measureCurrent(A);
}

// Switch key when the same candidate wins two frames in a row by at least 3 dB
// over its neighbours; as a note dies out, noise peaks win by less. Right
// after an attack (6 dB up within four frames), one frame with a 10 dB lead
// is enough. Count how long the current key has been a clear winner; only
// then does auto mode save.
function followDetectedKey(d) {
  state.autoFrames = d.score > 8 && d.margin >= 6 && d.key === state.key ? state.autoFrames + 1 : 0;
  if (d.score <= 8) return;
  state.candCount = d.key === state.cand ? state.candCount + 1 : 1;
  state.cand = d.key;
  const attack = state.level - Math.min(...state.levels) > 6;
  const frames = attack && d.margin >= 10 ? 1 : 2;
  if (state.candCount >= frames && d.margin >= 3 && d.key !== state.key) selectKey(d.key, false);
}

function idle(why) {
  state.diag.idle[why] = (state.diag.idle[why] || 0) + 1;
  state.signal = false;
  if (state.map && !state.map.waitAttack && state.map.pitch.length) state.map.lost = true;
  renderMapPanel();
  updateReadout();
}

function measureCurrent(A) {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const target = partialFreq(T.freq[k], T.B[k], n);
  // Auto: around where detection heard the key. Locked key: wide window so
  // that even a badly flat piano is found.
  const auto = state.mode === 'auto';
  const m = A.measure(target * 2 ** ((auto ? state.shift : 0) / 1200), auto ? 50 : 150, 8);
  if (!m) {
    // A key far away has no partial near the target, but detection still hears it.
    if (state.map && !refPlaying()) trackWrongKey(mapping.wrongKey(state.map.heard, k, NaN, NaN, state.run.done));
    return idle('no partial');
  }

  const raw = centsBetween(m.freq, target);
  const ref = refPlaying();
  if (!ref && state.refTainted) state.readings = []; // drop readings of the reference tone
  state.refTainted = ref;
  state.readings.push({ c: raw, hz: m.freq });
  if (!ref) trackBeating(k, raw, m.prom);
  if (state.readings.length > 7) state.readings.shift();
  const last = state.readings.slice(-5);
  const cs = last.map((r) => r.c);
  const sure = !auto || state.autoFrames >= 3;
  state.stable = !ref && sure && last.length >= 4 && Math.max(...cs) - Math.min(...cs) < (k > 70 ? 1.5 : 0.8);
  state.signal = true;
  state.diag.readings++;

  const g = goal(k);
  state.display = median(cs) - g;
  state.measHz = median(last.map((r) => r.hz));
  const center = target * 2 ** (g / 1200); // the beat view is centred on the target including overpull
  state.beatHz = center * (2 ** (state.display / 1200) - 1);
  state.frameCol = { col: A.zoom(center, SPEC_CENTS, SPEC_BINS), c: state.display };
  state.partialDevs = Array.from({ length: 8 }, (_, i) => {
    const fi = partialFreq(T.freq[k], T.B[k], i + 1);
    if (fi > A.sr * 0.45 || fi < 40) return null;
    const mi = i + 1 === n ? m : A.measure(fi, 50, 8);
    return mi ? centsBetween(mi.freq, fi) : null;
  });

  // Strobe: the measured partial and the two octaves above it, each against
  // its own target. The upper ones are searched where the measured partial
  // says they should be and smoothed like the main reading.
  state.strobe = [{ p: n, c: state.display }];
  [2 * n, 4 * n].forEach((p, i) => {
    const fp = partialFreq(T.freq[k], T.B[k], p);
    const mp = fp < A.sr * 0.45 ? A.measure(fp * 2 ** (raw / 1200), 30, 8) : null;
    const rs = state.strobeReadings[i];
    rs.push(mp ? centsBetween(mp.freq, fp) - g : NaN);
    if (rs.length > 5) rs.shift();
    const ok = rs.filter(Number.isFinite);
    state.strobe.push({ p, c: ok.length >= 3 ? median(ok) : NaN });
  });

  // Save the value that is shown. During a survey, collectMapping saves instead.
  if (state.stable && !state.map) {
    const hz = median(last.map((r) => r.hz));
    if (jumpConfirmed(k, n, hz)) recordKey(k, n, hz);
  }

  const f1 = T.freq[k] * 2 ** (raw / 1200);
  if (!ref && state.measureB?.k === k) {
    const r = A.inharmonicity(f1, T.B[k]);
    if (r) state.bReadings.push(r.B);
  }
  if (state.map && !ref) collectMapping(A, k, m.freq, f1, raw);
  if (state.measureB && performance.now() > state.measureB.until) finishMeasureB();
  updateReadout();
}

// Unisons out of tune make the reading swing with the beat. Readings from
// 0.5 s after the attack, while the note is clearly heard and not being
// damped, are fitted with a line so that a slow glide does not count. A swing
// around it of more than 3 cents (4 in the treble) means the note beats; the
// hint stays until a later note on the key is clean.
function trackBeating(k, c, prom) {
  if (prom < 25 || state.level < Math.max(...state.levels) - 12) return;
  if (state.unisonSkip < 6) return void state.unisonSkip++;
  const w = state.unison;
  w.push(c);
  if (w.length > 10) w.shift();
  if (w.length < 8) return;
  const n = w.length;
  const mx = (n - 1) / 2;
  const my = w.reduce((a, b) => a + b, 0) / n;
  let sxy = 0;
  let sxx = 0;
  w.forEach((y, i) => {
    sxy += (i - mx) * (y - my);
    sxx += (i - mx) ** 2;
  });
  const res = w.map((y, i) => y - my - (sxy / sxx) * (i - mx)).sort((a, b) => a - b);
  const swing = res[n - 2] - res[1];
  if (swing > (k > 70 ? 4 : 3)) state.beating = true;
  else if (w.length === 10 && swing < 1.5) state.beating = false;
}

function resetBeating() {
  Object.assign(state, { unison: [], unisonSkip: 0, beating: false });
}

// A reading more than 50 cents from the key's last one is saved only when a
// new attack gives it again (within 10 cents). Another note still ringing or
// a neighbour struck by mistake was saved as A4 at −94 cents. Tuning moves
// the reading in smaller steps between strikes, so it is not held up.
const JUMP = 50;
function jumpConfirmed(k, n, hz) {
  const rec = state.tuning.keys[k];
  if (!rec?.hz || rec.n !== n || Math.abs(centsBetween(hz, rec.hz)) <= JUMP) {
    state.jump = null;
    return true;
  }
  const j = state.jump;
  const same = j && j.k === k && Math.abs(centsBetween(hz, j.hz)) < 10;
  if (same && state.attacks > j.attack) {
    state.jump = null;
    return true;
  }
  if (!same) {
    state.jump = { k, hz, attack: state.attacks };
    const c = fmtC(centsBetween(hz, rec.hz), 0);
    diag(`not saved: ${kName(k)} ${c} cents from its last reading, waiting for a new attack`);
    message(tr('msg.jump', { name: kName(k), c }), 'warn', 5000);
  }
  return false;
}

function recordKey(k, n, hz) {
  const rec = state.tuning.keys[k] || {};
  if (!rec.bhz) Object.assign(rec, { bhz: hz, bn: n }); // first measurement in the pass
  Object.assign(rec, { hz, n, at: Date.now() });
  state.tuning.keys[k] = rec;
  if (k !== state.diag.savedKey || Date.now() - state.diag.savedAt > 2000) {
    diag(`saved ${kName(k)} ${fmtC(centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n)))} cents`);
    Object.assign(state.diag, { savedKey: k, savedAt: Date.now() });
  }
  markDirty();
  renderKeyStatus();
}

function storeB(k, B) {
  diag(`B ${kName(k)} = ${fmtB(B)}`);
  state.tuning.inharmonicity[k] = Number(B.toPrecision(4));
  markDirty();
  recompute();
}

function finishMeasureB() {
  const k = state.measureB.k;
  state.measureB = null;
  $('btn-measure-b').disabled = false;
  if (state.bReadings.length >= 3) {
    const B = median(state.bReadings);
    storeB(k, B);
    if (state.bBad.has(k)) message(tr('msg.bOutlier', { name: kName(k), b: fmtB(B) }), 'warn', 0);
    else message(tr('msg.bMeasured', { name: kName(k), b: fmtB(B) }), 'ok');
  } else {
    message(tr('msg.bFailed'), 'warn');
  }
  state.bReadings = [];
}

function flashKey(k) {
  const el = $('keyboard').children[k - 1];
  el.classList.remove('flash');
  void el.offsetWidth; // restart the animation
  el.classList.add('flash');
}

// ---------------------------------------------------------------------------
// Survey

const isMapped = (k) => !!keyRec(k)?.mapped;
const isQuick = () => state.mapPlan === 'quick';
const needsB = (k) => isQuick() || !state.tuning.inharmonicity[k]; // the quick survey always remeasures B
const planKeys = () => mapping.planKeys(state.mapPlan, top());
const newRun = () => mapping.newRun(state.mapPlan, top(), isMapped);
const nextPending = (k) => mapping.nextPending(state.run, state.mapPlan, top(), k);

function setMapPlan(p) {
  state.mapPlan = p;
  try { localStorage.setItem(LS.plan, p); } catch { /* optional */ }
  document.querySelectorAll('[data-plan]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.plan === p));
  if (!state.map) return;
  state.map = mapping.newKeyState();
  state.run = newRun();
  selectKey(nextPending(0), false);
  renderKeyboard();
  renderMapPanel();
}

// Nothing from another key is kept; the hint shows after a few frames in a row.
function trackWrongKey(other) {
  const mp = state.map;
  mp.wrongFrames = other ? mp.wrongFrames + 1 : 0;
  mp.wrong = mp.wrongFrames >= 3 ? other : 0;
  // Drop what was collected: the start of a wrong note can look right.
  if (other) Object.assign(mp, { pitch: [], bs: [], ms: 0 });
  return other;
}

function collectMapping(A, k, partialHz, f1, raw) {
  const mp = state.map;
  if (trackWrongKey(mapping.wrongKey(mp.heard, k, raw, median(state.run.offsets), state.run.done))) return renderMapPanel();
  mp.pitch.push(partialHz);
  mp.ms += FRAME_MS;
  mp.lost = false;
  if (needsB(k) && mp.bs.length < mapping.B_READINGS) {
    const r = A.inharmonicity(f1, state.T.B[k]);
    if (r) mp.bs.push(r.B);
  }
  if (!mapping.keyDone(mp, needsB(k), state.mapPlan)) return renderMapPanel();

  const hz = median(mp.pitch);
  const n = partialOf(k);
  state.run.offsets.push(centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n)));
  state.tuning.keys[k] = { ...keyRec(k), bhz: hz, bn: n, hz, n, at: Date.now(), mapped: true };
  if (mp.bs.length >= 3) storeB(k, median(mp.bs));
  else {
    markDirty();
    recompute();
  }
  flashKey(k);
  state.run.done.add(k);
  advanceMapping(k);
}

function skipMapping() {
  state.run.skipped.add(state.key);
  advanceMapping(state.key);
}

function advanceMapping(k) {
  const next = nextPending(k);
  if (next) selectKey(next, false);
  else finishMapping();
}

function finishMapping() {
  const withB = (ks) => ks.filter((k) => state.tuning.inharmonicity[k]).length;
  const all = Array.from({ length: top() }, (_, i) => i + 1);
  const skipped = [...state.run.skipped].sort((a, b) => a - b);
  const text =
    (isQuick()
      ? tr('map.doneQuick', { b: withB(planKeys()), n: planKeys().length })
      : tr('map.doneFull', { n: all.filter(isMapped).length, b: withB(all) })) +
    (!skipped.length ? '' : skipped.length <= 8 ? tr('map.skipped', { keys: skipped.map(kName).join(', ') }) : tr('map.skippedMany', { n: skipped.length })) +
    (state.bBad.size ? tr('map.bOutliers', { keys: [...state.bBad].sort((a, b) => a - b).map(kName).join(', ') }) : '');
  setMode('lock');
  selectKey(A4, false); // tuning starts in the temperament octave
  message(text, 'ok', 0);
}

function renderMapPanel() {
  if (!state.map) return;
  const mp = state.map;
  const name = kName(state.key);
  const ks = planKeys();
  const done = ks.filter((k) => mapping.handled(state.run, k)).length;
  $('map-progress').textContent = tr(isQuick() ? 'map.progressQuick' : 'map.progressFull', { done, total: ks.length });
  $('map-bar').style.width = `${(done / ks.length) * 100}%`;
  $('map-step').textContent = mp.wrong
    ? mp.wrong > 0 ? tr('map.wrong', { heard: kName(mp.wrong), name }) : tr('map.offPitch', { name, c: mapping.OFFSET_LIMIT })
    : tr(mp.waitAttack ? 'map.strike' : mp.lost ? 'map.lost' : 'map.listening', { name });
  const p = Math.min(mp.pitch.length, mapping.PITCH_READINGS);
  setCheck('map-chk-pitch', tr('map.pitch', { p, n: mapping.PITCH_READINGS }), p >= mapping.PITCH_READINGS);
  if (!needsB(state.key)) setCheck('map-chk-b', tr('map.bKnown'), true);
  else if (mapping.bGivenUp(mp, state.mapPlan)) setCheck('map-chk-b', tr('map.bSkipped'), true);
  else setCheck('map-chk-b', tr('map.b', { p: Math.min(mp.bs.length, mapping.B_READINGS), n: mapping.B_READINGS }), mp.bs.length >= mapping.B_READINGS);
}

function setCheck(id, text, done) {
  $(id).textContent = text;
  $(id).dataset.done = done ? '1' : '0';
}

// ---------------------------------------------------------------------------
// Reference tones

const goalF1 = (k) => state.T.freq[k] * 2 ** (goal(k) / 1200);
const sineFreq = () => partialFreq(goalF1(state.key), state.T.B[state.key], partialOf(state.key));

function playPiano() {
  diag(`piano tone ${kName(state.key)}`);
  const ms = tones.pluck(goalF1(state.key), state.T.B[state.key]);
  state.refUntil = Math.max(state.refUntil, performance.now() + ms + 800); // + the analysis buffer
}

function startSine() {
  if (!tones.sineOn && mic.running) message(tr('msg.sineNoSave'), 'info', 4000);
  diag(`sine ${kName(state.key)} partial ${partialOf(state.key)}, ${fmtHz(sineFreq())}`);
  tones.startSine(sineFreq());
  renderToneButton();
}

function stopSine() {
  if (!tones.sineOn) return;
  diag('sine off');
  tones.stopSine();
  state.refUntil = performance.now() + 800;
  renderToneButton();
}

function playCurrent() {
  if (state.toneMode === 'off') return;
  if (state.toneMode === 'piano') playPiano();
  else if (tones.sineOn) stopSine();
  else startSine();
}

function setToneMode(m) {
  state.toneMode = m;
  if (m !== 'sine') stopSine();
  document.querySelectorAll('[data-tone]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.tone === m));
  try { localStorage.setItem(LS.tone, m); } catch { /* optional */ }
  renderToneButton();
}

// The sine sounds at the measured partial, in the bass and tenor an octave or
// more above the key, so the button names the note it plays.
function renderToneButton() {
  const b = $('btn-tone');
  const n = partialOf(state.key);
  const note = kName(Math.min(KEY_COUNT, state.key + Math.round(12 * Math.log2(n))));
  const what = n > 1 ? tr('tone.partialNote', { note, n }) : note;
  b.textContent = tr(tones.sineOn ? 'tone.stopSine' : state.toneMode === 'sine' ? 'tone.playSine' : 'tone.play', { what });
  b.setAttribute('aria-pressed', tones.sineOn);
  b.hidden = state.toneMode === 'off';
}

// ---------------------------------------------------------------------------
// Readout and animation

function updateReadout() {
  let text;
  let s = 'idle';
  if (!mic.running) text = tr('status.start');
  else if (!state.signal) text = state.map?.waitAttack ? tr('status.strike', { name: kName(state.key) }) : tr('status.listening');
  else {
    s = statusClass(state.display);
    text = tr(refPlaying() ? 'status.ref' : s === 'good' ? 'status.good' : state.display > 0 ? 'status.high' : 'status.low');
  }
  $('status').dataset.s = $('hub').dataset.s = s;
  $('status').textContent = text;
  $('cents-num').textContent = mic.running ? fmtC(state.display) : '–';
  $('cents').dataset.live = state.signal ? '1' : '0';
  const n = partialOf(state.key);
  const hz = mic.running && Number.isFinite(state.measHz) ? fmtHz(state.measHz) : '–';
  $('measured').replaceChildren(...trNodes(n > 1 ? 'measured.partial' : 'measured', { n, hz }));
  $('measured').dataset.live = state.signal ? '1' : '0';
  const hint = $('unison-hint');
  hint.hidden = !(mic.running && state.beating);
  if (!hint.hidden) hint.textContent = tr('unison.hint');
  $('level-bar').style.width = `${Math.max(0, Math.min(100, (state.level + 80) * 1.4))}%`;
  renderPartials();
}

function renderPartials() {
  if ($('partials-row').hidden) return;
  const box = $('partials');
  if (box.children.length !== 8) {
    box.replaceChildren(
      ...Array.from({ length: 8 }, (_, i) => {
        const d = Object.assign(document.createElement('div'), { className: 'pcell' });
        d.append(Object.assign(document.createElement('span'), { className: 'pn', textContent: i + 1 }), Object.assign(document.createElement('span'), { className: 'pv' }));
        return d;
      }),
    );
  }
  const n = partialOf(state.key);
  [...box.children].forEach((cell, i) => {
    const d = state.signal ? state.partialDevs[i] : null;
    cell.classList.toggle('sel', i + 1 === n);
    cell.lastChild.textContent = d == null ? '–' : fmtC(d);
    cell.dataset.s = d == null ? 'none' : statusClass(d);
  });
}

function animate(t) {
  const dt = state.lastAnim ? Math.min(0.1, (t - state.lastAnim) / 1000) : 0;
  state.lastAnim = t;
  if (state.tuning) {
    const C = state.colors;
    const tol = tolerance();
    const live = state.signal && Number.isFinite(state.display);
    drawDial($('dial'), { display: state.display, signal: state.signal, bands: state.strobe, live, tol }, C, dt, state.ringPhase);
    const beatLive = live && Number.isFinite(state.beatHz);
    if (!$('beats-row').hidden) {
      drawSpectro($('spectro'), state.spec, { capacity: SPEC_COLS, bins: SPEC_BINS, cents: SPEC_CENTS, tol }, C);
      state.beatPhase = drawBeat($('beat'), { beatHz: state.beatHz, display: state.display, live: beatLive, tol }, C, dt, state.beatPhase);
    }
    const df = Math.abs(state.beatHz);
    const rate = !beatLive ? '–' : df < 0.1 ? tr('beat.none') : tr('beat.rate', { n: num(df, df < 10 ? 1 : 0) });
    if ($('beat-rate').textContent !== rate) $('beat-rate').textContent = rate;
  }
  requestAnimationFrame(animate);
}

// ---------------------------------------------------------------------------
// Actions

function setSetting(key, value) {
  S()[key] = value;
  recompute();
  renderSettingDescs();
  markDirty();
}

function setRef(hz) {
  if (!Number.isFinite(hz)) return;
  setSetting('refA4', Math.round(Math.max(380, Math.min(480, hz)) * 10) / 10);
}

// Set the reference so the middle of the piano is on target: median of the
// before values in the middle, otherwise the key sounding now.
function fitRefToPiano() {
  const mid = midBefore();
  let shift;
  if (mid.length >= 3) shift = median(mid);
  else if (state.signal && Number.isFinite(state.display)) shift = state.display + goal(state.key);
  else return message(tr('msg.fitNeedsInput'), 'warn');
  setRef(Number(S().refA4) * 2 ** (shift / 1200));
  message(tr('msg.fitDone', { hz: fmtHz(Number(S().refA4), 1) }), 'ok');
}

// End the pass: save a summary to the history and clear the measurements.
// Inharmonicity and settings are kept.
function newPass() {
  const t = state.tuning;
  const ks = Array.from({ length: top() }, (_, i) => i + 1);
  const after = ks.map(statusDev).filter(Number.isFinite);
  const before = ks.map(beforeDev).filter(Number.isFinite);
  const meanAbs = (a) => (a.length ? a.reduce((s, x) => s + Math.abs(x), 0) / a.length : 0);
  if (after.length) {
    t.history = [
      ...t.history,
      { startedAt: t.passStartedAt, endedAt: new Date().toISOString(), refA4: Number(S().refA4), measured: after.length, meanAbsBefore: meanAbs(before), meanAbsAfter: meanAbs(after) },
    ].slice(-30);
  }
  t.keys = {};
  t.passStartedAt = new Date().toISOString();
  resetReadings();
  recompute();
  markDirty();
  message(tr('msg.newPass'), 'ok');
}

function exportTuning() {
  const blob = new Blob([JSON.stringify(state.tuning, null, 2)], { type: 'application/json' });
  download(blob, (state.tuning.name || tr('name.file')).replace(/[^\p{L}\p{N}_-]+/gu, '_') + '.json');
}

function download(blob, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

async function importTuning(file) {
  try {
    const data = JSON.parse(await file.text());
    if (!data?.settings) throw new Error(tr('msg.importNoSettings'));
    const exists = state.list.some((x) => x.id === data.id);
    const name = data.name || tr('name.imported');
    const t = duplicateTuning(data, exists ? tr('name.import', { name }) : name);
    await createAndOpen(t);
    message(tr('msg.imported', { name: t.name }), 'ok');
  } catch (e) {
    message(tr('msg.importFailed', { err: e.message }), 'error');
  }
}

async function deleteCurrent() {
  try {
    await saver.discard(); // a save in progress must not recreate the file
    await deleteTuning(state.tuning.id);
    await refreshList();
    if (state.list[0]) await openTuning(await getTuning(state.list[0].id));
    else await createAndOpen(newTuning(tr('name.default')));
    message(tr('msg.deleted'), 'ok');
  } catch {
    message(tr('msg.deleteFailed'), 'error');
  }
}

// Color mode: auto follows the browser. theme.js in <head> applies the saved
// choice before the page is drawn.
const currentTheme = () => document.documentElement.dataset.theme || 'auto';

function setTheme(t) {
  if (t === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  try {
    if (t === 'auto') localStorage.removeItem(LS.theme);
    else localStorage.setItem(LS.theme, t);
  } catch { /* optional */ }
  renderThemeButton();
  refreshColors();
}

function renderThemeButton() {
  const th = currentTheme();
  const desc = tr(`theme.${th}.desc`);
  Object.assign($('btn-theme'), { textContent: tr('theme.' + th), title: tr('theme.title', { desc }) });
  $('btn-theme').setAttribute('aria-label', tr('theme.aria', { desc }));
}

// Redraw everything that shows text.
function changeLanguage(l) {
  setLang(l);
  buildStaticUi();
  $('message').hidden = true;
  setSaveState($('save-status').dataset.state);
  renderSettings();
  recompute();
  renderMapPanel();
  renderToneButton();
  renderThemeButton();
  renderMicButton();
  updateReadout();
}

function refreshColors() {
  state.colors = readColors();
  renderKeyboard();
  renderChart();
}

// ---------------------------------------------------------------------------
// Settings drawer

function openDrawer(tab) {
  $('drawer').hidden = $('drawer-backdrop').hidden = false;
  document.body.classList.add('drawer-open');
  $('btn-settings').setAttribute('aria-expanded', 'true');
  let last = 'piano';
  try { last = localStorage.getItem(LS.tab) || last; } catch { /* optional */ }
  showTab(tab || last);
  $('drawer-close').focus();
}

function closeDrawer() {
  $('drawer').hidden = $('drawer-backdrop').hidden = true;
  document.body.classList.remove('drawer-open');
  $('btn-settings').setAttribute('aria-expanded', 'false');
  $('btn-settings').focus();
}

function showTab(tab) {
  if (!document.querySelector(`[data-panel="${tab}"]`)) tab = 'piano';
  document.querySelectorAll('[data-tab]').forEach((b) => b.setAttribute('aria-selected', b.dataset.tab === tab));
  document.querySelectorAll('[data-panel]').forEach((p) => (p.hidden = p.dataset.panel !== tab));
  try { localStorage.setItem(LS.tab, tab); } catch { /* optional */ }
}

// ---------------------------------------------------------------------------
// Events

function bindEvents() {
  const on = (id, ev, fn) => $(id).addEventListener(ev, fn);
  const onAll = (sel, fn) => document.querySelectorAll(sel).forEach((el) => el.addEventListener('click', () => fn(el)));
  const show = (id, v) => () => ($(id).hidden = !v);

  // Top
  on('set-lang', 'input', (e) => changeLanguage(e.target.value));
  on('btn-theme', 'click', () => {
    const order = ['auto', 'light', 'dark'];
    setTheme(order[(order.indexOf(currentTheme()) + 1) % order.length]);
  });
  on('message-close', 'click', show('message', false));
  // Back to the start without reloading, which would stop the microphone.
  on('brand', 'click', (e) => {
    e.preventDefault();
    if (!$('drawer').hidden) closeDrawer();
    window.scrollTo({ top: 0, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  });
  on('btn-settings', 'click', () => ($('drawer').hidden ? openDrawer() : closeDrawer()));
  on('drawer-close', 'click', closeDrawer);
  on('drawer-backdrop', 'click', closeDrawer);
  on('btn-ref-chip', 'click', () => openDrawer('tuning'));
  onAll('[data-tab]', (b) => showTab(b.dataset.tab));
  on('btn-mic', 'click', () => (mic.running ? stopMic() : startMic()));
  on('btn-rec', 'click', toggleRecording);
  on('btn-rec-stop', 'click', finishRecording);

  // Tuner
  on('btn-prev', 'click', () => selectKey(state.key - 1));
  on('btn-next', 'click', () => selectKey(state.key + 1));
  on('mode-auto', 'click', () => setMode('auto'));
  on('mode-lock', 'click', () => setMode('lock'));
  const startSurvey = () => {
    if (state.mode === 'map') return;
    setMode('map');
    if (!mic.running) startMic();
  };
  on('mode-map', 'click', startSurvey);
  on('btn-curve-map', 'click', () => {
    setMapPlan('quick');
    startSurvey();
  });
  on('map-skip', 'click', skipMapping);
  on('map-redo', 'click', () => {
    state.map = mapping.newKeyState();
    renderMapPanel();
  });
  on('map-stop', 'click', () => setMode('lock'));
  onAll('[data-plan]', (b) => setMapPlan(b.dataset.plan));

  on('keyboard', 'click', (e) => {
    const k = Number(e.target.closest('.key')?.dataset.k);
    if (!k) return;
    const prev = state.key;
    selectKey(k);
    if (state.toneMode === 'piano') playPiano();
    else if (state.toneMode === 'sine') (tones.sineOn && k === prev ? stopSine : startSine)();
  });
  onAll('[data-tone]', (b) => setToneMode(b.dataset.tone));
  on('btn-tone', 'click', playCurrent);

  const setPartial = (d) => {
    const k = state.key;
    const n = Math.max(1, Math.min(8, partialOf(k) + d));
    if (n === defaultPartial(k)) delete state.tuning.partials[k];
    else state.tuning.partials[k] = n;
    resetReadings();
    renderKeyInfo();
    markDirty();
  };
  on('partial-dec', 'click', () => setPartial(-1));
  on('partial-inc', 'click', () => setPartial(1));
  on('btn-measure-b', 'click', () => {
    if (!mic.running) return message(tr('msg.micFirst'), 'warn');
    state.bReadings = [];
    state.measureB = { k: state.key, until: performance.now() + 4000 };
    $('btn-measure-b').disabled = true;
    message(tr('msg.strikeB', { name: kName(state.key) }), 'info', 4000);
    setTimeout(() => state.measureB && finishMeasureB(), 6000); // in case the note dies away first
  });

  // Reference
  on('set-ref', 'change', (e) => setRef(parseFloat(e.target.value.replace(',', '.'))));
  onAll('[data-ref]', (b) => setRef(Number(S().refA4) + Number(b.dataset.ref)));
  onAll('[data-hz]', (b) => setRef(Number(b.dataset.hz)));
  on('btn-fit-ref', 'click', fitRefToPiano);
  on('btn-overpull', 'click', () => setSetting('overpull', Number($('btn-overpull').dataset.p)));

  // Settings
  const bindSetting = (id, key, conv = (v) => v) => on(id, 'input', (e) => setSetting(key, conv(e.target.value)));
  on('set-kind', 'input', (e) => {
    S().sizeCm = PIANO_KINDS[e.target.value].def; // an upright's height is no sensible grand length
    $('set-size').value = S().sizeCm;
    setSetting('pianoKind', e.target.value);
  });
  on('set-size', 'change', (e) => {
    const k = PIANO_KINDS[S().pianoKind];
    const cm = Math.round(Math.max(k.min, Math.min(k.max, Number(e.target.value) || k.def)));
    e.target.value = cm;
    setSetting('sizeCm', cm);
  });
  on('set-keys', 'input', (e) => {
    setSetting('keyCount', Number(e.target.value));
    applyKeyCount();
  });
  bindSetting('set-temperament', 'temperament');
  bindSetting('set-root', 'root', Number);
  bindSetting('set-stretch', 'stretch');
  bindSetting('set-bass', 'bassOctave');
  bindSetting('set-mid', 'midOctave');
  bindSetting('set-treble', 'trebleOctave');
  bindSetting('set-extra-treble', 'extraTreble', Number);
  bindSetting('set-extra-bass', 'extraBass', Number);
  bindSetting('set-overpull', 'overpull', Number);
  bindSetting('set-tolerance', 'tolerance', Number);
  on('set-name', 'input', (e) => {
    state.tuning.name = e.target.value.trim() || tr('name.untitled');
    const item = state.list.find((t) => t.id === state.tuning.id);
    if (item) item.name = state.tuning.name;
    renderTuningSelect();
    markDirty();
  });
  on('set-notes', 'input', (e) => {
    state.tuning.notes = e.target.value;
    markDirty();
  });

  // Saved tunings
  on('tuning-select', 'change', async (e) => {
    try {
      await openTuning(await getTuning(e.target.value));
    } catch {
      message(tr('msg.openFailed'), 'error');
      renderTuningSelect();
    }
  });
  on('btn-new', 'click', () => createAndOpen(newTuning(tr('name.new', { n: state.list.length + 1 }))).catch(() => message(tr('msg.createFailed'), 'error')));
  on('btn-dup', 'click', async () => {
    await saver.flush();
    createAndOpen(duplicateTuning(state.tuning, tr('name.copy', { name: state.tuning.name }))).catch(() => message(tr('msg.dupFailed'), 'error'));
  });
  on('btn-del', 'click', () => {
    $('confirm-del-text').textContent = tr('piano.confirmDel', { name: state.tuning.name });
    $('confirm-del').hidden = false;
  });
  on('confirm-del-no', 'click', show('confirm-del', false));
  on('confirm-del-yes', 'click', () => {
    $('confirm-del').hidden = true;
    deleteCurrent();
  });

  // Pass
  on('btn-new-pass', 'click', show('confirm-pass', true));
  on('confirm-pass-no', 'click', show('confirm-pass', false));
  on('confirm-pass-yes', 'click', () => {
    $('confirm-pass').hidden = true;
    newPass();
  });
  on('btn-export', 'click', exportTuning);
  on('file-import', 'change', (e) => {
    const f = e.target.files[0];
    e.target.value = '';
    if (f) importTuning(f);
  });

  // Chart
  on('minichart', 'pointermove', chartHover);
  on('minichart', 'pointerleave', show('minitip', false));
  on('minichart', 'click', (e) => chartKeyAt(e) && selectKey(chartKeyAt(e)));
  on('table-details', 'toggle', () => $('table-details').open && renderTable());
  on('set-mic', 'change', async () => {
    state.micId = $('set-mic').value;
    try { localStorage.setItem(LS.mic, state.micId); } catch { /* optional */ }
    if (mic.running) {
      stopMic();
      await startMic();
    }
  });
  navigator.mediaDevices?.addEventListener?.('devicechange', () => {
    diag('audio devices changed');
    renderMicList();
  });
  window.addEventListener('error', (e) => diag(`error: ${e.message} (${e.filename?.split('/').pop()}:${e.lineno})`));
  window.addEventListener('unhandledrejection', (e) => diag(`error: ${e.reason?.message || e.reason}`));
  on('curve-toggle', 'click', () => {
    const open = $('curve-row').hidden;
    setCurveOpen(open);
    try { localStorage.setItem(LS.curve, open ? 'open' : 'closed'); } catch { /* optional */ }
  });
  for (const name of ['beats', 'partials']) {
    on(name + '-toggle', 'click', () => {
      const open = $(name + '-row').hidden;
      setFoldOpen(name, open);
      try { localStorage.setItem(LS[name], open ? 'open' : 'closed'); } catch { /* optional */ }
    });
  }

  // Keyboard shortcuts
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$('drawer').hidden) return closeDrawer();
    if (e.target.closest('input, select, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
    const action = {
      ArrowLeft: () => selectKey(state.key - 1),
      ArrowRight: () => selectKey(state.key + 1),
      l: () => setMode('lock'),
      a: () => setMode('auto'),
      t: playCurrent,
      s: () => ($('drawer').hidden ? openDrawer() : closeDrawer()),
    }[e.key.length === 1 ? e.key.toLowerCase() : e.key];
    if (!action) return;
    action();
    e.preventDefault();
  });

  // Window
  window.addEventListener('resize', () => {
    renderKeyboard();
    renderChart();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refreshColors);
  document.addEventListener('visibilitychange', () => {
    diag(`page ${document.visibilityState}`);
    if (document.visibilityState === 'visible') checkVersion();
    if (document.visibilityState === 'hidden') saver.flush();
    else if (mic.running) {
      mic.resume();
      if (!state.wakeLock || state.wakeLock.released) requestWakeLock(); // released by the browser when the page was hidden
    }
  });
  // Last chance to save when the tab closes.
  window.addEventListener('pagehide', () => {
    if (!saver.dirty || !state.tuning) return;
    navigator.sendBeacon?.(
      'api/tunings/' + encodeURIComponent(state.tuning.id),
      new Blob([JSON.stringify(state.tuning)], { type: 'application/json' }),
    );
  });
}

// ---------------------------------------------------------------------------
// Start

async function boot() {
  try { state.micId = localStorage.getItem(LS.mic) || ''; } catch { /* optional */ }
  buildStaticUi();
  state.colors = readColors();
  try {
    await refreshList();
    let id = null;
    try { id = localStorage.getItem(LS.tuning); } catch { /* optional */ }
    const pick = state.list.find((t) => t.id === id) || state.list[0];
    if (pick) await openTuning(await getTuning(pick.id));
    else await createAndOpen(newTuning(tr('name.default')));
  } catch {
    // Server unreachable: run anyway, without saving.
    state.tuning = newTuning(tr('name.default'));
    recompute();
    renderSettings();
    setSaveState('error');
    message(tr('msg.noServer'), 'warn', 0, 'server');
  }
  bindEvents();
  renderThemeButton();
  renderMicButton();
  let plan = 'quick';
  let tone = 'off';
  try {
    plan = localStorage.getItem(LS.plan) === 'full' ? 'full' : 'quick';
    tone = localStorage.getItem(LS.tone) || 'off';
    if (localStorage.getItem(LS.curve) === 'closed') setCurveOpen(false);
    for (const name of ['beats', 'partials']) if (localStorage.getItem(LS[name]) === 'open') setFoldOpen(name, true);
  } catch { /* optional */ }
  setMapPlan(plan);
  setToneMode(tone);
  fetch('api/version')
    .then((r) => r.json())
    .then(({ version, debug }) => {
      state.version = version;
      if (debug) {
        enableDiag();
        diag(`page loaded: ${navigator.userAgent}`);
        setInterval(diagStatus, 5000);
      }
      setInterval(checkVersion, 30 * 60 * 1000);
      $('app-version').textContent = version;
      if (/^v\d/.test(version)) $('app-version').href += '/tag/' + version;
    })
    .catch(() => {});
  updateReadout();
  requestAnimationFrame(animate);
}

boot();
