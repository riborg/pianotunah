// Piano Tunah: state, DOM and events. Calculations live in theory.js and
// dsp.js, drawing in draw.js, audio in mic.js/tone.js, saving in saver.js.

import {
  KEY_COUNT, A4, TEMPERAMENTS, PIANO_KINDS, STRETCH_PRESETS, OCTAVE_TYPES, sizeClass,
  computeTargets, recommendedOverpull, defaultPartial, partialFreq, centsBetween, noteName, pcName, pitchClass, isBlack,
} from './theory.js';
import { Analyzer, rmsDb, median } from './dsp.js';
import { listTunings, getTuning, saveTuning, deleteTuning, newTuning, normalize, duplicateTuning } from './store.js';
import { num, short, fmtC, fmtHz, fmtB } from './format.js';
import { tr, lang, locale, setLang, translateDom } from './i18n.js';
import { Mic } from './mic.js';
import { TonePlayer } from './tone.js';
import { Saver } from './saver.js';
import { readColors, drawMeter, drawStrobe, drawSpectro, drawBeat, drawChart, drawDeviations } from './draw.js';
import * as mapping from './mapping.js';

const $ = (id) => document.getElementById(id);

const FRAME_MS = 90; // analysis interval
const SPEC_COLS = 100; // spectrogram history, ≈ 9 s
const SPEC_BINS = 48;
const SPEC_CENTS = 30;
const LS = { tuning: 'pianotunah.lastTuning', tone: 'pianotunah.toneMode', theme: 'pianotunah.theme', plan: 'pianotunah.mapPlan', tab: 'pianotunah.tab', curve: 'pianotunah.curve', mic: 'pianotunah.mic' };

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
  bReadings: [],
  measureB: null, // { k, until } during manual B measurement
  map: null, // survey of the current key, see mapping.newKeyState
  run: null, // the survey as a whole, see mapping.newRun
  mapPlan: 'quick',
  toneMode: 'off', // off | piano | sine
  refUntil: 0, // reference tone audible in the microphone until this time
  refTainted: false,
  wakeLock: null,
  strobePhase: [0, 0, 0],
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
const bSource = (k) => tr(state.tuning.inharmonicity[k] ? 'b.measured' : 'b.model');
const fmtDate = (d) => d.toLocaleDateString(locale(), { dateStyle: 'medium' });

// Measurements are stored as the frequency of the measured partial, so they
// stay valid when reference, temperament, stretch or B change.
const keyRec = (k) => state.tuning.keys[k];
const devOf = (k, hz, n) => (hz && n ? centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n)) : NaN);
const curDev = (k) => devOf(k, keyRec(k)?.hz, keyRec(k)?.n);
const beforeDev = (k) => devOf(k, keyRec(k)?.bhz, keyRec(k)?.bn);

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
function message(text, kind = 'info', ms = 6000, tag = '') {
  const el = $('message');
  $('message-text').textContent = text;
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
  renderKeyboard.scrolledTo = 0;
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

function renderKeyInfo() {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const g = goal(k);
  $('note-name').textContent = kName(k);
  $('note-sub').textContent = tr('key.sub', { k, c: fmtC(T.cents[k]) });
  $('targetline').textContent =
    tr('target.fund', { hz: fmtHz(T.freq[k]) }) +
    (n > 1 ? tr('target.partial', { n, hz: fmtHz(partialFreq(T.freq[k], T.B[k], n)) }) : '') +
    (g ? tr('target.overpull', { c: fmtC(g) }) : '');
  $('partial-val').textContent = n;
  $('bval').textContent = tr('measure.bval', { b: fmtB(T.B[k]), src: bSource(k) });
  if (tones.sineOn) tones.setSine(sineFreq());
}

function renderKeyboard() {
  buildKeyboard(top());
  const cur = Math.min(state.key, top());
  const quickPlan = state.map && state.mapPlan === 'quick';
  for (const el of $('keyboard').children) {
    const k = Number(el.dataset.k);
    const label = tr('key.label', { name: kName(k), dev: Number.isFinite(curDev(k)) ? fmtC(statusDev(k)) + ' ' + tr('unit.cents') : tr('key.unmeasured') });
    el.dataset.s = statusClass(statusDev(k));
    el.classList.toggle('current', k === cur);
    el.classList.toggle('has-b', !!state.tuning.inharmonicity[k]);
    el.classList.toggle('plan', !!quickPlan && mapping.QUICK_KEYS.includes(k));
    if (el.firstChild) el.firstChild.textContent = pitchClass(k) === 0 || k === 1 ? kName(k) : '';
    el.setAttribute('aria-label', label);
    el.setAttribute('aria-current', k === cur);
    el.title = label;
  }
  const curEl = $('keyboard').children[cur - 1];
  renderDeviations(curEl);
  const marker = $('kb-marker');
  marker.style.left = `calc(10px + (100% - 20px) * ${Number(curEl.dataset.cx) / 100})`;
  marker.dataset.s = statusClass(statusDev(cur));
  $('kb-marker-name').textContent = kName(cur);
  // Scroll the current key into view on narrow screens, but only when it
  // changes, so the user can scroll freely between measurements.
  const sc = $('kb-scroll');
  if (cur !== renderKeyboard.scrolledTo && sc.scrollWidth > sc.clientWidth) {
    renderKeyboard.scrolledTo = cur;
    const x = (Number(curEl.dataset.cx) / 100) * sc.scrollWidth - sc.clientWidth / 2;
    sc.scrollTo({ left: x, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }
}

// The strip under the keyboard: measured deviation from target per key.
function renderDeviations(curEl) {
  const keys = [...$('keyboard').children];
  const whites = keys.filter((el) => el.classList.contains('white')).length;
  const bars = [];
  for (const el of keys) {
    const d = statusDev(Number(el.dataset.k));
    if (Number.isFinite(d)) bars.push({ x: el.dataset.cx / 100, d });
  }
  const range = drawDeviations($('devstrip'), { bars, current: curEl.dataset.cx / 100, barW: 0.55 / whites, tol: tolerance() }, state.colors);
  $('dev-legend').textContent = tr('legend.dev', { n: range });
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
      fmtB(T.B[k]) + (state.tuning.inharmonicity[k] ? ' *' : ''), partialOf(k), fmtC(beforeDev(k)), fmtC(statusDev(k)),
    ];
    for (const c of cells) row.append(Object.assign(document.createElement('td'), { textContent: c }));
    row.lastChild.dataset.s = statusClass(statusDev(k));
    if (k === state.key) row.className = 'current';
    body.append(row);
  }
  $('ktable').replaceChildren(head, body);
}

// The curve is drawn on the main page and, when that tab is open, in settings.
const TIPS = { minichart: 'minitip', chart: 'tooltip' };

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
  // The main page copy uses the keyboard's key positions as its x axis.
  const xs = [0, ...[...$('keyboard').children].map((el) => el.dataset.cx / 100)];
  state.chartGeo = {};
  for (const id in TIPS) {
    const data = { top: top(), target: T.cents, points, ticks, current: state.key, xs: id === 'minichart' ? xs : null, labelX: $('kb-scroll').scrollLeft };
    if ($(id).clientWidth) state.chartGeo[id] = drawChart($(id), data, state.colors);
  }
}

function setCurveOpen(open) {
  $('curve-row').hidden = !open;
  document.querySelector('.lg-curve').hidden = !open;
  $('curve-toggle').setAttribute('aria-expanded', open);
  if (open) renderChart(); // not drawn while folded
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
  const k = state.chartGeo?.[c.id]?.keyAt(e.clientX - c.getBoundingClientRect().left);
  return k >= 1 && k <= top() ? k : 0;
}

function chartHover(e) {
  const k = chartKeyAt(e);
  const c = e.currentTarget;
  const geo = state.chartGeo[c.id];
  const tip = $(TIPS[c.id]);
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
  // Keep the tooltip within the visible part; the main page curve scrolls with the keyboard.
  const sc = $('kb-scroll');
  const [x0, x1] = c.id === 'minichart' ? [sc.scrollLeft, sc.scrollLeft + sc.clientWidth] : [0, c.clientWidth];
  tip.style.left = Math.min(Math.max(geo.xOf(k) + 12, x0 + 4), x1 - tip.offsetWidth - 4) + 'px';
  tip.style.top = Math.max(4, geo.yOf(T.cents[k]) - tip.offsetHeight - 10) + 'px';
}

// ---------------------------------------------------------------------------
// Key and mode

function resetReadings() {
  Object.assign(state, { readings: [], spec: [], beatHz: NaN, display: NaN, measHz: NaN, stable: false, partialDevs: [], strobe: [], strobeReadings: [[], []], bReadings: [], autoFrames: 0 });
}

function selectKey(k, manual = true) {
  k = Math.max(1, Math.min(top(), k));
  if (manual && state.mode === 'auto') setMode('lock');
  if (k === state.key) return;
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
  state.mode = m;
  for (const id of ['auto', 'lock', 'map']) $('mode-' + id).setAttribute('aria-pressed', m === id);
  state.map = m === 'map' ? mapping.newKeyState() : null;
  state.run = m === 'map' ? newRun() : null;
  state.bReadings = [];
  $('map-panel').hidden = m !== 'map';
  if (m === 'map') selectKey(nextPending(0), false);
  renderKeyboard();
  renderMapPanel();
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
    const key = { insecure: 'mic.insecure', NotAllowedError: 'mic.denied' }[e.name];
    message(key ? tr(key) : tr('mic.failed', { err: e.message }), 'error', 0);
    return;
  }
  state.analyzer = new Analyzer(mic.sampleRate);
  state.noise = -70;
  state.timer = setInterval(processFrame, FRAME_MS);
  renderMicButton();
  renderMicList(); // names are known now
  requestWakeLock();
}

function stopMic() {
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
}

async function requestWakeLock() {
  try { state.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* optional */ }
}

function processFrame() {
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
  // Noise floor: follows quickly down, slowly up.
  state.noise = lvl < state.noise ? lvl : state.noise + Math.min(0.15, (lvl - state.noise) * 0.01);
  // The survey waits for an attack so the previous key's decay is not measured.
  if (state.map?.waitAttack) {
    if (lvl - state.prevLevel <= 6) return idle();
    state.map.waitAttack = false;
  }
  if (lvl < Math.max(state.noise + 10, -72)) return idle();

  const A = state.analyzer;
  A.load(buf);
  if (state.mode === 'auto') followDetectedKey(A.detectKey(state.T, state.key, top()));
  else if (state.map) state.map.heard = A.detectKey(state.T, state.key, top());
  measureCurrent(A);
}

// Switch key when the same candidate wins two frames in a row. Count how long
// the current key has been a clear winner; only then does auto mode save.
function followDetectedKey(d) {
  state.autoFrames = d.score > 8 && d.margin >= 6 && d.key === state.key ? state.autoFrames + 1 : 0;
  if (d.score <= 8) return;
  state.candCount = d.key === state.cand ? state.candCount + 1 : 1;
  state.cand = d.key;
  if (state.candCount >= 2 && d.key !== state.key) selectKey(d.key, false);
}

function idle() {
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
  // Locked key: wide window so that even a badly flat piano is found.
  const m = A.measure(target, state.mode === 'auto' ? 50 : 150, 8);
  if (!m) {
    // A key far away has no partial near the target, but detection still hears it.
    if (state.map && !refPlaying()) trackWrongKey(mapping.wrongKey(state.map.heard, k, NaN, NaN, state.run.done));
    return idle();
  }

  const raw = centsBetween(m.freq, target);
  const ref = refPlaying();
  if (!ref && state.refTainted) state.readings = []; // drop readings of the reference tone
  state.refTainted = ref;
  state.readings.push({ c: raw, hz: m.freq });
  if (state.readings.length > 7) state.readings.shift();
  const last = state.readings.slice(-5);
  const cs = last.map((r) => r.c);
  const sure = state.mode !== 'auto' || state.autoFrames >= 6;
  state.stable = !ref && sure && last.length >= 4 && Math.max(...cs) - Math.min(...cs) < (k > 70 ? 1.5 : 0.8);
  state.signal = true;

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
  if (state.stable && !state.map) recordKey(k, n, median(last.map((r) => r.hz)));

  const f1 = T.freq[k] * 2 ** (raw / 1200);
  if (!ref && state.measureB?.k === k) {
    const r = A.inharmonicity(f1, T.B[k]);
    if (r) state.bReadings.push(r.B);
  }
  if (state.map && !ref) collectMapping(A, k, m.freq, f1, raw);
  if (state.measureB && performance.now() > state.measureB.until) finishMeasureB();
  updateReadout();
}

function recordKey(k, n, hz) {
  const rec = state.tuning.keys[k] || {};
  if (!rec.bhz) Object.assign(rec, { bhz: hz, bn: n }); // first measurement in the pass
  Object.assign(rec, { hz, n, at: Date.now() });
  state.tuning.keys[k] = rec;
  markDirty();
  renderKeyStatus();
}

function storeB(k, B) {
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
    message(tr('msg.bMeasured', { name: kName(k), b: fmtB(B) }), 'ok');
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
    (!skipped.length ? '' : skipped.length <= 8 ? tr('map.skipped', { keys: skipped.map(kName).join(', ') }) : tr('map.skippedMany', { n: skipped.length }));
  setMode('lock');
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
  const ms = tones.pluck(goalF1(state.key), state.T.B[state.key]);
  state.refUntil = Math.max(state.refUntil, performance.now() + ms + 800); // + the analysis buffer
}

function startSine() {
  if (!tones.sineOn && mic.running) message(tr('msg.sineNoSave'), 'info', 4000);
  tones.startSine(sineFreq());
  renderToneButton();
}

function stopSine() {
  if (!tones.sineOn) return;
  tones.stopSine();
  state.refUntil = performance.now() + 800;
  renderToneButton();
}

function playCurrent() {
  if (state.toneMode !== 'sine') playPiano();
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

function renderToneButton() {
  const b = $('btn-tone');
  b.textContent = tr(tones.sineOn ? 'tone.stopSine' : state.toneMode === 'sine' ? 'tone.playSine' : 'tone.play');
  b.setAttribute('aria-pressed', tones.sineOn);
}

// ---------------------------------------------------------------------------
// Readout and animation

function updateReadout() {
  const pill = $('status-pill');
  let text;
  let s = 'idle';
  if (!mic.running) text = tr('status.start');
  else if (!state.signal) text = state.map?.waitAttack ? tr('status.strike', { name: kName(state.key) }) : tr('status.listening');
  else {
    s = statusClass(state.display);
    text = tr(refPlaying() ? 'status.ref' : s === 'good' ? 'status.good' : state.display > 0 ? 'status.high' : 'status.low');
  }
  pill.dataset.s = s;
  pill.textContent = text;
  $('cents-num').textContent = mic.running ? fmtC(state.display) : '–';
  $('cents').dataset.live = state.signal ? '1' : '0';
  const n = partialOf(state.key);
  const hz = mic.running && Number.isFinite(state.measHz) ? fmtHz(state.measHz) : '–';
  $('measured').textContent = tr(n > 1 ? 'measured.partial' : 'measured', { n, hz });
  $('measured').dataset.live = state.signal ? '1' : '0';
  $('level-bar').style.width = `${Math.max(0, Math.min(100, (state.level + 80) * 1.4))}%`;
  renderPartials();
}

function renderPartials() {
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
    drawMeter($('meter'), { display: state.display, signal: state.signal, tol }, C);
    drawStrobe($('strobe'), { bands: state.strobe, live, tol }, C, dt, state.strobePhase);
    drawSpectro($('spectro'), state.spec, { capacity: SPEC_COLS, bins: SPEC_BINS, cents: SPEC_CENTS, tol }, C);
    const beatLive = live && Number.isFinite(state.beatHz);
    state.beatPhase = drawBeat($('beat'), { beatHz: state.beatHz, display: state.display, live: beatLive, tol }, C, dt, state.beatPhase);
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
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(state.tuning, null, 2)], { type: 'application/json' }));
  a.download = (state.tuning.name || tr('name.file')).replace(/[^\p{L}\p{N}_-]+/gu, '_') + '.json';
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
  if (tab === 'curve') renderChart();
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
  on('btn-settings', 'click', () => ($('drawer').hidden ? openDrawer() : closeDrawer()));
  on('drawer-close', 'click', closeDrawer);
  on('drawer-backdrop', 'click', closeDrawer);
  on('btn-ref-chip', 'click', () => openDrawer('tuning'));
  onAll('[data-tab]', (b) => showTab(b.dataset.tab));
  on('btn-mic', 'click', () => (mic.running ? stopMic() : startMic()));

  // Tuner
  on('btn-prev', 'click', () => selectKey(state.key - 1));
  on('btn-next', 'click', () => selectKey(state.key + 1));
  on('mode-auto', 'click', () => setMode('auto'));
  on('mode-lock', 'click', () => setMode('lock'));
  on('mode-map', 'click', () => {
    if (state.mode === 'map') return;
    setMode('map');
    if (!mic.running) startMic();
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
  for (const [id, tip] of Object.entries(TIPS)) {
    on(id, 'pointermove', chartHover);
    on(id, 'pointerleave', show(tip, false));
    on(id, 'click', (e) => chartKeyAt(e) && selectKey(chartKeyAt(e)));
  }
  on('table-details', 'toggle', () => $('table-details').open && renderTable());
  on('set-mic', 'change', async () => {
    state.micId = $('set-mic').value;
    try { localStorage.setItem(LS.mic, state.micId); } catch { /* optional */ }
    if (mic.running) {
      stopMic();
      await startMic();
    }
  });
  navigator.mediaDevices?.addEventListener?.('devicechange', renderMicList);
  let scrollRaf = 0;
  on('kb-scroll', 'scroll', () => (scrollRaf ||= requestAnimationFrame(() => { scrollRaf = 0; renderChart(); })));
  on('curve-toggle', 'click', () => {
    const open = $('curve-row').hidden;
    setCurveOpen(open);
    try { localStorage.setItem(LS.curve, open ? 'open' : 'closed'); } catch { /* optional */ }
  });

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
    if (document.visibilityState === 'hidden') saver.flush();
    else if (mic.running) {
      mic.resume();
      if (!state.wakeLock) requestWakeLock();
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
  } catch { /* optional */ }
  setMapPlan(plan);
  setToneMode(tone);
  fetch('api/version')
    .then((r) => r.json())
    .then(({ version }) => {
      $('app-version').textContent = version;
      if (/^v\d/.test(version)) $('app-version').href += '/tag/' + version;
    })
    .catch(() => {});
  updateReadout();
  requestAnimationFrame(animate);
}

boot();
