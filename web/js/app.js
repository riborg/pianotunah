// Piano Tunah: DOM and events. What the sound means for the piano lives in
// engine.js, the sums in theory.js and dsp.js, drawing in draw.js, audio in
// mic.js/tone.js, saving in saver.js.

import {
  KEY_COUNT, TEMPERAMENTS, PIANO_KINDS, STRETCH_PRESETS, OCTAVE_TYPES, sizeClass,
  partialFreq, centsBetween, noteName, pcName, pitchClass, isBlack,
} from './theory.js';
import { listTunings, getTuning, saveTuning, deleteTuning, newTuning, normalize, duplicateTuning } from './store.js';
import { num, short, fmtC, fmtHz, fmtB, parseNum } from './format.js';
import { tr, trNodes, lang, locale, setLang, translateDom } from './i18n.js';
import { Mic } from './mic.js';
import { TonePlayer } from './tone.js';
import { Saver } from './saver.js';
import { enableDiag, diagOn, diag } from './diag.js';
import { readColors, drawDial, drawSpectro, drawBeat, drawChart } from './draw.js';
import * as survey from './survey.js';
import * as order from './order.js';
import { Engine, FRAME_MS, SPEC_COLS, SPEC_BINS, SPEC_CENTS, clampRef, clampSize, stepRange } from './engine.js';

const $ = (id) => document.getElementById(id);

const REC_MAX_S = 120;
const LS = { tuning: 'pianotunah.lastTuning', tone: 'pianotunah.toneMode', toneOnKey: 'pianotunah.toneOnKey', theme: 'pianotunah.theme', plan: 'pianotunah.mapPlan', tab: 'pianotunah.tab', curve: 'pianotunah.curve', partials: 'pianotunah.partials', beats: 'pianotunah.beats', mic: 'pianotunah.mic', order: 'pianotunah.order' };

const mic = new Mic();
const tones = new TonePlayer();
// The piano, the key, the readings, the survey and the order. What it does
// is drawn by onEngine.
const engine = new Engine({ emit: (type, e) => onEngine(type, e) });

// The page's own state; the rest is in engine.
const state = {
  list: [],
  timer: 0,
  beatPhase: 0,
  micId: '', // chosen input, '' = system default
  version: '', // the server's version when the page loaded, see checkVersion
  toneMode: 'piano', // piano | sine
  toneOnKey: false, // clicking a key also plays the tone
  refUntil: 0, // reference tone audible in the microphone until this time
  wakeLock: null,
  recTimer: 0,
  ringPhase: [0, 0, 0],
  lastAnim: 0,
  colors: {},
  chartGeo: null,
};

// ---------------------------------------------------------------------------
// Derived values

const S = () => engine.settings;
const kName = (k) => noteName(k);
const top = () => engine.top();
const partialOf = (k) => engine.partialOf(k);
const curDev = (k) => engine.curDev(k);
const statusDev = (k) => engine.statusDev(k);
const statusClass = (d) => engine.statusClass(d);
const bSource = (k) => tr(!engine.tuning.inharmonicity[k] ? 'b.model' : engine.bBad.has(k) ? 'b.outlier' : 'b.measured');
const fmtDate = (d) => d.toLocaleDateString(locale(), { dateStyle: 'medium' });

// The microphone hears the speaker (no echo cancellation). Nothing is saved
// while a reference tone sounds.
const refPlaying = () => tones.sineOn || performance.now() < state.refUntil;

// What the engine did, shown on the page.
function onEngine(type, e) {
  switch (type) {
    case 'key': return renderKeyChange();
    case 'mode': return renderMode();
    case 'targets': return renderTargets();
    case 'dirty': return markDirty();
    case 'saved':
      markDirty();
      return renderKeyStatus();
    case 'flash': return flashKey(e.k);
    case 'survey': return renderSurveyPanel();
    case 'order':
      renderOrderPanel();
      return renderKeyboard();
    case 'orderState': return renderOrderState();
    case 'measureB': return void ($('btn-measure-b').disabled = e.on);
    case 'message': return engineMessage(e);
    case 'log': return diag(e.line);
  }
}

function engineMessage(e) {
  const name = e.k ? kName(e.k) : '';
  if (e.id === 'jump') message(tr('msg.jump', { name, c: fmtC(e.c, 0) }), 'warn', 5000);
  else if (e.id === 'bOutlier') message(tr('msg.bOutlier', { name, b: fmtB(e.B) }), 'warn', 0);
  else if (e.id === 'bMeasured') message(tr('msg.bMeasured', { name, b: fmtB(e.B) }), 'ok');
  else if (e.id === 'bFailed') message(tr('msg.bFailed'), 'warn');
  else if (e.id === 'surveyDone') message(surveyDoneText(e), 'ok', 0);
  else if (e.id === 'orderDone') message(tr('order.done'), 'ok');
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

// The toast's height, for the room the page and the drawer keep free under
// their content while it shows (style.css).
new ResizeObserver(() => document.documentElement.style.setProperty('--msg-h', `${$('message').offsetHeight}px`)).observe($('message'));

// ---------------------------------------------------------------------------
// Saving

const saver = new Saver({
  current: () => engine.tuning,
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
  $('btn-settings').dataset.save = s; // the mark on phones (style.css)
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

// A tab in the background shows the tuning as it was loaded, also when the
// piano has been tuned on from another tab or device since: on return, and
// when the tuning order is opened, the server's version is shown if it is
// newer. Changes here are saved first; if the server has moved on, that save
// ends in reloadAfterConflict instead, which says the changes were not saved.
let syncing = null;
function syncTuning() {
  if (!engine.tuning || syncing) return syncing;
  syncing = (async () => {
    try {
      const t = engine.tuning;
      await saver.flush();
      const skip = () => engine.tuning !== t || saver.dirty || saver.conflicted(t);
      if (skip()) return;
      const latest = await getTuning(t.id);
      if (skip() || !(latest.rev > t.rev)) return;
      diag(`synced ${t.id} rev ${t.rev} → ${latest.rev}`);
      await openTuning(latest);
      message(tr('msg.synced'), 'info');
    } catch { /* offline: keep what is shown; the saver reports errors */ }
  })().finally(() => (syncing = null));
  return syncing;
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
  if (engine.tuning) sel.value = engine.tuning.id;
}

// On phones the piano is chosen at the top of the Piano tab: the top bar
// keeps one row, so more of the tuning order fits on the first screen.
const phoneTop = matchMedia('(max-width: 620px)');
function placeTuningSelect() {
  const label = $('tuning-label');
  label.classList.toggle('sr-only', !phoneTop.matches);
  const home = phoneTop.matches ? document.querySelector('#panel-piano .form') : document.querySelector('.tuning-bar');
  home.prepend(label, $('tuning-select'));
}

async function openTuning(t) {
  await saver.flush();
  const other = engine.tuning?.id !== t.id;
  try { localStorage.setItem(LS.tuning, t.id); } catch { /* optional */ }
  engine.open(normalize(t));
  renderSettings();
  renderTuningSelect();
  setSaveState('idle');
  if (other && engine.mode === 'survey') engine.setMode('survey'); // the run belongs to the piano it started on
  engine.followOrder();
}

async function createAndOpen(t) {
  t.rev = (await saveTuning(t)).rev;
  await refreshList();
  await openTuning(t);
}

// ---------------------------------------------------------------------------
// Rendering

const option = (value, text) => Object.assign(document.createElement('option'), { value, textContent: text });

// The targets changed (engine.recompute).
function renderTargets() {
  renderKeyInfo();
  renderKeyboard();
  renderRef();
  renderPass();
  renderChart();
  if ($('table-details').open) renderTable();
  renderOrderPanel();
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
  engine.rebuildOrder();
  if (engine.key > top()) engine.selectKey(top(), false);
  renderKeyboard();
  renderChart();
}

function renderSettings() {
  const s = S();
  applyKeyCount();
  $('set-name').value = engine.tuning.name;
  $('set-kind').value = s.pianoKind;
  $('set-size').value = s.sizeCm;
  $('set-keys').value = String(top());
  $('set-two').value = s.twoStringsTo;
  $('set-one').value = s.oneStringTo;
  $('set-unisons').value = s.unisons;
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
  $('set-notes').value = engine.tuning.notes || '';
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
  for (const [id, k] of [['out-two', s.twoStringsTo], ['out-one', s.oneStringTo]]) $(id).textContent = k ? kName(k) : tr('piano.stringsNone');
}

// The field shows the reference with the language's decimal separator.
function showRefField() {
  const ref = Number(S().refA4);
  $('set-ref').value = num(ref, 1);
  $('set-ref').setAttribute('aria-valuenow', ref);
}

function renderRef() {
  const ref = Number(S().refA4);
  if (document.activeElement !== $('set-ref')) showRefField();
  $('ref-hz').textContent = fmtHz(ref, 1);
  const c = centsBetween(ref, 440);
  $('ref-cents').textContent = Math.abs(c) < 0.05 ? tr('ref.standard') : tr('ref.vs440', { c: fmtC(c) });
  for (const b of $('ref-presets').children) b.classList.toggle('on', Number(b.dataset.hz) === ref);

  const a = engine.refAdvice();
  $('btn-overpull').hidden = true;
  if (a.kind === 'none') {
    $('ref-advice').textContent = tr('ref.adviceNone');
    return;
  }
  const { m, p } = a;
  if (a.kind === 'near') {
    $('ref-advice').textContent = tr('ref.adviceNear', { c: fmtC(m) });
    return;
  }
  let text = tr('ref.adviceOff', { c: fmtC(m), hz: fmtHz(a.hz, 1) });
  if (p) {
    text += tr('ref.overpull', { p, c: fmtC(m, 0), o: fmtC(a.o, 0), hz: fmtHz(a.ohz, 1) });
    if (a.big) text += ' ' + tr('ref.overpullBig');
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
  const k = engine.key;
  const T = engine.T;
  const n = partialOf(k);
  const g = engine.goal(k);
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
    diag(`sine ${kName(k)} partial ${n}, ${fmtHz(engine.sineFreq())}`);
    tones.setSine(engine.sineFreq());
  }
  renderToneButton();
}

function renderKeyboard() {
  buildKeyboard(top());
  const cur = Math.min(engine.key, top());
  const quickPlan = engine.survey && engine.surveyPlan === 'quick';
  const orderKey = engine.orderActive() ? engine.orderTask()?.k : 0;
  for (const el of $('keyboard').children) {
    const k = Number(el.dataset.k);
    const label = tr('key.label', { name: kName(k), dev: Number.isFinite(curDev(k)) ? fmtC(statusDev(k)) + ' ' + tr('unit.cents') : tr('key.unmeasured') });
    el.classList.toggle('current', k === cur);
    el.classList.toggle('has-b', !!engine.tuning.inharmonicity[k]);
    el.classList.toggle('plan', (!!quickPlan && survey.QUICK_KEYS.includes(k)) || k === orderKey);
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
  const { measured, ok } = engine.passStats();
  const since = new Date(engine.tuning.passStartedAt || engine.tuning.createdAt);
  $('pass-stats').replaceChildren(
    stat(`${ok}/${top()}`, tr('pass.inTol')),
    stat(`${measured}`, tr('pass.measured')),
    stat(fmtDate(since), tr('pass.started')),
  );
  $('history').replaceChildren(
    ...[...engine.tuning.history].reverse().map((p) =>
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
  const T = engine.T;
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
      fmtB(T.B[k]) + (engine.bBad.has(k) ? ' ?' : engine.tuning.inharmonicity[k] ? ' *' : ''), partialOf(k), fmtC(engine.beforeDev(k)), fmtC(statusDev(k)),
    ];
    for (const c of cells) row.append(Object.assign(document.createElement('td'), { textContent: c }));
    row.lastChild.dataset.s = statusClass(statusDev(k));
    if (k === engine.key) row.className = 'current';
    body.append(row);
  }
  $('ktable').replaceChildren(head, body);
}

function renderChart() {
  if (!engine.T) return;
  const T = engine.T;
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
  state.chartGeo = c.clientWidth ? drawChart(c, { top: top(), target: T.cents, points, ticks, current: engine.key, xs }, state.colors) : null;
  renderCurveHint();
}

// Until some inharmonicity is measured, the curve comes from the model.
function renderCurveHint() {
  $('curve-hint').hidden = $('curve-row').hidden || engine.mode === 'survey' || Object.keys(engine.tuning.inharmonicity).length > 0;
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
  const T = engine.T;
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

// A key chosen on the page; it leaves auto mode.
const selectKey = (k) => engine.selectKey(k);
const setMode = (m) => engine.setMode(m);

// Another key is selected (engine.selectKey).
function renderKeyChange() {
  renderSurveyPanel();
  renderOrderPanel();
  renderKeyInfo();
  renderKeyboard();
  renderChart();
  if ($('table-details').open) renderTable();
}

// The mode changed (engine.setMode).
function renderMode() {
  const m = engine.mode;
  for (const id of ['auto', 'lock']) $('mode-' + id).setAttribute('aria-pressed', m === id);
  $('btn-survey').setAttribute('aria-pressed', m === 'survey');
  $('survey-panel').hidden = m !== 'survey';
  renderKeyboard();
  renderSurveyPanel();
  renderOrderPanel();
  renderCurveHint();
}

// ---------------------------------------------------------------------------
// Measuring

// One start at a time: a second click while the permission prompt is open
// would start a second stream and analysis timer that are never stopped.
let micStarting = false;
async function startMic() {
  if (micStarting || mic.running) return;
  micStarting = true;
  try {
    await openMic();
  } finally {
    micStarting = false;
  }
}

async function openMic() {
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
    const key = {
      insecure: 'mic.insecure',
      NotAllowedError: 'mic.denied',
      NotFoundError: 'mic.notFound',
      NotReadableError: 'mic.notReadable',
      OverconstrainedError: 'mic.unavailable',
      AbortError: 'mic.aborted',
      SecurityError: 'mic.blocked',
    }[e.name];
    message(key ? tr(key) : tr('mic.failed', { err: e.message }), 'error', 0);
    return;
  }
  engine.startAudio(mic.sampleRate);
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
  // Unplugged, or the browser took the input back: the analyser would go on
  // reading silence.
  track?.addEventListener('ended', () => {
    if (mic.stream?.getAudioTracks()[0] !== track) return;
    stopMic();
    message(tr('mic.ended'), 'warn', 0);
  });
}

// Every 5 s while the microphone runs: frames analysed, readings, and why the
// other frames gave none.
function diagStatus() {
  const d = engine.stats;
  if (mic.running && diagOn()) {
    const track = mic.stream?.getAudioTracks()[0];
    const idle = Object.entries(d.idle).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ') || '–';
    const gate = engine.gate();
    diag(
      `status: ${d.frames} frames, ${d.readings} readings; idle: ${idle}; level ${engine.level.toFixed(0)} dB, noise ${engine.noise.toFixed(0)}, gate ${gate.toFixed(0)}; ` +
        `${engine.mode} ${kName(engine.key)}; audio ${mic.ctx.state}, track ${track?.readyState}${track?.muted ? ' muted' : ''}, page ${document.visibilityState}` +
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
  engine.stopAudio();
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
  $('mic-txt').textContent = tr(mic.running ? 'mic.stop' : 'mic.start');
  $('mic-alt').textContent = tr(mic.running ? 'mic.start' : 'mic.stop');
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

// Every FRAME_MS: the latest samples to the engine, then the readout.
function processFrame() {
  engine.frame(mic.read(), { time: mic.time, now: performance.now(), wall: Date.now(), ref: refPlaying() });
  renderSurveyPanel();
  updateReadout();
}

function flashKey(k) {
  const el = $('keyboard').children[k - 1];
  el.classList.remove('flash');
  void el.offsetWidth; // restart the animation
  el.classList.add('flash');
}

// ---------------------------------------------------------------------------
// Survey

function setSurveyPlan(p) {
  try { localStorage.setItem(LS.plan, p); } catch { /* optional */ }
  document.querySelectorAll('[data-plan]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.plan === p));
  engine.setSurveyPlan(p);
  if (!engine.survey) return;
  renderKeyboard();
  renderSurveyPanel();
}

// What a finished survey measured (engine.finishSurvey).
function surveyDoneText({ quick, b, n, skipped, outliers }) {
  return (
    (quick ? tr('survey.doneQuick', { b, n }) : tr('survey.doneFull', { n, b })) +
    (!skipped.length ? '' : skipped.length <= 8 ? tr('survey.skipped', { keys: skipped.map(kName).join(', ') }) : tr('survey.skippedMany', { n: skipped.length })) +
    (outliers.length ? tr('survey.bOutliers', { keys: outliers.map(kName).join(', ') }) : '')
  );
}

function renderSurveyPanel() {
  if (!engine.survey) return;
  const sk = engine.survey;
  const name = kName(engine.key);
  const ks = engine.planKeys();
  const done = ks.filter((k) => survey.handled(engine.run, k)).length;
  $('survey-progress').textContent = tr('survey.progress', { done, total: ks.length });
  $('survey-bar').style.width = `${(done / ks.length) * 100}%`;
  $('survey-step').textContent = sk.wrong
    ? sk.wrong > 0 ? tr('survey.wrong', { heard: kName(sk.wrong), name }) : tr('survey.offPitch', { name, c: survey.OFFSET_LIMIT })
    : tr(sk.waitAttack ? 'survey.strike' : sk.lost ? 'survey.lost' : 'survey.listening', { name });
  const p = Math.min(sk.pitch.length, survey.PITCH_READINGS);
  setCheck('survey-chk-pitch', tr('survey.pitch', { p, n: survey.PITCH_READINGS }), p >= survey.PITCH_READINGS);
  if (!engine.needsB(engine.key)) setCheck('survey-chk-b', tr('survey.bKnown'), true);
  else if (survey.bGivenUp(sk, engine.surveyPlan)) setCheck('survey-chk-b', tr('survey.bSkipped'), true);
  else setCheck('survey-chk-b', tr('survey.b', { p: Math.min(sk.bs.length, survey.B_READINGS), n: survey.B_READINGS }), sk.bs.length >= survey.B_READINGS);
}

function setCheck(id, text, done) {
  $(id).textContent = text;
  $(id).dataset.done = done ? '1' : '0';
}

// ---------------------------------------------------------------------------
// Tuning order: optional. The panel shows the step and the key it is on; any
// other key or mode can be used meanwhile, and the order waits for its key.

const orderTask = () => engine.orderTask();
const strings = (k) => engine.strings(k);
const goOrder = (pos) => engine.goOrder(pos);

function setOrderOn(on) {
  try { localStorage.setItem(LS.order, on ? 'on' : 'off'); } catch { /* optional */ }
  $('btn-order').setAttribute('aria-pressed', on);
  engine.setOrderOn(on);
  if (on) syncTuning();
}

function renderOrderState() {
  const c = engine.orderConfirm;
  const el = $('order-state');
  const advice = orderTask() && engine.orderAdvice;
  el.textContent = advice
    ? tr('order.' + advice, { c: num(engine.display), dir: tr(engine.display > 0 ? 'order.sharp' : 'order.flat') })
    : orderTask() && c && c.cur > c.since && c.ok ? tr('order.confirm') : '';
  el.classList.toggle('warn', !!advice);
}

const ivName = ({ semis, p }) => tr('iv.' + semis) + (semis === 12 ? ' ' + p.join(':') : '');

function rateText(b) {
  const a = Math.abs(b);
  if (a < 0.05) return tr('order.beatless');
  return tr('order.rate', { n: num(a, a < 10 ? 1 : 0), dir: tr(b > 0 ? 'order.wide' : 'order.narrow') });
}

const ivKeys = (r) => `${kName(r.lo)}–${kName(r.hi)}`;

// How much faster b beats than a, in per cent; signed for the row, plain for the title.
function rise(a, b, signed = true) {
  const x = (Math.abs(b.beat) / Math.abs(a.beat) - 1) * 100;
  return tr('order.pct', { n: (signed ? (x < 0 ? '−' : '+') : '') + num(x, 0) });
}

// A check row as text, and for a third or sixth with tuned neighbours its
// window: slower < this < faster, with how much faster each step beats.
function checkLabel(r) {
  const text = `${ivKeys(r)} ${ivName(r)} ${rateText(r.beat)}`;
  if (!r.below && !r.above) return { textContent: text };
  const steps = [];
  const title = [];
  if (r.below) {
    steps.push(rise(r.below, r));
    title.push(tr('order.window.below', { iv: ivKeys(r), x: ivKeys(r.below), n: rise(r.below, r, false) }));
  }
  if (r.above) {
    steps.push(rise(r, r.above));
    title.push(tr('order.window.above', { iv: ivKeys(r), x: ivKeys(r.above), n: rise(r, r.above, false) }));
  }
  return {
    textContent: `${r.below ? ivKeys(r.below) + ' < ' : ''}${text}${r.above ? ' < ' + ivKeys(r.above) : ''} (${steps.join(', ')})`,
    title: title.join(' '),
  };
}

function stepParams(id) {
  const r = stepRange(id, top());
  return r ? { lo: kName(r[0]), hi: kName(r[1]) } : {};
}

function taskText(t) {
  const p = { name: kName(t.k), from: t.from ? kName(t.from) : '' };
  if (t.from) p.iv = tr('iv.' + Math.abs(t.k - t.from));
  if (t.what === 'middle') return tr(t.from ? 'order.task.middleFrom' : 'order.task.middle', p);
  if (t.what === 'one') return tr(strings(t.k) === 1 ? 'order.task.single' : 'order.task.one', p);
  if (t.what === 'unison') return tr(strings(t.k) === 2 ? 'order.task.unison2' : 'order.task.unison3', p);
  if (t.what === 'pair') return tr(strings(t.k) === 2 ? 'order.task.pair2' : 'order.task.pair', p);
  if (t.what === 'recheck') return tr('order.task.recheck', { ...p, c: fmtC(statusDev(t.k)) });
  return tr('order.task.' + t.what, p);
}

// Where the piano is, for the first two steps.
function pitchAdvice() {
  const a = engine.pitchAdvice();
  if (!a) return tr('order.pitch.unknown');
  return tr(a.off ? 'order.pitch.off' : 'order.pitch.near', { c: fmtC(a.m, 0) });
}

function orderButton(id, label, run) {
  const b = $(id);
  b.hidden = !label;
  if (label) Object.assign(b, { textContent: label, onclick: run });
}

function renderOrderPanel() {
  const on = engine.orderActive();
  $('order-panel').hidden = !on;
  if (!on) return;
  const o = engine.order;
  const pos = engine.orderPos;
  const step = o[pos.step];
  const t = orderTask();
  const sel = $('order-step');
  if (sel.options.length !== o.length || sel.dataset.lang !== lang() || sel.dataset.top !== String(top())) {
    sel.replaceChildren(...o.map((s, i) => option(i, `${i + 1}. ${tr('order.' + s.id, stepParams(s.id))}`)));
    Object.assign(sel.dataset, { lang: lang(), top: String(top()) });
  }
  sel.value = pos.step;
  $('order-progress').textContent = step.tasks.length ? tr('order.progress', { i: pos.i + 1, n: step.tasks.length }) : '';
  $('order-bar').style.width = `${order.progress(o, pos) * 100}%`;
  $('order-task').textContent = t ? taskText(t) : tr(`order.${step.id}.task`, stepParams(step.id));

  const rows = t ? order.checkRows(engine.T, t, top(), order.tunedBefore(o, pos)) : [];
  $('order-checks').replaceChildren(
    ...rows.map((r, i) => Object.assign(document.createElement('span'), {
      className: 'chk' + (i === 0 && t.from ? ' main' : ''),
      ...checkLabel(r),
    })),
  );
  $('order-checks').hidden = !rows.length;

  const dsuStep = S().unisons === 'dsu' && (step.id === 'treble' || step.id === 'bass');
  let text = tr(`order.${step.id}.${dsuStep ? 'dsuText' : 'text'}`, stepParams(step.id));
  if (step.id === 'pitch' || step.id === 'raise') text += ' ' + pitchAdvice();
  if (t && t.what !== 'raise') text += ' ' + tr('order.how');
  $('order-text').textContent = text;

  orderButton('order-back', t && engine.key !== t.k ? tr('order.back', { name: kName(t.k) }) : '');
  orderButton('order-action', '');
  orderButton('order-action2', '');
  if (step.id === 'pitch') {
    orderButton('order-action', tr('curve.hintSurvey'), () => {
      setSurveyPlan('quick');
      setMode('survey');
      if (!mic.running) startMic();
    });
    if (Number.isFinite(engine.midShift())) orderButton('order-action2', tr('ref.fit'), fitRefToPiano);
  } else if (step.id === 'raise') {
    const p = engine.suggestedOverpull();
    if (p && Number(S().overpull) !== p) orderButton('order-action', tr('ref.useOverpull', { p }), () => setSetting('overpull', p));
    orderButton('order-action2', tr('order.finePass'), () => {
      newPass();
      setSetting('overpull', 0);
      goOrder({ step: engine.orderStepIndex('strip'), i: 0 });
    });
  } else if (step.id === 'finish') {
    // The main action once no key is left to go over.
    orderButton(t ? 'order-action2' : 'order-action', tr('pass.new'), () => ($('order-confirm-pass').hidden = false));
  }
  if (step.id !== 'finish') $('order-confirm-pass').hidden = true;
  $('order-prev').disabled = !order.prevPos(o, pos);
  $('order-next').textContent = tr(t ? 'order.nextKey' : 'order.next');
  $('order-skip').hidden = !t;
  renderOrderState();
  fitOrderText();
}

// "Show more" under a clamped explanation; not needed when it all fits or
// the panel is beside the dial in a high window (style.css).
const orderWide = matchMedia('(min-width: 960px) and (min-height: 900px)');
function fitOrderText() {
  const panel = $('order-panel');
  if (panel.hidden) return;
  const open = panel.classList.contains('text-open');
  const el = $('order-text');
  const b = $('order-more');
  b.hidden = orderWide.matches || (!open && el.scrollHeight <= el.clientHeight + 1);
  b.textContent = tr(open ? 'order.less' : 'order.more');
  b.setAttribute('aria-expanded', open);
}

// ---------------------------------------------------------------------------
// Reference tones

const sineFreq = () => engine.sineFreq();

function playPiano() {
  diag(`piano tone ${kName(engine.key)}`);
  const ms = tones.pluck(engine.goalF1(engine.key), engine.T.B[engine.key]);
  state.refUntil = Math.max(state.refUntil, performance.now() + ms + 800); // + the analysis buffer
}

function startSine() {
  if (!tones.sineOn && mic.running) message(tr('msg.sineNoSave'), 'info', 4000);
  diag(`sine ${kName(engine.key)} partial ${partialOf(engine.key)}, ${fmtHz(sineFreq())}`);
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
  if (state.toneMode === 'piano') playPiano();
  else if (tones.sineOn) stopSine();
  else startSine();
}

function setToneMode(m) {
  state.toneMode = m;
  if (m !== 'sine') stopSine();
  document.querySelectorAll('[data-tone]').forEach((b) => b.setAttribute('aria-checked', b.dataset.tone === m));
  document.querySelectorAll('[data-tone-label]').forEach((s) => s.toggleAttribute('data-off', s.dataset.toneLabel !== m));
  try { localStorage.setItem(LS.tone, m); } catch { /* optional */ }
  renderToneButton();
}

function setToneOnKey(on) {
  state.toneOnKey = on;
  $('tone-on-key').setAttribute('aria-checked', on);
  try { localStorage.setItem(LS.toneOnKey, on ? 'on' : 'off'); } catch { /* optional */ }
}

// Opening focuses the checked tone; closing gives focus back to the button if
// it was in the menu.
function setToneMenuOpen(open) {
  const menu = $('tone-menu');
  if (open === !menu.hidden) return;
  if (!open && menu.contains(document.activeElement)) $('btn-tone-menu').focus();
  menu.hidden = !open;
  $('btn-tone-menu').setAttribute('aria-expanded', open);
  if (open) menu.querySelector('[data-tone][aria-checked="true"]').focus();
}

// The sine sounds at the measured partial, in the bass and tenor an octave or
// more above the key, so the button names the note it plays.
function renderToneButton() {
  const b = $('btn-tone');
  const n = state.toneMode === 'sine' ? partialOf(engine.key) : 1;
  const note = kName(Math.min(KEY_COUNT, engine.key + Math.round(12 * Math.log2(n))));
  const what = n > 1 ? tr('tone.partialNote', { note, n }) : note;
  b.textContent = `${tones.sineOn ? '■' : '▶'} ${note}`;
  b.title = tr(tones.sineOn ? 'tone.stopSine' : state.toneMode === 'sine' ? 'tone.playSine' : 'tone.playTitle', { what });
  b.setAttribute('aria-label', b.title);
  b.setAttribute('aria-pressed', tones.sineOn);
}

// ---------------------------------------------------------------------------
// Readout and animation

function updateReadout() {
  let text;
  let s = 'idle';
  if (!mic.running) text = tr('status.start');
  else if (!engine.signal) text = engine.survey?.waitAttack ? tr('status.strike', { name: kName(engine.key) }) : tr('status.listening');
  else {
    s = statusClass(engine.display);
    text = tr(refPlaying() ? 'status.ref' : s === 'good' ? 'status.good' : engine.display > 0 ? 'status.high' : 'status.low');
  }
  $('status').dataset.s = $('hub').dataset.s = s;
  $('status').textContent = text;
  $('cents-num').textContent = mic.running ? fmtC(engine.display) : '–';
  $('cents').dataset.live = engine.signal ? '1' : '0';
  const n = partialOf(engine.key);
  const hz = mic.running && Number.isFinite(engine.measHz) ? fmtHz(engine.measHz) : '–';
  $('measured').replaceChildren(...trNodes(n > 1 ? 'measured.partial' : 'measured', { n, hz }));
  $('measured').dataset.live = engine.signal ? '1' : '0';
  const hint = $('unison-hint');
  hint.hidden = !(mic.running && engine.beating);
  if (!hint.hidden) hint.textContent = tr('unison.hint');
  $('level-bar').style.width = mic.running ? `${Math.max(0, Math.min(100, (engine.level + 80) * 1.4))}%` : '0';
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
  const n = partialOf(engine.key);
  [...box.children].forEach((cell, i) => {
    const d = engine.signal ? engine.partialDevs[i] : null;
    cell.classList.toggle('sel', i + 1 === n);
    cell.lastChild.textContent = d == null ? '–' : fmtC(d);
    cell.dataset.s = d == null ? 'none' : statusClass(d);
  });
}

function animate(t) {
  const dt = state.lastAnim ? Math.min(0.1, (t - state.lastAnim) / 1000) : 0;
  state.lastAnim = t;
  if (engine.tuning) {
    const C = state.colors;
    const tol = engine.tolerance();
    const live = engine.signal && Number.isFinite(engine.display);
    drawDial($('dial'), { display: engine.display, signal: engine.signal, bands: engine.strobe, live, tol }, C, dt, state.ringPhase);
    const beatLive = live && Number.isFinite(engine.beatHz);
    if (!$('beats-row').hidden) {
      drawSpectro($('spectro'), engine.spec, { capacity: SPEC_COLS, bins: SPEC_BINS, cents: SPEC_CENTS, tol }, C);
      state.beatPhase = drawBeat($('beat'), { beatHz: engine.beatHz, display: engine.display, live: beatLive, tol }, C, dt, state.beatPhase);
    }
    const df = Math.abs(engine.beatHz);
    const rate = !beatLive ? '–' : df < 0.1 ? tr('beat.none') : tr('beat.rate', { n: num(df, df < 10 ? 1 : 0) });
    if ($('beat-rate').textContent !== rate) $('beat-rate').textContent = rate;
  }
  requestAnimationFrame(animate);
}

// ---------------------------------------------------------------------------
// Actions

function setSetting(key, value) {
  S()[key] = value;
  engine.recompute();
  renderSettingDescs();
  markDirty();
}

function setRef(hz) {
  if (!Number.isFinite(hz)) return;
  setSetting('refA4', clampRef(hz));
}

// Set the reference so the middle of the piano is on target (engine.fitRefHz).
function fitRefToPiano() {
  const hz = engine.fitRefHz();
  if (!Number.isFinite(hz)) return message(tr('msg.fitNeedsInput'), 'warn');
  setRef(hz);
  message(tr('msg.fitDone', { hz: fmtHz(Number(S().refA4), 1) }), 'ok');
}

// End the pass (engine.newPass).
function newPass() {
  engine.newPass(Date.now());
  markDirty();
  message(tr('msg.newPass'), 'ok');
}

function exportTuning() {
  const blob = new Blob([JSON.stringify(engine.tuning, null, 2)], { type: 'application/json' });
  download(blob, (engine.tuning.name || tr('name.file')).replace(/[^\p{L}\p{N}_-]+/gu, '_') + '.json');
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
    await deleteTuning(engine.tuning.id);
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
  engine.recompute();
  renderSurveyPanel();
  renderOrderPanel();
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

// The reference popover at the A4 chip borrows the reference controls from
// the Tuning tab while it is open.
function openRefPop() {
  $('ref-pop').prepend($('ref-box'));
  $('ref-pop').hidden = false;
  $('btn-ref-chip').setAttribute('aria-expanded', 'true');
  $('ref-pop').focus();
}

function closeRefPop(focusChip = false) {
  if ($('ref-pop').hidden) return;
  $('ref-pop').hidden = true;
  $('ref-home').append($('ref-box'));
  $('btn-ref-chip').setAttribute('aria-expanded', 'false');
  if (focusChip) $('btn-ref-chip').focus();
}

// The page behind the drawer is inert, so Tab stays in the drawer. The toast
// stays reachable; it is drawn above the drawer.
const setPageInert = (on) => document.querySelectorAll('.top, main').forEach((el) => (el.inert = on));

// Focus goes back to the button that opened the drawer.
let drawerOpener = 'btn-settings';
const setDrawerExpanded = (v) => ['btn-settings', 'btn-help'].forEach((id) => $(id).setAttribute('aria-expanded', v));

function openDrawer(tab, opener = 'btn-settings') {
  drawerOpener = opener;
  closeRefPop();
  setToneMenuOpen(false);
  setPageInert(true);
  $('drawer').hidden = $('drawer-backdrop').hidden = false;
  document.body.classList.add('drawer-open');
  setDrawerExpanded(true);
  let last = 'piano';
  try { last = localStorage.getItem(LS.tab) || last; } catch { /* optional */ }
  showTab(tab || last);
  $('drawer-close').focus();
}

function closeDrawer() {
  $('drawer').hidden = $('drawer-backdrop').hidden = true;
  setPageInert(false);
  document.body.classList.remove('drawer-open');
  setDrawerExpanded(false);
  $(drawerOpener).focus();
}

// H: Help, or back to the page when Help is already showing.
function toggleHelp() {
  if ($('drawer').hidden) openDrawer('help', 'btn-help');
  else if (document.querySelector('[data-panel="help"]').hidden) showTab('help');
  else closeDrawer();
}

function showTab(tab) {
  if (!document.querySelector(`[data-panel="${tab}"]`)) tab = 'piano';
  document.querySelectorAll('[data-tab]').forEach((b) => {
    b.setAttribute('aria-selected', b.dataset.tab === tab);
    b.tabIndex = b.dataset.tab === tab ? 0 : -1; // only the selected tab is in the Tab order
  });
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
  on('btn-help', 'click', toggleHelp);
  on('drawer-close', 'click', closeDrawer);
  on('drawer-backdrop', 'click', closeDrawer);
  on('btn-ref-chip', 'click', () => ($('ref-pop').hidden ? openRefPop() : closeRefPop()));
  on('ref-more', 'click', () => openDrawer('tuning'));
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.ref-anchor')) closeRefPop();
  });
  onAll('[data-tab]', (b) => showTab(b.dataset.tab));
  // Arrow keys, Home and End move between the tabs and select them.
  document.querySelector('[role="tablist"]').addEventListener('keydown', (e) => {
    const tabs = [...document.querySelectorAll('[data-tab]')];
    const i = tabs.indexOf(e.target);
    const to = { ArrowLeft: i - 1, ArrowRight: i + 1, Home: 0, End: tabs.length - 1 }[e.key];
    if (i < 0 || to === undefined || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = tabs[(to + tabs.length) % tabs.length];
    showTab(t.dataset.tab);
    t.focus();
    e.preventDefault();
    e.stopPropagation(); // not the page's previous/next key
  });
  on('btn-mic', 'click', () => (mic.running ? stopMic() : startMic()));
  on('btn-rec', 'click', toggleRecording);
  on('btn-rec-stop', 'click', finishRecording);

  // Tuner
  on('btn-prev', 'click', () => selectKey(engine.key - 1));
  on('btn-next', 'click', () => selectKey(engine.key + 1));
  on('mode-auto', 'click', () => setMode('auto'));
  on('mode-lock', 'click', () => setMode('lock'));
  const startSurvey = () => {
    if (engine.mode === 'survey') return;
    setMode('survey');
    if (!mic.running) startMic();
  };
  on('btn-survey', 'click', () => (engine.mode === 'survey' ? setMode('lock') : startSurvey()));
  on('btn-curve-survey', 'click', () => {
    setSurveyPlan('quick');
    startSurvey();
  });
  on('survey-skip', 'click', () => engine.skipSurveyKey());
  on('survey-redo', 'click', () => {
    engine.redoSurveyKey();
    renderSurveyPanel();
  });
  on('survey-stop', 'click', () => setMode('lock'));
  onAll('[data-plan]', (b) => setSurveyPlan(b.dataset.plan));
  on('btn-order', 'click', () => setOrderOn(!engine.orderOn));
  on('order-close', 'click', () => setOrderOn(false));
  on('order-more', 'click', () => {
    $('order-panel').classList.toggle('text-open');
    fitOrderText();
  });
  on('order-step', 'change', (e) => goOrder({ step: Number(e.target.value), i: 0 }));
  on('order-prev', 'click', () => engine.orderPrev());
  on('order-next', 'click', () => engine.orderNext());
  on('order-skip', 'click', () => engine.orderSkip());
  on('order-back', 'click', () => engine.orderBack());

  on('keyboard', 'click', (e) => {
    const k = Number(e.target.closest('.key')?.dataset.k);
    if (!k) return;
    const prev = engine.key;
    selectKey(k);
    if (!state.toneOnKey) return;
    if (state.toneMode === 'piano') playPiano();
    else (tones.sineOn && k === prev ? stopSine : startSine)();
  });
  on('btn-tone', 'click', playCurrent);
  on('btn-tone-menu', 'click', () => setToneMenuOpen($('tone-menu').hidden));
  on('btn-tone-menu', 'keydown', (e) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    setToneMenuOpen(true);
    e.preventDefault();
  });
  // Up/Down, Home and End move among the items; Tab closes the menu and moves
  // on from its button.
  on('tone-menu', 'keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'Tab') return setToneMenuOpen(false);
    const items = [...$('tone-menu').querySelectorAll('[role^="menuitem"]')];
    const i = items.indexOf(document.activeElement);
    const to = { ArrowUp: i - 1, ArrowDown: i + 1, Home: 0, End: items.length - 1 }[e.key];
    if (to !== undefined) items[(to + items.length) % items.length].focus();
    else if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault();
    e.stopPropagation(); // not the page's previous/next key
  });
  onAll('[data-tone]', (b) => {
    setToneMode(b.dataset.tone);
    setToneMenuOpen(false);
  });
  on('tone-on-key', 'click', () => {
    setToneOnKey(!state.toneOnKey);
    setToneMenuOpen(false);
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.split')) setToneMenuOpen(false);
  });

  const setPartial = (d) => {
    engine.setPartial(d);
    renderKeyInfo();
    markDirty();
  };
  on('partial-dec', 'click', () => setPartial(-1));
  on('partial-inc', 'click', () => setPartial(1));
  on('btn-measure-b', 'click', () => {
    if (!mic.running) return message(tr('msg.micFirst'), 'warn');
    const run = engine.startMeasureB(performance.now());
    message(tr('msg.strikeB', { name: kName(engine.key) }), 'info', 4000);
    setTimeout(() => engine.measureB === run && engine.finishMeasureB(), 6000); // in case the note dies away first
  });

  // Reference
  // Invalid input goes back to the current reference.
  on('set-ref', 'change', (e) => {
    setRef(parseNum(e.target.value));
    showRefField();
  });
  // Arrow keys step 0.1 Hz, with Shift 1 Hz.
  on('set-ref', 'keydown', (e) => {
    const dir = { ArrowUp: 1, ArrowDown: -1 }[e.key];
    if (!dir) return;
    e.preventDefault();
    const typed = parseNum(e.target.value);
    setRef((Number.isFinite(typed) ? typed : Number(S().refA4)) + dir * (e.shiftKey ? 1 : 0.1));
    showRefField();
  });
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
    const cm = clampSize(S().pianoKind, e.target.value);
    e.target.value = cm;
    setSetting('sizeCm', cm);
  });
  on('set-keys', 'input', (e) => {
    setSetting('keyCount', Number(e.target.value));
    applyKeyCount();
  });
  // Strings per key: within the keyboard, one string never above two.
  const setStrings = () => {
    const { two, one } = engine.setStrings($('set-two').value, $('set-one').value);
    $('set-two').value = two;
    $('set-one').value = one;
    renderSettingDescs();
    renderOrderPanel();
    markDirty();
  };
  on('set-two', 'change', setStrings);
  on('set-one', 'change', setStrings);
  on('set-unisons', 'change', (e) => engine.setUnisons(e.target.value));
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
    engine.tuning.name = e.target.value.trim() || tr('name.untitled');
    const item = state.list.find((t) => t.id === engine.tuning.id);
    if (item) item.name = engine.tuning.name;
    renderTuningSelect();
    markDirty();
  });
  on('set-notes', 'input', (e) => {
    engine.tuning.notes = e.target.value;
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
    createAndOpen(duplicateTuning(engine.tuning, tr('name.copy', { name: engine.tuning.name }))).catch(() => message(tr('msg.dupFailed'), 'error'));
  });
  on('btn-del', 'click', () => {
    $('confirm-del-text').textContent = tr('piano.confirmDel', { name: engine.tuning.name });
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
  on('order-confirm-pass-no', 'click', show('order-confirm-pass', false));
  on('order-confirm-pass-yes', 'click', () => {
    $('order-confirm-pass').hidden = true;
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
    if (e.key === 'Escape' && !$('ref-pop').hidden) return closeRefPop(true);
    if (e.key === 'Escape' && !$('tone-menu').hidden) {
      setToneMenuOpen(false);
      return $('btn-tone-menu').focus();
    }
    if (e.key === 'Escape' && !$('drawer').hidden) return closeDrawer();
    if (e.target.closest('input, select, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
    const action = {
      ArrowLeft: () => selectKey(engine.key - 1),
      ArrowRight: () => selectKey(engine.key + 1),
      l: () => setMode('lock'),
      a: () => setMode('auto'),
      o: () => setOrderOn(!engine.orderOn),
      t: playCurrent,
      s: () => ($('drawer').hidden ? openDrawer() : closeDrawer()),
      h: toggleHelp,
    }[e.key.length === 1 ? e.key.toLowerCase() : e.key];
    // Only S and H work while the drawer is open; the rest act on the page behind it.
    if (!action || (!$('drawer').hidden && !['s', 'h'].includes(e.key.toLowerCase()))) return;
    action();
    e.preventDefault();
  });

  // Window
  window.addEventListener('resize', () => {
    fitOrderText();
    renderKeyboard();
    renderChart();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refreshColors);
  document.addEventListener('visibilitychange', () => {
    diag(`page ${document.visibilityState}`);
    if (document.visibilityState === 'visible') {
      checkVersion();
      syncTuning();
    }
    if (document.visibilityState === 'hidden') saver.flush();
    else if (mic.running) {
      mic.resume();
      if (!state.wakeLock || state.wakeLock.released) requestWakeLock(); // released by the browser when the page was hidden
    }
  });
  // A window behind another one is not hidden, but it gets the focus back.
  window.addEventListener('focus', () => syncTuning());
  // Last chance to save when the tab closes.
  window.addEventListener('pagehide', () => {
    if (!saver.dirty || !engine.tuning) return;
    navigator.sendBeacon?.(
      'api/tunings/' + encodeURIComponent(engine.tuning.id),
      new Blob([JSON.stringify(engine.tuning)], { type: 'application/json' }),
    );
  });
}

// ---------------------------------------------------------------------------
// Start

async function boot() {
  try { state.micId = localStorage.getItem(LS.mic) || ''; } catch { /* optional */ }
  buildStaticUi();
  placeTuningSelect();
  phoneTop.addEventListener('change', placeTuningSelect);
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
    engine.tuning = newTuning(tr('name.default'));
    engine.recompute();
    renderSettings();
    setSaveState('error');
    message(tr('msg.noServer'), 'warn', 0, 'server');
  }
  bindEvents();
  renderThemeButton();
  renderMicButton();
  let plan = 'quick';
  let tone = 'piano';
  let onKey = false;
  try {
    plan = localStorage.getItem(LS.plan) === 'full' ? 'full' : 'quick';
    // Before 1.8 the tone had an Off choice, and Piano and Sine played on key clicks.
    const saved = localStorage.getItem(LS.tone);
    if (saved === 'sine') tone = 'sine';
    onKey = (localStorage.getItem(LS.toneOnKey) || (saved && saved !== 'off' ? 'on' : 'off')) === 'on';
    if (localStorage.getItem(LS.curve) === 'closed') setCurveOpen(false);
    for (const name of ['beats', 'partials']) if (localStorage.getItem(LS[name]) === 'open') setFoldOpen(name, true);
  } catch { /* optional */ }
  setSurveyPlan(plan);
  setToneMode(tone);
  setToneOnKey(onKey);
  try { if (localStorage.getItem(LS.order) === 'on') setOrderOn(true); } catch { /* optional */ }
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
