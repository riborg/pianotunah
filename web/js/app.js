import {
  KEY_COUNT, A4, TEMPERAMENTS, PIANO_TYPES, STRETCH_PRESETS, OCTAVE_TYPES,
  computeTargets, defaultPartial, partialFreq, centsBetween,
  noteName, pcName, pitchClass, isBlack, octave,
} from './theory.js';
import { Analyzer, rmsDb, median } from './dsp.js';
import { listTunings, getTuning, saveTuning, deleteTuning, newTuning, normalize, duplicateTuning } from './store.js';

const $ = (id) => document.getElementById(id);
const LAST_ID = 'pianotunah.lastTuning';
const FRAME_MS = 90;
const SPEC_COLS = 100; // ≈ 9 s historik i svävningsvyn
const SPEC_BINS = 48;
const SPEC_CENTS = 30;

const state = {
  tuning: null,
  T: null, // beräknade mål
  list: [],
  key: A4,
  mode: 'auto', // auto | lock | map
  audio: null,
  analyzer: null,
  buf: null,
  timer: 0,
  level: -100,
  prevLevel: -100,
  noise: -70,
  signal: false,
  readings: [],
  display: NaN, // avvikelse mot (ev. överdragsjusterat) mål
  stable: false,
  spec: [], // kolumner { col: Float32Array | null, c }
  frameCol: null,
  beatHz: NaN,
  beatPhase: 0,
  partialDevs: [],
  cand: 0,
  candCount: 0,
  bReadings: [],
  measureB: null, // { k, until }
  map: null, // { start, waitAttack }
  dirty: false,
  saveTimer: 0,
  saveState: 'idle',
  wakeLock: null,
  toneCtx: null,
  strobePhase: [0, 0, 0],
  lastAnim: 0,
  colors: {},
};

// ---------------------------------------------------------------------------
// Formatering

const num = (x, d = 1) => Math.abs(x).toFixed(d).replace('.', ',');
const fmtC = (c, d = 1) => (Number.isFinite(c) ? (c > 0.049 ? '+' : c < -0.049 ? '−' : '±') + num(c, d) : '–');
const fmtHz = (f, d = 2) => f.toFixed(d).replace('.', ',') + ' Hz';
const names = () => state.tuning.settings.noteNames;
const kName = (k) => noteName(k, names());
const S = () => state.tuning.settings;

// ---------------------------------------------------------------------------
// Avvikelser per tangent. Mätningar sparas som frekvensen på den delton som
// mättes, så att de förblir korrekta när referens, temperatur eller stretch ändras.

function devOf(k, hz, n) {
  if (!hz || !n) return NaN;
  return centsBetween(hz, partialFreq(state.T.freq[k], state.T.B[k], n));
}
const keyRec = (k) => state.tuning.keys[k];
const curDev = (k) => (keyRec(k) ? devOf(k, keyRec(k).hz, keyRec(k).n) : NaN);
const beforeDev = (k) => (keyRec(k) ? devOf(k, keyRec(k).bhz, keyRec(k).bn) : NaN);
function goal(k) {
  const b = beforeDev(k);
  const p = Number(S().overpull) || 0;
  return Number.isFinite(b) && p ? (-p / 100) * b : 0;
}
const statusDev = (k) => curDev(k) - goal(k);

function statusClass(d) {
  if (!Number.isFinite(d)) return 'none';
  const tol = Number(S().tolerance) || 1;
  const a = Math.abs(d);
  if (a <= tol) return 'good';
  if (a <= Math.max(5, tol * 2)) return 'warn';
  return 'bad';
}
const partialOf = (k) => state.tuning.partials[k] || defaultPartial(k);

// ---------------------------------------------------------------------------
// Meddelanden

let msgTimer = 0;
function message(text, kind = 'info', ms = 6000) {
  const el = $('message');
  el.textContent = text;
  el.dataset.kind = kind;
  el.hidden = false;
  clearTimeout(msgTimer);
  if (ms) msgTimer = setTimeout(() => (el.hidden = true), ms);
}

// ---------------------------------------------------------------------------
// Sparande

function setSaveState(s) {
  state.saveState = s;
  const el = $('save-status');
  el.dataset.state = s;
  el.textContent = { idle: 'Sparad', dirty: 'Ändrad', saving: 'Sparar …', error: 'Ej sparad' }[s] || s;
  el.title = s === 'error' ? 'Servern svarar inte. Försöker igen.' : '';
}

function markDirty() {
  state.dirty = true;
  if (state.saveState !== 'saving') setSaveState('dirty');
  if (!state.saveTimer) state.saveTimer = setTimeout(flushSave, 2500);
}

async function flushSave() {
  clearTimeout(state.saveTimer);
  state.saveTimer = 0;
  if (!state.dirty || !state.tuning) return;
  state.dirty = false;
  state.tuning.updatedAt = new Date().toISOString();
  setSaveState('saving');
  try {
    await saveTuning(state.tuning);
    setSaveState(state.dirty ? 'dirty' : 'idle');
    const item = state.list.find((t) => t.id === state.tuning.id);
    if (item && item.name !== state.tuning.name) {
      item.name = state.tuning.name;
      renderTuningSelect();
    }
  } catch {
    state.dirty = true;
    setSaveState('error');
    state.saveTimer = setTimeout(flushSave, 10000);
  }
}

// ---------------------------------------------------------------------------
// Stämningar (profiler)

async function refreshList() {
  state.list = await listTunings();
  renderTuningSelect();
}

function renderTuningSelect() {
  const sel = $('tuning-select');
  sel.replaceChildren(
    ...state.list.map((t) => {
      const o = document.createElement('option');
      o.value = t.id;
      o.textContent = t.name || 'Namnlös';
      return o;
    }),
  );
  if (state.tuning) sel.value = state.tuning.id;
}

async function openTuning(t) {
  if (state.dirty) await flushSave();
  state.tuning = normalize(t);
  try { localStorage.setItem(LAST_ID, t.id); } catch { /* valfritt */ }
  resetReadings();
  recompute();
  renderSettings();
  renderTuningSelect();
  setSaveState('idle');
}

async function createAndOpen(t) {
  await saveTuning(t);
  await refreshList();
  await openTuning(t);
}

async function boot() {
  buildStaticUi();
  readColors();
  try {
    await refreshList();
    let id = null;
    try { id = localStorage.getItem(LAST_ID); } catch { /* valfritt */ }
    const pick = state.list.find((t) => t.id === id) || state.list[0];
    if (pick) await openTuning(await getTuning(pick.id));
    else await createAndOpen(newTuning('Mitt piano'));
  } catch {
    // Servern nås inte: kör ändå, men utan sparande.
    state.tuning = newTuning('Mitt piano');
    recompute();
    renderSettings();
    setSaveState('error');
    message('Kunde inte nå servern. Mätningar sparas inte förrän den svarar.', 'warn', 0);
  }
  bindEvents();
  updateReadout();
  requestAnimationFrame(animate);
}

// ---------------------------------------------------------------------------
// Beräkning och rendering

function recompute() {
  state.T = computeTargets(S(), state.tuning.inharmonicity);
  renderKeyInfo();
  renderKeyboard();
  renderRef();
  renderPass();
  drawChart();
  if ($('table-details').open) renderTable();
}

function buildStaticUi() {
  const opt = (v, t) => Object.assign(document.createElement('option'), { value: v, textContent: t });
  $('set-piano').replaceChildren(...Object.entries(PIANO_TYPES).map(([k, v]) => opt(k, v.name)));
  $('set-temperament').replaceChildren(...Object.entries(TEMPERAMENTS).map(([k, v]) => opt(k, v.name)));
  $('set-stretch').replaceChildren(...Object.entries(STRETCH_PRESETS).map(([k, v]) => opt(k, v.name)));
  for (const id of ['set-bass', 'set-mid', 'set-treble']) {
    $(id).replaceChildren(...Object.keys(OCTAVE_TYPES).map((k) => opt(k, k)));
  }
  // Klaviatur: 52 vita tangenter i ett flex-led, svarta absolut positionerade.
  const kb = $('keyboard');
  const whites = [];
  let wi = 0;
  for (let k = 1; k <= KEY_COUNT; k++) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'key ' + (isBlack(k) ? 'black' : 'white');
    b.dataset.k = k;
    if (isBlack(k)) {
      b.style.left = `${(wi / 52) * 100}%`;
      b.dataset.cx = (wi / 52) * 100;
    } else {
      b.dataset.cx = ((wi + 0.5) / 52) * 100;
      wi++;
      const lbl = document.createElement('span');
      lbl.className = 'klabel';
      b.append(lbl);
    }
    whites.push(b);
  }
  kb.replaceChildren(...whites);
}

function renderRootSelect() {
  const sel = $('set-root');
  sel.replaceChildren(
    ...Array.from({ length: 12 }, (_, pc) =>
      Object.assign(document.createElement('option'), { value: pc, textContent: pcName(pc, names()) }),
    ),
  );
}

function renderSettings() {
  const s = S();
  $('set-name').value = state.tuning.name;
  $('set-piano').value = s.pianoType;
  $('set-temperament').value = s.temperament;
  renderRootSelect();
  $('set-root').value = s.root;
  $('set-stretch').value = s.stretch;
  $('set-bass').value = s.bassOctave;
  $('set-mid').value = s.midOctave;
  $('set-treble').value = s.trebleOctave;
  $('set-extra-treble').value = s.extraTreble;
  $('set-extra-bass').value = s.extraBass;
  $('set-overpull').value = s.overpull;
  $('set-tolerance').value = String(s.tolerance);
  $('set-names').value = s.noteNames;
  $('set-notes').value = state.tuning.notes || '';
  renderSettingDescs();
}

function renderSettingDescs() {
  const s = S();
  $('temperament-desc').textContent = (TEMPERAMENTS[s.temperament] || {}).desc || '';
  $('stretch-desc').textContent = (STRETCH_PRESETS[s.stretch] || {}).desc || '';
  $('custom-oct').hidden = s.stretch !== 'custom';
  $('set-root').disabled = s.temperament === 'et';
  $('out-extra-treble').textContent = fmtC(Number(s.extraTreble), 0) + ' cent vid C8';
  $('out-extra-bass').textContent = (Number(s.extraBass) ? '−' + num(Number(s.extraBass), 0) : '±0') + ' cent vid A0';
  $('out-overpull').textContent = s.overpull + ' %';
}

function renderRef() {
  const ref = Number(S().refA4);
  if (document.activeElement !== $('set-ref')) $('set-ref').value = ref.toFixed(1);
  const c = centsBetween(ref, 440);
  $('ref-cents').textContent = Math.abs(c) < 0.05 ? 'Standardstämton' : `${fmtC(c)} cent mot 440 Hz`;
  for (const b of $('ref-presets').children) b.classList.toggle('on', Number(b.dataset.hz) === ref);

  // Råd om pianot ligger långt från målet.
  const mid = [];
  for (let k = 28; k <= 64; k++) {
    const d = beforeDev(k);
    if (Number.isFinite(d)) mid.push(d);
  }
  const adv = $('ref-advice');
  if (mid.length >= 3) {
    const m = median(mid);
    const hz = ref * 2 ** (m / 1200);
    adv.textContent =
      Math.abs(m) < 3
        ? `Pianot låg nära målet (${fmtC(m)} cent i mitten) när omgången började.`
        : `Pianot låg ${fmtC(m)} cent från målet i mitten (≈ A4 = ${fmtHz(hz, 1)}). ` +
          (m < -15
            ? 'Sänk referensen för en snabb stämning, eller dra upp med 20–30 % överdrag och räkna med en andra omgång.'
            : 'Små avvikelser stäms direkt utan överdrag.');
  } else {
    adv.textContent = 'Kartlägg eller mät några tangenter i mitten så kan appen föreslå en referens som passar pianot.';
  }
}

function renderKeyInfo() {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const fp = partialFreq(T.freq[k], T.B[k], n);
  $('note-name').textContent = kName(k);
  $('note-sub').textContent = `tangent ${k} · mål ${fmtC(T.cents[k])} cent`;
  const g = goal(k);
  $('targetline').textContent =
    `Grundton ${fmtHz(T.freq[k])}` +
    (n > 1 ? ` · delton ${n} ${fmtHz(fp)}` : '') +
    (g ? ` · överdrag ${fmtC(g)} cent` : '');
  $('partial-val').textContent = n;
  const measured = state.tuning.inharmonicity[k];
  $('bval').textContent = `B = ${T.B[k].toExponential(2).replace('.', ',')}` + (measured ? ' (uppmätt)' : ' (modell)');
}

function renderKeyboard() {
  const cur = state.key;
  for (const el of $('keyboard').children) {
    const k = Number(el.dataset.k);
    el.dataset.s = statusClass(statusDev(k));
    el.classList.toggle('current', k === cur);
    el.classList.toggle('has-b', !!state.tuning.inharmonicity[k]);
    const lbl = el.firstChild;
    if (lbl) lbl.textContent = pitchClass(k) === 0 || k === 1 ? kName(k) : '';
    el.setAttribute('aria-label', `${kName(k)}, ${Number.isFinite(curDev(k)) ? fmtC(statusDev(k)) + ' cent' : 'ej mätt'}`);
    el.setAttribute('aria-current', k === cur ? 'true' : 'false');
    el.title = el.getAttribute('aria-label');
  }
  const curEl = $('keyboard').children[cur - 1];
  const marker = $('kb-marker');
  marker.style.left = `calc(10px + (100% - 20px) * ${Number(curEl.dataset.cx) / 100})`;
  marker.dataset.s = statusClass(statusDev(cur));
  $('kb-marker-name').textContent = kName(cur);
  // Håll aktuell tangent synlig när klaviaturen scrollar (smala skärmar).
  const sc = $('kb-scroll');
  if (sc.scrollWidth > sc.clientWidth) {
    const x = (Number(curEl.dataset.cx) / 100) * sc.scrollWidth - sc.clientWidth / 2;
    sc.scrollTo({ left: x, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }
}

function renderPass() {
  let measured = 0;
  let ok = 0;
  for (let k = 1; k <= KEY_COUNT; k++) {
    const d = statusDev(k);
    if (!Number.isFinite(d)) continue;
    measured++;
    if (statusClass(d) === 'good') ok++;
  }
  const since = new Date(state.tuning.passStartedAt || state.tuning.createdAt);
  $('pass-stats').replaceChildren(
    stat(`${ok}/88`, 'inom tolerans'),
    stat(`${measured}`, 'uppmätta'),
    stat(since.toLocaleDateString('sv-SE'), 'påbörjad'),
  );
  const h = $('history');
  h.replaceChildren(
    ...[...state.tuning.history].reverse().map((p) => {
      const li = document.createElement('li');
      const d = new Date(p.startedAt).toLocaleDateString('sv-SE');
      li.textContent =
        `${d}: ${p.measured} tangenter, ref ${num(p.refA4, 1)} Hz, ` +
        `före ${num(p.meanAbsBefore)} cent → efter ${num(p.meanAbsAfter)} cent i snitt`;
      return li;
    }),
  );
}

function stat(v, l) {
  const d = document.createElement('div');
  d.className = 'stat';
  const b = document.createElement('b');
  b.textContent = v;
  const s = document.createElement('span');
  s.textContent = l;
  d.append(b, s);
  return d;
}

function renderTable() {
  const T = state.T;
  const head = document.createElement('thead');
  head.innerHTML = '<tr><th>Tangent</th><th>Ton</th><th>Mål (cent)</th><th>Mål (Hz)</th><th>B</th><th>Delton</th><th>Före</th><th>Nu</th></tr>';
  const body = document.createElement('tbody');
  for (let k = KEY_COUNT; k >= 1; k--) {
    const tr = document.createElement('tr');
    const cells = [
      k,
      kName(k),
      fmtC(T.cents[k]),
      T.freq[k].toFixed(2).replace('.', ','),
      T.B[k].toExponential(2).replace('.', ',') + (state.tuning.inharmonicity[k] ? ' *' : ''),
      partialOf(k),
      fmtC(beforeDev(k)),
      fmtC(statusDev(k)),
    ];
    for (const c of cells) {
      const td = document.createElement('td');
      td.textContent = c;
      tr.append(td);
    }
    tr.lastChild.dataset.s = statusClass(statusDev(k));
    if (k === state.key) tr.className = 'current';
    body.append(tr);
  }
  $('ktable').replaceChildren(head, body);
}

// ---------------------------------------------------------------------------
// Tangentval

function resetReadings() {
  state.readings = [];
  state.spec = [];
  state.beatHz = NaN;
  state.display = NaN;
  state.stable = false;
  state.partialDevs = [];
  state.bReadings = [];
}

function selectKey(k, manual = true) {
  k = Math.max(1, Math.min(KEY_COUNT, k));
  if (manual && state.mode === 'auto') setMode('lock');
  if (k === state.key) return;
  state.key = k;
  resetReadings();
  if (state.map) state.map = { start: performance.now(), waitAttack: true };
  renderKeyInfo();
  renderKeyboard();
  drawChart();
  if ($('table-details').open) renderTable();
}

function setMode(m) {
  state.mode = m;
  $('mode-auto').setAttribute('aria-pressed', m === 'auto');
  $('mode-lock').setAttribute('aria-pressed', m === 'lock');
  $('mode-map').setAttribute('aria-pressed', m === 'map');
  state.map = m === 'map' ? { start: performance.now(), waitAttack: false } : null;
  state.bReadings = [];
  const info = $('map-info');
  info.hidden = m !== 'map';
  if (m === 'map') {
    info.textContent =
      'Kartläggning: slå an den markerade tangenten kraftigt och låt den klinga. När den är mätt går appen vidare till nästa. Använd › för att hoppa över.';
  }
}

// ---------------------------------------------------------------------------
// Ljud

async function startMic() {
  if (!navigator.mediaDevices?.getUserMedia) {
    message('Mikrofonen kräver en säker anslutning (https). Öppna appen via https.', 'error', 0);
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 },
    });
    const ctx = new AudioContext();
    const src = ctx.createMediaStreamSource(stream);
    const an = ctx.createAnalyser();
    an.fftSize = 32768;
    an.smoothingTimeConstant = 0;
    src.connect(an);
    state.audio = { ctx, stream, an };
    state.buf = new Float32Array(an.fftSize);
    state.analyzer = new Analyzer(ctx.sampleRate);
    state.noise = -70;
    state.timer = setInterval(processFrame, FRAME_MS);
    $('btn-mic').textContent = 'Stoppa mikrofon';
    $('btn-mic').classList.remove('primary');
    try { state.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* valfritt */ }
  } catch (e) {
    message(
      e.name === 'NotAllowedError'
        ? 'Mikrofonen nekades. Tillåt mikrofonen för sidan via ikonen i adressfältet och försök igen.'
        : `Kunde inte starta mikrofonen: ${e.message}`,
      'error',
      0,
    );
  }
}

function stopMic() {
  clearInterval(state.timer);
  state.audio?.stream.getTracks().forEach((t) => t.stop());
  state.audio?.ctx.close();
  state.audio = null;
  state.signal = false;
  state.wakeLock?.release?.().catch(() => {});
  state.wakeLock = null;
  $('btn-mic').textContent = 'Starta mikrofon';
  $('btn-mic').classList.add('primary');
  updateReadout();
}

function processFrame() {
  state.frameCol = null;
  analyseFrame();
  state.spec.push(state.frameCol);
  if (state.spec.length > SPEC_COLS) state.spec.shift();
}

function analyseFrame() {
  const { an } = state.audio;
  an.getFloatTimeDomainData(state.buf);
  const lvl = rmsDb(state.buf);
  state.prevLevel = state.level;
  state.level = lvl;
  // Brusgolv: följer snabbt nedåt och långsamt uppåt.
  state.noise = lvl < state.noise ? lvl : state.noise + Math.min(0.15, (lvl - state.noise) * 0.01);
  const onset = lvl - state.prevLevel > 6;
  if (state.map?.waitAttack) {
    if (!onset) return idle();
    state.map.waitAttack = false;
    state.map.start = performance.now();
  }
  if (lvl < Math.max(state.noise + 10, -72)) return idle();

  const A = state.analyzer;
  A.load(state.buf);

  if (state.mode === 'auto') {
    const d = A.detectKey(state.T, state.key);
    if (d.score > 8) {
      if (d.key === state.cand) state.candCount++;
      else {
        state.cand = d.key;
        state.candCount = 1;
      }
      if (state.candCount >= 2 && d.key !== state.key) selectKey(d.key, false);
    }
  }
  measureCurrent(A);
}

function idle() {
  state.signal = false;
  updateReadout();
}

function measureCurrent(A) {
  const k = state.key;
  const T = state.T;
  const n = partialOf(k);
  const target = partialFreq(T.freq[k], T.B[k], n);
  const m = A.measure(target, state.mode === 'auto' ? 50 : 90, 8);
  if (!m) return idle();

  const raw = centsBetween(m.freq, target);
  state.readings.push({ c: raw, hz: m.freq });
  if (state.readings.length > 7) state.readings.shift();
  const last = state.readings.slice(-5).map((r) => r.c);
  const med = median(last);
  const spread = Math.max(...last) - Math.min(...last);
  state.signal = true;
  state.stable = last.length >= 4 && spread < (k > 70 ? 1.5 : 0.8);
  const g = goal(k);
  state.display = med - g;
  // Svävningsvyn centreras på målet (inklusive ev. överdrag).
  const center = target * 2 ** (g / 1200);
  state.beatHz = center * (2 ** (state.display / 1200) - 1);
  state.frameCol = { col: A.zoom(center, SPEC_CENTS, SPEC_BINS), c: state.display };

  state.partialDevs = [];
  for (let i = 1; i <= 8; i++) {
    const fi = partialFreq(T.freq[k], T.B[k], i);
    if (fi > A.sr * 0.45 || fi < 40) {
      state.partialDevs.push(null);
      continue;
    }
    const mi = i === n ? m : A.measure(fi, 50, 8);
    state.partialDevs.push(mi ? centsBetween(mi.freq, fi) : null);
  }

  if (state.stable) recordKey(k, n, state.readings[state.readings.length - 1].hz);

  // Inharmonicitet (kartläggning eller manuell mätning).
  const wantB = state.map || (state.measureB && state.measureB.k === k);
  if (wantB) {
    const f1 = T.freq[k] * 2 ** (raw / 1200);
    const r = A.inharmonicity(f1, T.B[k]);
    if (r) state.bReadings.push(r.B);
  }
  if (state.map) mapStep(k);
  if (state.measureB && performance.now() > state.measureB.until) finishMeasureB();

  updateReadout();
}

function recordKey(k, n, hz) {
  const rec = state.tuning.keys[k] || {};
  if (!rec.bhz) {
    rec.bhz = hz;
    rec.bn = n;
  }
  rec.hz = hz;
  rec.n = n;
  rec.at = Date.now();
  state.tuning.keys[k] = rec;
  markDirty();
  renderKeyStatus(k);
}

let statusRaf = 0;
function renderKeyStatus() {
  if (statusRaf) return;
  statusRaf = requestAnimationFrame(() => {
    statusRaf = 0;
    renderKeyboard();
    renderPass();
    drawChart();
  });
}

function storeB(k, B) {
  state.tuning.inharmonicity[k] = Number(B.toPrecision(4));
  state.T = computeTargets(S(), state.tuning.inharmonicity);
  markDirty();
  renderKeyInfo();
  renderKeyboard();
  drawChart();
}

function mapStep(k) {
  const elapsed = performance.now() - state.map.start;
  const enoughB = state.bReadings.length >= 5;
  const recorded = !!keyRec(k)?.bhz;
  if ((enoughB && recorded) || (elapsed > 5000 && recorded)) {
    if (state.bReadings.length >= 3) storeB(k, median(state.bReadings));
    flashKey(k);
    if (k >= KEY_COUNT) {
      setMode('lock');
      message('Kartläggningen är klar. Målkurvan bygger nu på pianots egen inharmonicitet.', 'ok');
      renderRef();
      return;
    }
    selectKey(k + 1, false);
    renderRef();
  }
}

function finishMeasureB() {
  const k = state.measureB.k;
  state.measureB = null;
  $('btn-measure-b').disabled = false;
  if (state.bReadings.length >= 3) {
    const B = median(state.bReadings);
    storeB(k, B);
    message(`Inharmonicitet för ${kName(k)}: B = ${B.toExponential(2).replace('.', ',')}`, 'ok');
  } else {
    message('Kunde inte mäta inharmonicitet. Slå an tangenten kraftigt och låt den klinga i ett par sekunder.', 'warn');
  }
  state.bReadings = [];
}

function flashKey(k) {
  const el = $('keyboard').children[k - 1];
  el.classList.remove('flash');
  void el.offsetWidth;
  el.classList.add('flash');
}

function playTone() {
  const k = state.key;
  const T = state.T;
  const ctx = state.audio?.ctx || (state.toneCtx ||= new AudioContext());
  ctx.resume?.();
  const now = ctx.currentTime;
  const out = ctx.createGain();
  out.gain.value = 0.22;
  out.connect(ctx.destination);
  const f1 = T.freq[k] * 2 ** (goal(k) / 1200);
  for (let n = 1; n <= 10; n++) {
    const f = partialFreq(f1, T.B[k], n);
    if (f > ctx.sampleRate * 0.45) break;
    const osc = ctx.createOscillator();
    osc.frequency.value = f;
    const g = ctx.createGain();
    const amp = 1 / n ** 1.1;
    const decay = Math.max(0.4, 3.2 - n * 0.25);
    g.gain.setValueAtTime(0.0001, now);
    g.gain.exponentialRampToValueAtTime(amp, now + 0.008);
    g.gain.exponentialRampToValueAtTime(0.0001, now + decay);
    osc.connect(g).connect(out);
    osc.start(now);
    osc.stop(now + decay + 0.05);
  }
}

// ---------------------------------------------------------------------------
// Visning

function updateReadout() {
  const el = $('cents-num');
  const pill = $('status-pill');
  if (!state.audio) {
    el.textContent = '–';
    pill.dataset.s = 'idle';
    pill.textContent = 'Starta mikrofonen';
  } else if (!state.signal) {
    el.textContent = Number.isFinite(state.display) ? fmtC(state.display) : '–';
    pill.dataset.s = 'idle';
    pill.textContent = state.map?.waitAttack ? `Slå an ${kName(state.key)}` : 'Lyssnar …';
  } else {
    el.textContent = fmtC(state.display);
    const s = statusClass(state.display);
    pill.dataset.s = s;
    pill.textContent = s === 'good' ? 'I stäm' : state.display > 0 ? 'För högt, släpp efter' : 'För lågt, dra upp';
  }
  $('cents').dataset.live = state.signal ? '1' : '0';
  $('level-bar').style.width = `${Math.max(0, Math.min(100, (state.level + 80) * 1.4))}%`;
  renderPartials();
}

function renderPartials() {
  const box = $('partials');
  if (box.children.length !== 8) {
    box.replaceChildren(
      ...Array.from({ length: 8 }, (_, i) => {
        const d = document.createElement('div');
        d.className = 'pcell';
        const n = document.createElement('span');
        n.className = 'pn';
        n.textContent = i + 1;
        const v = document.createElement('span');
        v.className = 'pv';
        d.append(n, v);
        return d;
      }),
    );
  }
  const n = partialOf(state.key);
  [...box.children].forEach((cell, i) => {
    const d = state.partialDevs[i];
    cell.classList.toggle('sel', i + 1 === n);
    cell.lastChild.textContent = d == null || !state.signal ? '–' : fmtC(d);
    cell.dataset.s = d == null || !state.signal ? 'none' : statusClass(d);
  });
}

function readColors() {
  const cs = getComputedStyle(document.documentElement);
  for (const t of ['ink', 'muted', 'faint', 'line', 'surface', 'accent', 'good', 'warn', 'bad', 'stripe', 'stripe2', 'scale-yellow', 'scale-orange']) {
    state.colors[t] = cs.getPropertyValue('--' + t).trim();
  }
  state.colors.goodRgb = hexRgb(state.colors.good);
  state.colors.yellowRgb = hexRgb(state.colors['scale-yellow']);
  state.colors.orangeRgb = hexRgb(state.colors['scale-orange']);
  state.colors.badRgb = hexRgb(state.colors.bad);
}

function fitCanvas(c) {
  const dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth;
  const h = Number(c.getAttribute('height'));
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
    c.style.height = h + 'px';
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w, h };
}

// Mätare: komprimerad skala så att mitten (±5 cent) får mest plats.
const meterX = (c, w) => w / 2 + Math.sign(c) * Math.sqrt(Math.min(Math.abs(c), 50) / 50) * (w / 2 - 14);

function drawMeter() {
  const { ctx, w, h } = fitCanvas($('meter'));
  const C = state.colors;
  ctx.clearRect(0, 0, w, h);
  const tol = Number(S().tolerance) || 1;
  const y = 30;
  ctx.fillStyle = C.good;
  ctx.globalAlpha = 0.18;
  ctx.fillRect(meterX(-tol, w), 8, meterX(tol, w) - meterX(-tol, w), 34);
  ctx.globalAlpha = 1;
  ctx.font = '11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
  ctx.textAlign = 'center';
  for (const t of [-50, -20, -10, -5, -2, -1, 0, 1, 2, 5, 10, 20, 50]) {
    const x = meterX(t, w);
    ctx.strokeStyle = t === 0 ? C.ink : C.muted;
    ctx.lineWidth = t === 0 ? 2 : 1;
    ctx.beginPath();
    ctx.moveTo(x, t === 0 ? 6 : 16);
    ctx.lineTo(x, 42);
    ctx.stroke();
    if (Math.abs(t) !== 1 || w > 500) {
      ctx.fillStyle = C.muted;
      ctx.fillText(t === 0 ? '0' : (t > 0 ? '+' : '−') + Math.abs(t), x, 58);
    }
  }
  if (Number.isFinite(state.display)) {
    const x = meterX(state.display, w);
    ctx.globalAlpha = state.signal ? 1 : 0.35;
    ctx.fillStyle = scaleColor(state.display);
    ctx.beginPath();
    ctx.moveTo(x, y + 12);
    ctx.lineTo(x - 7, y - 18);
    ctx.lineTo(x + 7, y - 18);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 1;
  }
}

// Stroboskop: tre band som rör sig med 1, 2 och 4 gånger hastigheten.
// Står de stilla är tonen i stäm; åt höger = för högt.
function drawStrobe(dt) {
  const { ctx, w, h } = fitCanvas($('strobe'));
  const C = state.colors;
  ctx.clearRect(0, 0, w, h);
  const live = state.signal && Number.isFinite(state.display);
  const c = live ? Math.max(-30, Math.min(30, state.display)) : 0;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const bandH = (h - 8) / 3;
  const period = 28;
  for (let i = 0; i < 3; i++) {
    const speed = reduced ? 0 : c * 9 * 2 ** i;
    state.strobePhase[i] = (state.strobePhase[i] + speed * dt) % (period * 2);
    const y = 2 + i * (bandH + 2);
    ctx.fillStyle = C.stripe2;
    ctx.fillRect(0, y, w, bandH);
    ctx.fillStyle = live ? scaleColor(state.display) : C.faint;
    const p = state.strobePhase[i] / 2 ** i;
    const per = period / 2 ** (i * 0.5);
    for (let x = -per * 2 + (((p % per) + per) % per); x < w; x += per) {
      ctx.fillRect(x, y, per / 2, bandH);
    }
  }
}

// Färgskala för avvikelse: grönt inom tolerans, sedan gult, orange och rött.
function hexRgb(hex) {
  const h = hex.replace('#', '');
  const v = parseInt(h.length === 3 ? h.replace(/./g, '$&$&') : h, 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

function scaleRgb(c) {
  const C = state.colors;
  const tol = Number(S().tolerance) || 1;
  const a = Math.abs(c);
  const stops = [
    [tol, C.goodRgb],
    [Math.max(3, tol * 2.5), C.yellowRgb],
    [Math.max(6, tol * 5), C.orangeRgb],
    [Math.max(12, tol * 10), C.badRgb],
  ];
  if (a <= stops[0][0]) return stops[0][1];
  for (let i = 1; i < stops.length; i++) {
    if (a <= stops[i][0]) {
      const [x0, c0] = stops[i - 1];
      const [x1, c1] = stops[i];
      const t = (a - x0) / (x1 - x0);
      return c0.map((v, j) => Math.round(v + (c1[j] - v) * t));
    }
  }
  return stops[stops.length - 1][1];
}
const scaleColor = (c) => `rgb(${scaleRgb(c).join(' ')})`;

// Zoomat spektrogram runt måldeltonen. Ljusstyrkan är signalstyrkan (relativt
// kolumnens topp), färgen är hur långt från målet tonen låg i just det ögonblicket.
const specImg = { canvas: null, ctx: null, data: null };

function drawSpectro() {
  const { ctx, w, h } = fitCanvas($('spectro'));
  const C = state.colors;
  ctx.clearRect(0, 0, w, h);
  const padL = 30;
  const pw = w - padL;
  if (!specImg.canvas) {
    specImg.canvas = document.createElement('canvas');
    specImg.canvas.width = SPEC_COLS;
    specImg.canvas.height = SPEC_BINS;
    specImg.ctx = specImg.canvas.getContext('2d');
    specImg.data = specImg.ctx.createImageData(SPEC_COLS, SPEC_BINS);
  }
  const px = specImg.data.data;
  px.fill(0);
  const offset = SPEC_COLS - state.spec.length;
  state.spec.forEach((s, i) => {
    if (!s) return;
    const x = offset + i;
    const peak = Math.max(...s.col);
    const [r, g, b] = scaleRgb(s.c);
    for (let y = 0; y < SPEC_BINS; y++) {
      const v = Math.max(0, Math.min(1, (s.col[y] - peak + 30) / 30)) ** 1.8;
      const o = (y * SPEC_COLS + x) * 4;
      px[o] = r;
      px[o + 1] = g;
      px[o + 2] = b;
      px[o + 3] = Math.round(v * 255);
    }
  });
  specImg.ctx.putImageData(specImg.data, 0, 0);
  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(specImg.canvas, padL, 0, pw, h);

  const ym = (c) => h / 2 - (c / SPEC_CENTS) * (h / 2);
  const tol = Number(S().tolerance) || 1;
  ctx.strokeStyle = C.muted;
  ctx.lineWidth = 1;
  ctx.setLineDash([2, 4]);
  for (const c of [-tol, tol]) {
    ctx.beginPath();
    ctx.moveTo(padL, ym(c));
    ctx.lineTo(w, ym(c));
    ctx.stroke();
  }
  ctx.setLineDash([]);
  ctx.strokeStyle = C.ink;
  ctx.globalAlpha = 0.5;
  ctx.beginPath();
  ctx.moveTo(padL, h / 2);
  ctx.lineTo(w, h / 2);
  ctx.stroke();
  ctx.globalAlpha = 1;

  // Exakt uppmätt avvikelse som tunn linje ovanpå.
  const colW = pw / SPEC_COLS;
  ctx.strokeStyle = C.ink;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  let drawing = false;
  state.spec.forEach((s, i) => {
    if (!s) {
      drawing = false;
      return;
    }
    const x = padL + (offset + i + 0.5) * colW;
    const y = ym(Math.max(-SPEC_CENTS, Math.min(SPEC_CENTS, s.c)));
    if (drawing) ctx.lineTo(x, y);
    else ctx.moveTo(x, y);
    drawing = true;
  });
  ctx.stroke();

  ctx.fillStyle = C.muted;
  ctx.font = '10px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
  ctx.textAlign = 'right';
  ctx.fillText('+' + SPEC_CENTS, padL - 4, 11);
  ctx.fillText('0', padL - 4, h / 2 + 3);
  ctx.fillText('−' + SPEC_CENTS, padL - 4, h - 3);
}

// Svävningsremsa: hur det låter mot måltonen. Två toner som skiljer Δf Hz
// pulserar Δf gånger per sekund; remsan visar de senaste 3 sekunderna.
function drawBeat(dt) {
  const { ctx, w, h } = fitCanvas($('beat'));
  const C = state.colors;
  ctx.clearRect(0, 0, w, h);
  const live = state.signal && Number.isFinite(state.beatHz);
  const rateEl = $('beat-rate');
  if (!live) {
    rateEl.textContent = '–';
    ctx.strokeStyle = C.faint;
    ctx.beginPath();
    ctx.moveTo(0, h / 2);
    ctx.lineTo(w, h / 2);
    ctx.stroke();
    return;
  }
  const df = Math.abs(state.beatHz);
  rateEl.textContent = df < 0.1 ? 'Svävningsfritt' : `${num(df, df < 10 ? 1 : 0)} svävningar/s`;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!reduced) state.beatPhase = (state.beatPhase + Math.min(df, 40) * dt) % 1000;
  const span = 3;
  ctx.fillStyle = scaleColor(state.display);
  ctx.globalAlpha = 0.85;
  ctx.beginPath();
  const top = [];
  for (let x = 0; x <= w; x += 2) {
    const phi = state.beatPhase - (Math.min(df, 40) * (w - x) * span) / w;
    const env = df < 0.1 ? 1 : Math.abs(Math.cos(Math.PI * phi));
    top.push([x, h / 2 - env * (h / 2 - 3)]);
  }
  top.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
  for (let i = top.length - 1; i >= 0; i--) ctx.lineTo(top[i][0], h - top[i][1]);
  ctx.closePath();
  ctx.fill();
  ctx.globalAlpha = 1;
}

// Stämkurva: mål i cent mot liksvävande, plus uppmätta lägen.
const chart = { pad: { l: 44, r: 12, t: 12, b: 28 }, yMin: -30, yMax: 30 };

function drawChart() {
  if (!state.T) return;
  const { ctx, w, h } = fitCanvas($('chart'));
  const C = state.colors;
  const T = state.T;
  const { pad } = chart;
  ctx.clearRect(0, 0, w, h);

  const vals = [];
  for (let k = 1; k <= KEY_COUNT; k++) {
    vals.push(T.cents[k]);
    const d = curDev(k);
    if (Number.isFinite(d)) vals.push(T.cents[k] + d);
  }
  const lo = Math.min(-10, ...vals);
  const hi = Math.max(10, ...vals);
  const step = hi - lo > 80 ? 20 : 10;
  chart.yMin = Math.floor(lo / step) * step;
  chart.yMax = Math.ceil(hi / step) * step;
  const xm = (k) => pad.l + ((k - 1) / (KEY_COUNT - 1)) * (w - pad.l - pad.r);
  const ym = (c) => pad.t + ((chart.yMax - c) / (chart.yMax - chart.yMin)) * (h - pad.t - pad.b);
  chart.xm = xm;
  chart.ym = ym;

  ctx.font = '11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
  ctx.lineWidth = 1;
  ctx.textAlign = 'right';
  for (let c = chart.yMin; c <= chart.yMax; c += step) {
    ctx.strokeStyle = c === 0 ? C.muted : C.line;
    ctx.beginPath();
    ctx.moveTo(pad.l, ym(c));
    ctx.lineTo(w - pad.r, ym(c));
    ctx.stroke();
    ctx.fillStyle = C.muted;
    ctx.fillText(c === 0 ? '0' : (c > 0 ? '+' : '−') + Math.abs(c), pad.l - 6, ym(c) + 4);
  }
  ctx.textAlign = 'center';
  for (let k = 1; k <= KEY_COUNT; k++) {
    if (pitchClass(k) !== 0) continue;
    const x = xm(k);
    ctx.strokeStyle = C.line;
    ctx.beginPath();
    ctx.moveTo(x, h - pad.b);
    ctx.lineTo(x, h - pad.b + 4);
    ctx.stroke();
    if (w > 420 || octave(k) % 2 === 0) {
      ctx.fillStyle = C.muted;
      ctx.fillText(kName(k), x, h - 8);
    }
  }

  // Aktuell tangent.
  ctx.strokeStyle = C.accent;
  ctx.globalAlpha = 0.35;
  ctx.setLineDash([3, 3]);
  ctx.beginPath();
  ctx.moveTo(xm(state.key), pad.t);
  ctx.lineTo(xm(state.key), h - pad.b);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;

  // Mål: en linje per tangent följer temperaturens taggighet.
  ctx.strokeStyle = C.accent;
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.beginPath();
  for (let k = 1; k <= KEY_COUNT; k++) {
    const x = xm(k);
    const y = ym(T.cents[k]);
    if (k === 1) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  // Uppmätt: punkt i statusfärg med ring i ytfärg.
  for (let k = 1; k <= KEY_COUNT; k++) {
    const d = curDev(k);
    if (!Number.isFinite(d)) continue;
    const x = xm(k);
    const y = ym(T.cents[k] + d);
    ctx.fillStyle = C.surface;
    ctx.beginPath();
    ctx.arc(x, y, 5.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = C[statusClass(statusDev(k))];
    ctx.beginPath();
    ctx.arc(x, y, 4, 0, Math.PI * 2);
    ctx.fill();
  }
}

function chartHover(e) {
  if (!chart.xm) return;
  const c = $('chart');
  const r = c.getBoundingClientRect();
  const x = e.clientX - r.left;
  const { pad } = chart;
  const w = r.width;
  const k = Math.round(((x - pad.l) / (w - pad.l - pad.r)) * (KEY_COUNT - 1)) + 1;
  const tip = $('tooltip');
  if (k < 1 || k > KEY_COUNT) {
    tip.hidden = true;
    return;
  }
  const T = state.T;
  const d = curDev(k);
  tip.replaceChildren();
  const rows = [
    [kName(k), `tangent ${k}`],
    ['Mål', `${fmtC(T.cents[k])} cent · ${fmtHz(T.freq[k])}`],
    ['B', T.B[k].toExponential(2).replace('.', ',') + (state.tuning.inharmonicity[k] ? ' uppmätt' : ' modell')],
  ];
  if (Number.isFinite(d)) rows.push(['Avvikelse', `${fmtC(statusDev(k))} cent`]);
  for (const [a, b] of rows) {
    const row = document.createElement('div');
    const s1 = document.createElement('b');
    s1.textContent = a;
    const s2 = document.createElement('span');
    s2.textContent = b;
    row.append(s1, s2);
    tip.append(row);
  }
  tip.hidden = false;
  const tx = Math.min(Math.max(chart.xm(k) + 12, 4), w - tip.offsetWidth - 4);
  tip.style.left = tx + 'px';
  tip.style.top = Math.max(4, chart.ym(T.cents[k]) - tip.offsetHeight - 10) + 'px';
}

function animate(t) {
  const dt = state.lastAnim ? Math.min(0.1, (t - state.lastAnim) / 1000) : 0;
  state.lastAnim = t;
  if (state.tuning) {
    drawMeter();
    drawStrobe(dt);
    drawSpectro();
    drawBeat(dt);
  }
  requestAnimationFrame(animate);
}

// ---------------------------------------------------------------------------
// Händelser

function setSetting(key, value) {
  S()[key] = value;
  recompute();
  renderSettingDescs();
  markDirty();
}

function setRef(hz) {
  hz = Math.round(Math.max(380, Math.min(480, hz)) * 10) / 10;
  if (!Number.isFinite(hz)) return;
  setSetting('refA4', hz);
}

function fitRefToPiano() {
  const mid = [];
  for (let k = 28; k <= 64; k++) {
    const d = beforeDev(k);
    if (Number.isFinite(d)) mid.push(d);
  }
  let shift;
  if (mid.length >= 3) shift = median(mid);
  else if (state.signal && Number.isFinite(state.display)) shift = state.display + goal(state.key);
  else {
    message('Spela A4 (eller kartlägg några tangenter i mitten) så kan appen mäta pianots tonhöjd.', 'warn');
    return;
  }
  const hz = Number(S().refA4) * 2 ** (shift / 1200);
  setRef(hz);
  message(`Referensen satt till ${fmtHz(Number(S().refA4), 1)} efter pianots nuvarande tonhöjd.`, 'ok');
}

function newPass() {
  const t = state.tuning;
  let n = 0;
  let sb = 0;
  let sa = 0;
  let nb = 0;
  for (let k = 1; k <= KEY_COUNT; k++) {
    const a = statusDev(k);
    const b = beforeDev(k);
    if (Number.isFinite(a)) {
      n++;
      sa += Math.abs(a);
    }
    if (Number.isFinite(b)) {
      nb++;
      sb += Math.abs(b);
    }
  }
  if (n) {
    t.history.push({
      startedAt: t.passStartedAt,
      endedAt: new Date().toISOString(),
      refA4: Number(S().refA4),
      measured: n,
      meanAbsBefore: nb ? sb / nb : 0,
      meanAbsAfter: sa / n,
    });
    t.history = t.history.slice(-30);
  }
  t.keys = {};
  t.passStartedAt = new Date().toISOString();
  resetReadings();
  recompute();
  markDirty();
  message('Ny omgång påbörjad. Inharmonicitet och inställningar är kvar.', 'ok');
}

function exportTuning() {
  const blob = new Blob([JSON.stringify(state.tuning, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = (state.tuning.name || 'stamning').replace(/[^\wåäöÅÄÖ-]+/g, '_') + '.json';
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

async function importTuning(file) {
  try {
    const data = JSON.parse(await file.text());
    if (!data || typeof data !== 'object' || !data.settings) throw new Error('saknar inställningar');
    const t = duplicateTuning(data, (data.name || 'Importerad') + (state.list.some((x) => x.id === data.id) ? ' (import)' : ''));
    t.keys = data.keys || {};
    t.history = data.history || [];
    await createAndOpen(t);
    message(`Importerade "${t.name}".`, 'ok');
  } catch (e) {
    message(`Kunde inte importera filen: ${e.message}`, 'error');
  }
}

function bindEvents() {
  $('btn-mic').addEventListener('click', () => (state.audio ? stopMic() : startMic()));
  $('btn-prev').addEventListener('click', () => selectKey(state.key - 1));
  $('btn-next').addEventListener('click', () => selectKey(state.key + 1));
  $('mode-auto').addEventListener('click', () => setMode('auto'));
  $('mode-lock').addEventListener('click', () => setMode('lock'));
  $('mode-map').addEventListener('click', () => {
    setMode('map');
    if (!state.audio) startMic();
  });
  $('keyboard').addEventListener('click', (e) => {
    const k = Number(e.target.closest('.key')?.dataset.k);
    if (k) selectKey(k);
  });

  const setPartial = (d) => {
    const k = state.key;
    const n = Math.max(1, Math.min(8, partialOf(k) + d));
    if (n === defaultPartial(k)) delete state.tuning.partials[k];
    else state.tuning.partials[k] = n;
    resetReadings();
    renderKeyInfo();
    markDirty();
  };
  $('partial-dec').addEventListener('click', () => setPartial(-1));
  $('partial-inc').addEventListener('click', () => setPartial(1));
  $('btn-tone').addEventListener('click', playTone);
  $('btn-measure-b').addEventListener('click', () => {
    if (!state.audio) {
      message('Starta mikrofonen först.', 'warn');
      return;
    }
    state.bReadings = [];
    state.measureB = { k: state.key, until: performance.now() + 4000 };
    $('btn-measure-b').disabled = true;
    message(`Slå an ${kName(state.key)} kraftigt och låt den klinga …`, 'info', 4000);
    setTimeout(() => state.measureB && finishMeasureB(), 6000);
  });

  // Referens
  $('set-ref').addEventListener('change', (e) => setRef(parseFloat(e.target.value.replace(',', '.'))));
  document.querySelectorAll('[data-ref]').forEach((b) =>
    b.addEventListener('click', () => setRef(Number(S().refA4) + Number(b.dataset.ref))),
  );
  $('ref-presets').addEventListener('click', (e) => {
    const hz = Number(e.target.dataset.hz);
    if (hz) setRef(hz);
  });
  $('btn-fit-ref').addEventListener('click', fitRefToPiano);

  // Inställningar
  const bindSel = (id, key, conv = (v) => v) => $(id).addEventListener('input', (e) => setSetting(key, conv(e.target.value)));
  bindSel('set-piano', 'pianoType');
  bindSel('set-temperament', 'temperament');
  bindSel('set-root', 'root', Number);
  bindSel('set-stretch', 'stretch');
  bindSel('set-bass', 'bassOctave');
  bindSel('set-mid', 'midOctave');
  bindSel('set-treble', 'trebleOctave');
  bindSel('set-extra-treble', 'extraTreble', Number);
  bindSel('set-extra-bass', 'extraBass', Number);
  bindSel('set-overpull', 'overpull', Number);
  bindSel('set-tolerance', 'tolerance', Number);
  $('set-names').addEventListener('input', (e) => {
    setSetting('noteNames', e.target.value);
    renderRootSelect();
    $('set-root').value = S().root;
  });
  $('set-name').addEventListener('input', (e) => {
    state.tuning.name = e.target.value.trim() || 'Namnlös';
    const item = state.list.find((t) => t.id === state.tuning.id);
    if (item) item.name = state.tuning.name;
    renderTuningSelect();
    markDirty();
  });
  $('set-notes').addEventListener('input', (e) => {
    state.tuning.notes = e.target.value;
    markDirty();
  });

  // Stämningar
  $('tuning-select').addEventListener('change', async (e) => {
    try {
      await openTuning(await getTuning(e.target.value));
    } catch {
      message('Kunde inte öppna stämningen.', 'error');
      renderTuningSelect();
    }
  });
  $('btn-new').addEventListener('click', () => createAndOpen(newTuning(`Piano ${state.list.length + 1}`)).catch(() => message('Kunde inte skapa stämningen.', 'error')));
  $('btn-dup').addEventListener('click', async () => {
    await flushSave();
    const t = duplicateTuning(state.tuning, state.tuning.name + ' (kopia)');
    createAndOpen(t).catch(() => message('Kunde inte duplicera.', 'error'));
  });
  $('btn-del').addEventListener('click', () => {
    $('confirm-del-text').textContent = `Radera "${state.tuning.name}" med alla mätningar? Det går inte att ångra.`;
    $('confirm-del').hidden = false;
  });
  $('confirm-del-no').addEventListener('click', () => ($('confirm-del').hidden = true));
  $('confirm-del-yes').addEventListener('click', async () => {
    $('confirm-del').hidden = true;
    try {
      clearTimeout(state.saveTimer);
      state.saveTimer = 0;
      state.dirty = false;
      await deleteTuning(state.tuning.id);
      await refreshList();
      if (state.list[0]) await openTuning(await getTuning(state.list[0].id));
      else await createAndOpen(newTuning('Mitt piano'));
      message('Stämningen raderades.', 'ok');
    } catch {
      message('Kunde inte radera stämningen.', 'error');
    }
  });

  // Omgång
  $('btn-new-pass').addEventListener('click', () => ($('confirm-pass').hidden = false));
  $('confirm-pass-no').addEventListener('click', () => ($('confirm-pass').hidden = true));
  $('confirm-pass-yes').addEventListener('click', () => {
    $('confirm-pass').hidden = true;
    newPass();
  });
  $('btn-export').addEventListener('click', exportTuning);
  $('file-import').addEventListener('change', (e) => {
    const f = e.target.files[0];
    e.target.value = '';
    if (f) importTuning(f);
  });

  // Diagram
  $('chart').addEventListener('pointermove', chartHover);
  $('chart').addEventListener('pointerleave', () => ($('tooltip').hidden = true));
  $('chart').addEventListener('click', (e) => {
    const r = $('chart').getBoundingClientRect();
    const { pad } = chart;
    const k = Math.round(((e.clientX - r.left - pad.l) / (r.width - pad.l - pad.r)) * (KEY_COUNT - 1)) + 1;
    if (k >= 1 && k <= KEY_COUNT) selectKey(k);
  });
  $('table-details').addEventListener('toggle', () => $('table-details').open && renderTable());

  // Tangentbord
  document.addEventListener('keydown', (e) => {
    if (e.target.closest('input, select, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'ArrowLeft') selectKey(state.key - 1);
    else if (e.key === 'ArrowRight') selectKey(state.key + 1);
    else if (e.key === 'l' || e.key === 'L') setMode('lock');
    else if (e.key === 'a' || e.key === 'A') setMode('auto');
    else if (e.key === 't' || e.key === 'T') playTone();
    else return;
    e.preventDefault();
  });

  window.addEventListener('resize', () => drawChart());
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    readColors();
    drawChart();
  });
  document.addEventListener('visibilitychange', async () => {
    if (document.visibilityState === 'hidden') flushSave();
    else if (state.audio && !state.wakeLock) {
      try { state.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* valfritt */ }
    }
  });
  window.addEventListener('pagehide', () => {
    if (state.dirty && state.tuning) {
      navigator.sendBeacon?.(
        'api/tunings/' + encodeURIComponent(state.tuning.id) + '?beacon=1',
        new Blob([JSON.stringify(state.tuning)], { type: 'application/json' }),
      );
    }
  });
}

boot();
