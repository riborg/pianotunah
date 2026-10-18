// Piano Tunah: tillstånd, DOM och händelser. Beräkningar finns i theory.js och
// dsp.js, ritning i draw.js, ljud i mic.js/tone.js, sparning i saver.js.

import {
  KEY_COUNT, A4, TEMPERAMENTS, PIANO_KINDS, STRETCH_PRESETS, OCTAVE_TYPES, sizeClass,
  computeTargets, defaultPartial, partialFreq, centsBetween, noteName, pcName, pitchClass, isBlack,
} from './theory.js';
import { Analyzer, rmsDb, median } from './dsp.js';
import { listTunings, getTuning, saveTuning, deleteTuning, newTuning, normalize, duplicateTuning } from './store.js';
import { num, fmtC, fmtHz, fmtB } from './format.js';
import { Mic } from './mic.js';
import { TonePlayer } from './tone.js';
import { Saver } from './saver.js';
import { readColors, drawMeter, drawStrobe, drawSpectro, drawBeat, drawChart } from './draw.js';
import * as mapping from './mapping.js';

const $ = (id) => document.getElementById(id);

const FRAME_MS = 90; // analysintervall
const SPEC_COLS = 100; // spektrogrammets historik, ≈ 9 s
const SPEC_BINS = 48;
const SPEC_CENTS = 30;
const LS = { tuning: 'pianotunah.lastTuning', tone: 'pianotunah.toneMode', theme: 'pianotunah.theme', plan: 'pianotunah.mapPlan', tab: 'pianotunah.tab' };

const mic = new Mic();
const tones = new TonePlayer();

const state = {
  tuning: null,
  T: null, // mål från computeTargets
  list: [],
  key: A4,
  mode: 'auto', // auto | lock | map
  analyzer: null,
  timer: 0,
  level: -100,
  prevLevel: -100,
  noise: -70,
  signal: false,
  readings: [], // senaste avläsningarna för aktuell tangent: { c, hz }
  display: NaN, // avvikelse mot (ev. överdragsjusterat) mål
  stable: false,
  spec: [], // spektrogramkolumner, se drawSpectro
  frameCol: null,
  beatHz: NaN,
  beatPhase: 0,
  partialDevs: [],
  cand: 0, // kandidattangent i auto-läget och antal bildrutor i rad
  candCount: 0,
  autoFrames: 0, // bildrutor i rad som aktuell tangent varit klar vinnare
  bReadings: [],
  measureB: null, // { k, until } vid manuell B-mätning
  map: null, // kartläggning av aktuell tangent, se mapping.newKeyState
  mapPlan: 'quick',
  toneMode: 'off', // off | piano | sine
  refUntil: 0, // referenston hörs i mikrofonen till denna tidpunkt
  refTainted: false,
  wakeLock: null,
  strobePhase: [0, 0, 0],
  lastAnim: 0,
  colors: {},
  chartGeo: null,
};

// ---------------------------------------------------------------------------
// Härledda värden

const S = () => state.tuning.settings;
const kName = (k) => noteName(k);
const tolerance = () => Number(S().tolerance) || 1;
const top = () => (Number(S().keyCount) === 85 ? 85 : KEY_COUNT); // A7 på äldre pianon, annars C8
const partialOf = (k) => state.tuning.partials[k] || defaultPartial(k);

// Mätningar sparas som frekvensen för den delton som mättes, så att de förblir
// rätt när referens, temperatur, stretch eller B ändras.
const keyRec = (k) => state.tuning.keys[k];
const devOf = (k, hz, n) => (hz && n ? centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n)) : NaN);
const curDev = (k) => devOf(k, keyRec(k)?.hz, keyRec(k)?.n);
const beforeDev = (k) => devOf(k, keyRec(k)?.bhz, keyRec(k)?.bn);

// Överdrag: stäm förbi målet med en andel av hur långt tangenten låg från början.
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

// Mikrofonen hör högtalaren (ingen ekoreducering). Medan en referenston klingar
// sparas inga mätningar.
const refPlaying = () => tones.sineOn || performance.now() < state.refUntil;

function midBefore() {
  const d = [];
  for (let k = 28; k <= 64; k++) if (Number.isFinite(beforeDev(k))) d.push(beforeDev(k));
  return d;
}

// ---------------------------------------------------------------------------
// Meddelanden. ms = 0: ligger kvar tills det stängs. tag: kan tas bort när
// orsaken försvinner.

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
// Sparande

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

function setSaveState(s) {
  const el = $('save-status');
  el.dataset.state = s;
  el.textContent = { idle: 'Sparad', dirty: 'Ändrad', saving: 'Sparar …', error: 'Ej sparad' }[s];
  el.title = s === 'error' ? 'Servern svarar inte. Försöker igen.' : '';
}

async function reloadAfterConflict(t) {
  try {
    const latest = await getTuning(t.id);
    saver.dirty = false;
    await openTuning(latest);
    message('Stämningen har sparats från en annan flik eller enhet. Den senaste versionen är laddad; ändringarna här sparades inte.', 'warn', 0);
  } catch {
    setSaveState('error');
    message('Stämningen har ändrats någon annanstans men kunde inte laddas om. Ladda om sidan.', 'error', 0);
  }
}

// ---------------------------------------------------------------------------
// Sparade stämningar

async function refreshList() {
  state.list = await listTunings();
  renderTuningSelect();
}

function renderTuningSelect() {
  const sel = $('tuning-select');
  sel.replaceChildren(...state.list.map((t) => option(t.id, t.name || 'Namnlös')));
  if (state.tuning) sel.value = state.tuning.id;
}

async function openTuning(t) {
  await saver.flush();
  state.tuning = normalize(t);
  try { localStorage.setItem(LS.tuning, t.id); } catch { /* valfritt */ }
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

function buildStaticUi() {
  $('set-kind').replaceChildren(...Object.entries(PIANO_KINDS).map(([k, v]) => option(k, v.name)));
  $('set-temperament').replaceChildren(...Object.entries(TEMPERAMENTS).map(([k, v]) => option(k, v.name)));
  $('set-stretch').replaceChildren(...Object.entries(STRETCH_PRESETS).map(([k, v]) => option(k, v.name)));
  for (const id of ['set-bass', 'set-mid', 'set-treble']) $(id).replaceChildren(...Object.keys(OCTAVE_TYPES).map((k) => option(k, k)));
  $('set-root').replaceChildren(...Array.from({ length: 12 }, (_, pc) => option(pc, pcName(pc))));
}

// Vita tangenter i flex, svarta absolut positionerade mellan dem. Byggs om
// bara när antalet tangenter ändras.
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
  const kind = PIANO_KINDS[s.pianoKind] || PIANO_KINDS.upright;
  $('temperament-desc').textContent = TEMPERAMENTS[s.temperament]?.desc || '';
  $('stretch-desc').textContent = STRETCH_PRESETS[s.stretch]?.desc || '';
  $('custom-oct').hidden = s.stretch !== 'custom';
  $('set-root').disabled = s.temperament === 'et';
  $('size-label').textContent = kind.size;
  Object.assign($('set-size'), { min: kind.min, max: kind.max });
  $('out-size').textContent = sizeClass(s.pianoKind, Number(s.sizeCm));
  $('size-desc').textContent = `Mät ${kind.how}. Används som startgissning för strängarnas inharmonicitet tills pianot är kartlagt.`;
  $('out-extra-treble').textContent = fmtC(Number(s.extraTreble), 0) + ' cent vid C8';
  $('out-extra-bass').textContent = (Number(s.extraBass) ? '−' + num(Number(s.extraBass), 0) : '±0') + ' cent vid A0';
  $('out-overpull').textContent = s.overpull + ' %';
}

function renderRef() {
  const ref = Number(S().refA4);
  if (document.activeElement !== $('set-ref')) $('set-ref').value = ref.toFixed(1);
  $('btn-ref-chip').textContent = `A4 = ${fmtHz(ref, 1)}`;
  const c = centsBetween(ref, 440);
  $('ref-cents').textContent = Math.abs(c) < 0.05 ? 'Standardstämton' : `${fmtC(c)} cent mot 440 Hz`;
  for (const b of $('ref-presets').children) b.classList.toggle('on', Number(b.dataset.hz) === ref);

  const mid = midBefore();
  if (mid.length < 3) {
    $('ref-advice').textContent = 'Kartlägg eller mät några tangenter i mitten så kan appen föreslå en referens som passar pianot.';
    return;
  }
  const m = median(mid);
  $('ref-advice').textContent =
    Math.abs(m) < 3
      ? `Pianot låg nära målet (${fmtC(m)} cent i mitten) när omgången började.`
      : `Pianot låg ${fmtC(m)} cent från målet i mitten (≈ A4 = ${fmtHz(ref * 2 ** (m / 1200), 1)}). ` +
        (m < -15
          ? 'Sänk referensen för en snabb stämning, eller dra upp med 20–30 % överdrag och räkna med en andra omgång.'
          : 'Små avvikelser stäms direkt utan överdrag.');
}

function renderKeyInfo() {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const g = goal(k);
  $('note-name').textContent = kName(k);
  $('note-sub').textContent = `tangent ${k} · mål ${fmtC(T.cents[k])} cent`;
  $('targetline').textContent =
    `Grundton ${fmtHz(T.freq[k])}` +
    (n > 1 ? ` · delton ${n} ${fmtHz(partialFreq(T.freq[k], T.B[k], n))}` : '') +
    (g ? ` · överdrag ${fmtC(g)} cent` : '');
  $('partial-val').textContent = n;
  $('bval').textContent = `B = ${fmtB(T.B[k])} (${state.tuning.inharmonicity[k] ? 'uppmätt' : 'modell'})`;
  if (tones.sineOn) tones.setSine(sineFreq());
}

function renderKeyboard() {
  buildKeyboard(top());
  const cur = Math.min(state.key, top());
  const quickPlan = state.map && state.mapPlan === 'quick';
  for (const el of $('keyboard').children) {
    const k = Number(el.dataset.k);
    const label = `${kName(k)}, ${Number.isFinite(curDev(k)) ? fmtC(statusDev(k)) + ' cent' : 'ej mätt'}`;
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
  const marker = $('kb-marker');
  marker.style.left = `calc(10px + (100% - 20px) * ${Number(curEl.dataset.cx) / 100})`;
  marker.dataset.s = statusClass(statusDev(cur));
  $('kb-marker-name').textContent = kName(cur);
  // Scrolla fram aktuell tangent på smal skärm, men bara vid byte så att man
  // kan scrolla själv mellan mätningarna.
  const sc = $('kb-scroll');
  if (cur !== renderKeyboard.scrolledTo && sc.scrollWidth > sc.clientWidth) {
    renderKeyboard.scrolledTo = cur;
    const x = (Number(curEl.dataset.cx) / 100) * sc.scrollWidth - sc.clientWidth / 2;
    sc.scrollTo({ left: x, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }
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
    stat(`${ok}/${top()}`, 'inom tolerans'),
    stat(`${measured}`, 'uppmätta'),
    stat(since.toLocaleDateString('sv-SE'), 'påbörjad'),
  );
  $('history').replaceChildren(
    ...[...state.tuning.history].reverse().map((p) =>
      Object.assign(document.createElement('li'), {
        textContent:
          `${new Date(p.startedAt).toLocaleDateString('sv-SE')}: ${p.measured} tangenter, ref ${num(p.refA4, 1)} Hz, ` +
          `före ${num(p.meanAbsBefore)} cent → efter ${num(p.meanAbsAfter)} cent i snitt`,
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
  head.innerHTML = '<tr><th>Tangent</th><th>Ton</th><th>Mål (cent)</th><th>Mål (Hz)</th><th>B</th><th>Delton</th><th>Före</th><th>Nu</th></tr>';
  const body = document.createElement('tbody');
  for (let k = top(); k >= 1; k--) {
    const tr = document.createElement('tr');
    const cells = [
      k, kName(k), fmtC(T.cents[k]), T.freq[k].toFixed(2).replace('.', ','),
      fmtB(T.B[k]) + (state.tuning.inharmonicity[k] ? ' *' : ''), partialOf(k), fmtC(beforeDev(k)), fmtC(statusDev(k)),
    ];
    for (const c of cells) tr.append(Object.assign(document.createElement('td'), { textContent: c }));
    tr.lastChild.dataset.s = statusClass(statusDev(k));
    if (k === state.key) tr.className = 'current';
    body.append(tr);
  }
  $('ktable').replaceChildren(head, body);
}

function renderChart() {
  if (!state.T || !$('chart').clientWidth) return; // dold flik: ritas när den visas
  const T = state.T;
  const points = [];
  const ticks = [];
  for (let k = 1; k <= top(); k++) {
    const d = curDev(k);
    if (Number.isFinite(d)) points.push({ k, c: T.cents[k] + d, status: statusClass(statusDev(k)) });
    if (pitchClass(k) === 0) ticks.push({ k, label: kName(k) });
  }
  state.chartGeo = drawChart($('chart'), { top: top(), target: T.cents, points, ticks, current: state.key }, state.colors);
}

// Uppdatera tangentstatus högst en gång per bildruta, även om mätningar sparas oftare.
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
  const k = state.chartGeo?.keyAt(e.clientX - $('chart').getBoundingClientRect().left);
  return k >= 1 && k <= top() ? k : 0;
}

function chartHover(e) {
  const k = chartKeyAt(e);
  const tip = $('tooltip');
  tip.hidden = !k;
  if (!k) return;
  const T = state.T;
  const rows = [
    [kName(k), `tangent ${k}`],
    ['Mål', `${fmtC(T.cents[k])} cent · ${fmtHz(T.freq[k])}`],
    ['B', `${fmtB(T.B[k])} ${state.tuning.inharmonicity[k] ? 'uppmätt' : 'modell'}`],
  ];
  if (Number.isFinite(curDev(k))) rows.push(['Avvikelse', `${fmtC(statusDev(k))} cent`]);
  tip.replaceChildren(
    ...rows.map(([a, b]) => {
      const row = document.createElement('div');
      row.append(Object.assign(document.createElement('b'), { textContent: a }), Object.assign(document.createElement('span'), { textContent: b }));
      return row;
    }),
  );
  const w = $('chart').clientWidth;
  tip.style.left = Math.min(Math.max(state.chartGeo.xOf(k) + 12, 4), w - tip.offsetWidth - 4) + 'px';
  tip.style.top = Math.max(4, state.chartGeo.yOf(T.cents[k]) - tip.offsetHeight - 10) + 'px';
}

// ---------------------------------------------------------------------------
// Tangent och läge

function resetReadings() {
  Object.assign(state, { readings: [], spec: [], beatHz: NaN, display: NaN, stable: false, partialDevs: [], bReadings: [], autoFrames: 0 });
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
  state.bReadings = [];
  $('map-panel').hidden = m !== 'map';
  if (m === 'map') selectKey(firstUnmapped(), false); // börja från början, eller där förra slutade
  renderKeyboard();
  renderMapPanel();
}

// ---------------------------------------------------------------------------
// Mätning

async function startMic() {
  try {
    await mic.start();
  } catch (e) {
    const text = {
      insecure: 'Mikrofonen kräver https. Öppna appen via https.',
      NotAllowedError: 'Mikrofonen nekades. Tillåt den för sidan via ikonen i adressfältet och försök igen.',
    }[e.name];
    message(text || `Kunde inte starta mikrofonen: ${e.message}`, 'error', 0);
    return;
  }
  state.analyzer = new Analyzer(mic.sampleRate);
  state.noise = -70;
  state.timer = setInterval(processFrame, FRAME_MS);
  $('btn-mic').textContent = 'Stoppa mikrofon';
  $('btn-mic').classList.remove('primary');
  requestWakeLock();
}

function stopMic() {
  clearInterval(state.timer);
  mic.stop();
  state.signal = false;
  state.wakeLock?.release?.().catch(() => {});
  state.wakeLock = null;
  $('btn-mic').textContent = 'Starta mikrofon';
  $('btn-mic').classList.add('primary');
  updateReadout();
}

async function requestWakeLock() {
  try { state.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* valfritt */ }
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
  // Brusgolv: följer snabbt nedåt, långsamt uppåt.
  state.noise = lvl < state.noise ? lvl : state.noise + Math.min(0.15, (lvl - state.noise) * 0.01);
  // Kartläggning väntar på ett anslag så att förra tangentens efterklang inte mäts.
  if (state.map?.waitAttack) {
    if (lvl - state.prevLevel <= 6) return idle();
    state.map.waitAttack = false;
  }
  if (lvl < Math.max(state.noise + 10, -72)) return idle();

  const A = state.analyzer;
  A.load(buf);
  if (state.mode === 'auto') followDetectedKey(A.detectKey(state.T, state.key, top()));
  measureCurrent(A);
}

// Byt tangent när samma kandidat vunnit två bildrutor i rad. Räkna hur länge
// aktuell tangent varit klar vinnare; först då sparas något i auto-läget.
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
  // Låst tangent: brett fönster så att även ett kraftigt nedstämt piano hittas.
  const m = A.measure(target, state.mode === 'auto' ? 50 : 150, 8);
  if (!m) return idle();

  const raw = centsBetween(m.freq, target);
  const ref = refPlaying();
  if (!ref && state.refTainted) state.readings = []; // släng avläsningar av referenstonen
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
  const center = target * 2 ** (g / 1200); // svävningsvyn centreras på målet inkl. överdrag
  state.beatHz = center * (2 ** (state.display / 1200) - 1);
  state.frameCol = { col: A.zoom(center, SPEC_CENTS, SPEC_BINS), c: state.display };
  state.partialDevs = Array.from({ length: 8 }, (_, i) => {
    const fi = partialFreq(T.freq[k], T.B[k], i + 1);
    if (fi > A.sr * 0.45 || fi < 40) return null;
    const mi = i + 1 === n ? m : A.measure(fi, 50, 8);
    return mi ? centsBetween(mi.freq, fi) : null;
  });

  // Spara samma värde som visas. Under kartläggning sparar mapStep i stället.
  if (state.stable && !state.map) recordKey(k, n, median(last.map((r) => r.hz)));

  const f1 = T.freq[k] * 2 ** (raw / 1200);
  if (!ref && state.measureB?.k === k) {
    const r = A.inharmonicity(f1, T.B[k]);
    if (r) state.bReadings.push(r.B);
  }
  if (state.map && !ref) collectMapping(A, k, m.freq, f1);
  if (state.measureB && performance.now() > state.measureB.until) finishMeasureB();
  updateReadout();
}

function recordKey(k, n, hz) {
  const rec = state.tuning.keys[k] || {};
  if (!rec.bhz) Object.assign(rec, { bhz: hz, bn: n }); // första mätningen i omgången
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
    message(`Inharmonicitet för ${kName(k)}: B = ${fmtB(B)}`, 'ok');
  } else {
    message('Kunde inte mäta inharmonicitet. Slå an tangenten kraftigt och låt den klinga i ett par sekunder.', 'warn');
  }
  state.bReadings = [];
}

function flashKey(k) {
  const el = $('keyboard').children[k - 1];
  el.classList.remove('flash');
  void el.offsetWidth; // starta om animationen
  el.classList.add('flash');
}

// ---------------------------------------------------------------------------
// Kartläggning

const isMapped = (k) => !!keyRec(k)?.mapped;
const isQuick = () => state.mapPlan === 'quick';
const needsB = (k) => isQuick() || !state.tuning.inharmonicity[k]; // snabbläget mäter alltid om B
const planKeys = () => mapping.planKeys(state.mapPlan, top());
const firstUnmapped = () => planKeys().find((k) => !isMapped(k)) ?? planKeys()[0];

function setMapPlan(p) {
  state.mapPlan = p;
  try { localStorage.setItem(LS.plan, p); } catch { /* valfritt */ }
  document.querySelectorAll('[data-plan]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.plan === p));
  if (!state.map) return;
  state.map = mapping.newKeyState();
  selectKey(firstUnmapped(), false);
  renderKeyboard();
  renderMapPanel();
}

function collectMapping(A, k, partialHz, f1) {
  const mp = state.map;
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
  state.tuning.keys[k] = { ...keyRec(k), bhz: hz, bn: n, hz, n, at: Date.now(), mapped: true };
  if (mp.bs.length >= 3) storeB(k, median(mp.bs));
  else {
    markDirty();
    recompute();
  }
  flashKey(k);
  advanceMapping(k);
}

function advanceMapping(k) {
  const next = mapping.nextInPlan(state.mapPlan, top(), k);
  if (next) selectKey(next, false);
  else finishMapping();
}

function finishMapping() {
  const withB = (ks) => ks.filter((k) => state.tuning.inharmonicity[k]).length;
  const all = Array.from({ length: top() }, (_, i) => i + 1);
  const text = isQuick()
    ? `Snabbmätningen är klar: inharmonicitet för ${withB(planKeys())} av ${planKeys().length} toner. Tangenterna däremellan interpoleras.`
    : `Kartläggningen är klar: ${all.filter(isMapped).length} tangenter mätta, inharmonicitet för ${withB(all)}. Se rutan Referens A4 för hur pianot ligger.`;
  setMode('lock');
  message(text, 'ok', 0);
}

function renderMapPanel() {
  if (!state.map) return;
  const mp = state.map;
  const name = kName(state.key);
  const ks = planKeys();
  const done = ks.filter(isMapped).length;
  $('map-progress').textContent = `${done} av ${ks.length} ${isQuick() ? 'toner' : 'tangenter'}`;
  $('map-bar').style.width = `${(done / ks.length) * 100}%`;
  $('map-step').textContent = mp.waitAttack
    ? `Slå an ${name} kraftigt och låt den klinga.`
    : mp.lost
      ? `${name} klingade ut innan mätningen var klar. Slå an den igen.`
      : `Lyssnar på ${name} … låt tonen klinga.`;
  const p = Math.min(mp.pitch.length, mapping.PITCH_READINGS);
  setCheck('map-chk-pitch', `Tonhöjd ${p}/${mapping.PITCH_READINGS}`, p >= mapping.PITCH_READINGS);
  if (!needsB(state.key)) setCheck('map-chk-b', 'Inharmonicitet redan uppmätt', true);
  else if (mapping.bGivenUp(mp, state.mapPlan)) setCheck('map-chk-b', 'Inharmonicitet: för svaga övertoner, hoppas över', true);
  else setCheck('map-chk-b', `Inharmonicitet ${Math.min(mp.bs.length, mapping.B_READINGS)}/${mapping.B_READINGS}`, mp.bs.length >= mapping.B_READINGS);
}

function setCheck(id, text, done) {
  $(id).textContent = text;
  $(id).dataset.done = done ? '1' : '0';
}

// ---------------------------------------------------------------------------
// Referenstoner

const goalF1 = (k) => state.T.freq[k] * 2 ** (goal(k) / 1200);
const sineFreq = () => partialFreq(goalF1(state.key), state.T.B[state.key], partialOf(state.key));

function playPiano() {
  const ms = tones.pluck(goalF1(state.key), state.T.B[state.key]);
  state.refUntil = Math.max(state.refUntil, performance.now() + ms + 800); // + analysbufferten
}

function startSine() {
  if (!tones.sineOn && mic.running) message('Mätningar sparas inte medan sinustonen spelas.', 'info', 4000);
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
  try { localStorage.setItem(LS.tone, m); } catch { /* valfritt */ }
  renderToneButton();
}

function renderToneButton() {
  const b = $('btn-tone');
  b.textContent = tones.sineOn ? 'Stoppa sinuston' : state.toneMode === 'sine' ? 'Spela sinuston' : 'Spela målton';
  b.setAttribute('aria-pressed', tones.sineOn);
}

// ---------------------------------------------------------------------------
// Avläsning och animation

function updateReadout() {
  const pill = $('status-pill');
  let text;
  let s = 'idle';
  if (!mic.running) text = 'Starta mikrofonen';
  else if (!state.signal) text = state.map?.waitAttack ? `Slå an ${kName(state.key)}` : 'Lyssnar …';
  else {
    s = statusClass(state.display);
    text = refPlaying() ? 'Referenston, sparas ej' : s === 'good' ? 'I stäm' : state.display > 0 ? 'För högt, släpp efter' : 'För lågt, dra upp';
  }
  pill.dataset.s = s;
  pill.textContent = text;
  $('cents-num').textContent = mic.running ? fmtC(state.display) : '–';
  $('cents').dataset.live = state.signal ? '1' : '0';
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
    drawStrobe($('strobe'), { display: state.display, live, tol }, C, dt, state.strobePhase);
    drawSpectro($('spectro'), state.spec, { capacity: SPEC_COLS, bins: SPEC_BINS, cents: SPEC_CENTS, tol }, C);
    const beatLive = live && Number.isFinite(state.beatHz);
    state.beatPhase = drawBeat($('beat'), { beatHz: state.beatHz, display: state.display, live: beatLive, tol }, C, dt, state.beatPhase);
    const df = Math.abs(state.beatHz);
    const rate = !beatLive ? '–' : df < 0.1 ? 'Svävningsfritt' : `${num(df, df < 10 ? 1 : 0)} svävningar/s`;
    if ($('beat-rate').textContent !== rate) $('beat-rate').textContent = rate;
  }
  requestAnimationFrame(animate);
}

// ---------------------------------------------------------------------------
// Åtgärder

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

// Sätt referensen så att pianots mitt ligger på målet: median av före-värdena
// i mitten, annars den tangent som klingar nu.
function fitRefToPiano() {
  const mid = midBefore();
  let shift;
  if (mid.length >= 3) shift = median(mid);
  else if (state.signal && Number.isFinite(state.display)) shift = state.display + goal(state.key);
  else return message('Spela A4 (eller kartlägg några tangenter i mitten) så kan appen mäta pianots tonhöjd.', 'warn');
  setRef(Number(S().refA4) * 2 ** (shift / 1200));
  message(`Referensen satt till ${fmtHz(Number(S().refA4), 1)} efter pianots nuvarande tonhöjd.`, 'ok');
}

// Avsluta omgången: spara sammanfattning i historiken och töm mätningarna.
// Inharmonicitet och inställningar behålls.
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
  message('Ny omgång påbörjad. Inharmonicitet och inställningar är kvar.', 'ok');
}

function exportTuning() {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(state.tuning, null, 2)], { type: 'application/json' }));
  a.download = (state.tuning.name || 'stamning').replace(/[^\wåäöÅÄÖ-]+/g, '_') + '.json';
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

async function importTuning(file) {
  try {
    const data = JSON.parse(await file.text());
    if (!data?.settings) throw new Error('saknar inställningar');
    const exists = state.list.some((x) => x.id === data.id);
    const t = duplicateTuning(data, (data.name || 'Importerad') + (exists ? ' (import)' : ''));
    await createAndOpen(t);
    message(`Importerade "${t.name}".`, 'ok');
  } catch (e) {
    message(`Kunde inte importera filen: ${e.message}`, 'error');
  }
}

async function deleteCurrent() {
  try {
    await saver.discard(); // en pågående sparning får inte återskapa filen
    await deleteTuning(state.tuning.id);
    await refreshList();
    if (state.list[0]) await openTuning(await getTuning(state.list[0].id));
    else await createAndOpen(newTuning('Mitt piano'));
    message('Stämningen raderades.', 'ok');
  } catch {
    message('Kunde inte radera stämningen.', 'error');
  }
}

// Färgläge: auto följer webbläsaren. theme.js i <head> tillämpar sparat val
// innan sidan ritas.
const THEMES = { auto: ['◐ Auto', 'följer webbläsaren'], light: ['☀ Ljust', 'ljust'], dark: ['☾ Mörkt', 'mörkt'] };
const currentTheme = () => document.documentElement.dataset.theme || 'auto';

function setTheme(t) {
  if (t === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  try {
    if (t === 'auto') localStorage.removeItem(LS.theme);
    else localStorage.setItem(LS.theme, t);
  } catch { /* valfritt */ }
  renderThemeButton();
  refreshColors();
}

function renderThemeButton() {
  const [label, desc] = THEMES[currentTheme()];
  Object.assign($('btn-theme'), { textContent: label, title: `Färgläge: ${desc}. Klicka för att byta.` });
  $('btn-theme').setAttribute('aria-label', `Färgläge: ${desc}`);
}

function refreshColors() {
  state.colors = readColors();
  renderChart();
}

// ---------------------------------------------------------------------------
// Inställningspanel

function openDrawer(tab) {
  $('drawer').hidden = $('drawer-backdrop').hidden = false;
  document.body.classList.add('drawer-open');
  $('btn-settings').setAttribute('aria-expanded', 'true');
  let last = 'piano';
  try { last = localStorage.getItem(LS.tab) || last; } catch { /* valfritt */ }
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
  try { localStorage.setItem(LS.tab, tab); } catch { /* valfritt */ }
  if (tab === 'curve') renderChart();
}

// ---------------------------------------------------------------------------
// Händelser

function bindEvents() {
  const on = (id, ev, fn) => $(id).addEventListener(ev, fn);
  const onAll = (sel, fn) => document.querySelectorAll(sel).forEach((el) => el.addEventListener('click', () => fn(el)));
  const show = (id, v) => () => ($(id).hidden = !v);

  // Topp
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

  // Stämapparat
  on('btn-prev', 'click', () => selectKey(state.key - 1));
  on('btn-next', 'click', () => selectKey(state.key + 1));
  on('mode-auto', 'click', () => setMode('auto'));
  on('mode-lock', 'click', () => setMode('lock'));
  on('mode-map', 'click', () => {
    if (state.mode === 'map') return;
    setMode('map');
    if (!mic.running) startMic();
  });
  on('map-skip', 'click', () => advanceMapping(state.key));
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
    if (!mic.running) return message('Starta mikrofonen först.', 'warn');
    state.bReadings = [];
    state.measureB = { k: state.key, until: performance.now() + 4000 };
    $('btn-measure-b').disabled = true;
    message(`Slå an ${kName(state.key)} kraftigt och låt den klinga …`, 'info', 4000);
    setTimeout(() => state.measureB && finishMeasureB(), 6000); // om tonen tystnar innan
  });

  // Referens
  on('set-ref', 'change', (e) => setRef(parseFloat(e.target.value.replace(',', '.'))));
  onAll('[data-ref]', (b) => setRef(Number(S().refA4) + Number(b.dataset.ref)));
  onAll('[data-hz]', (b) => setRef(Number(b.dataset.hz)));
  on('btn-fit-ref', 'click', fitRefToPiano);

  // Inställningar
  const bindSetting = (id, key, conv = (v) => v) => on(id, 'input', (e) => setSetting(key, conv(e.target.value)));
  on('set-kind', 'input', (e) => {
    S().sizeCm = PIANO_KINDS[e.target.value].def; // en pianinohöjd är ingen rimlig flygellängd
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
    state.tuning.name = e.target.value.trim() || 'Namnlös';
    const item = state.list.find((t) => t.id === state.tuning.id);
    if (item) item.name = state.tuning.name;
    renderTuningSelect();
    markDirty();
  });
  on('set-notes', 'input', (e) => {
    state.tuning.notes = e.target.value;
    markDirty();
  });

  // Sparade stämningar
  on('tuning-select', 'change', async (e) => {
    try {
      await openTuning(await getTuning(e.target.value));
    } catch {
      message('Kunde inte öppna stämningen.', 'error');
      renderTuningSelect();
    }
  });
  on('btn-new', 'click', () => createAndOpen(newTuning(`Piano ${state.list.length + 1}`)).catch(() => message('Kunde inte skapa stämningen.', 'error')));
  on('btn-dup', 'click', async () => {
    await saver.flush();
    createAndOpen(duplicateTuning(state.tuning, state.tuning.name + ' (kopia)')).catch(() => message('Kunde inte duplicera.', 'error'));
  });
  on('btn-del', 'click', () => {
    $('confirm-del-text').textContent = `Radera "${state.tuning.name}" med alla mätningar? Det går inte att ångra.`;
    $('confirm-del').hidden = false;
  });
  on('confirm-del-no', 'click', show('confirm-del', false));
  on('confirm-del-yes', 'click', () => {
    $('confirm-del').hidden = true;
    deleteCurrent();
  });

  // Omgång
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

  // Diagram
  on('chart', 'pointermove', chartHover);
  on('chart', 'pointerleave', show('tooltip', false));
  on('chart', 'click', (e) => chartKeyAt(e) && selectKey(chartKeyAt(e)));
  on('table-details', 'toggle', () => $('table-details').open && renderTable());

  // Tangentbord
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

  // Fönster
  window.addEventListener('resize', renderChart);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refreshColors);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') saver.flush();
    else if (mic.running && !state.wakeLock) requestWakeLock();
  });
  // Sista chansen att spara när fliken stängs.
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
  buildStaticUi();
  state.colors = readColors();
  try {
    await refreshList();
    let id = null;
    try { id = localStorage.getItem(LS.tuning); } catch { /* valfritt */ }
    const pick = state.list.find((t) => t.id === id) || state.list[0];
    if (pick) await openTuning(await getTuning(pick.id));
    else await createAndOpen(newTuning('Mitt piano'));
  } catch {
    // Servern nås inte: kör ändå, utan sparande.
    state.tuning = newTuning('Mitt piano');
    recompute();
    renderSettings();
    setSaveState('error');
    message('Kunde inte nå servern. Mätningar sparas inte förrän den svarar.', 'warn', 0, 'server');
  }
  bindEvents();
  renderThemeButton();
  let plan = 'quick';
  let tone = 'off';
  try {
    plan = localStorage.getItem(LS.plan) === 'full' ? 'full' : 'quick';
    tone = localStorage.getItem(LS.tone) || 'off';
  } catch { /* valfritt */ }
  setMapPlan(plan);
  setToneMode(tone);
  updateReadout();
  requestAnimationFrame(animate);
}

boot();
