// Tuning order: the steps of a tuning in the order a tuner works by ear, from
// the pitch check to the last unison. Each step has tasks: a key and what to
// do with it. The app's targets give the pitch; checks are intervals to play
// by ear, with the beat rate the targets give.

import { COINCIDENT, intervalBeat, partialFreq } from './theory.js';

// The felt strip mutes the outer strings of F3–A4, so one string per key
// sounds while the temperament and the octaves above it are laid.
export const STRIP = [33, 49];

const range = (a, b) => Array.from({ length: Math.abs(b - a) + 1 }, (_, i) => (a < b ? a + i : a - i));

// Temperament F3–E4 by fourths and fifths from A3: [key, tuned from, checks].
// The checks compare like with like as soon as both exist: thirds beat
// faster the higher they lie, and so do fourths and fifths.
const TEMPERAMENT = [
  [42, 37, []], // D4 from A3
  [35, 42, []], // G3 from D4
  [40, 35, []], // C4 from G3
  [33, 40, [[33, 37]]], // F3 from C4; F3–A3 ≈ 7/s
  [38, 33, [[33, 37], [38, 42]]], // B♭3; B♭3–D4 faster than F3–A3
  [43, 38, [[37, 42]]], // E♭4; A3–D4 slower than B♭3–E♭4
  [36, 43, [[36, 40]]], // A♭3; A♭3–C4
  [41, 36, [[37, 41]]], // C♯4; A3–C♯4
  [34, 41, [[33, 40], [33, 37], [34, 38]]], // F♯3; F3–C4 slower, F♯3–B♭3 faster than F3–A3
  [39, 34, [[35, 39], [38, 42], [39, 43]]], // B3; G3–B3, B3–E♭4 faster than B♭3–D4
  // E4 closes the circle: C4–E4 faster than B3–E♭4, the fifth A3–E4 and
  // fourth E4–A4, and every third from C4–E4 down to F3–A3 evenly slower.
  [44, 39, [[39, 43], [40, 44], [37, 44], [44, 49], ...range(40, 33).map((k) => [k, k + 4])]],
];

// An octave tuned upwards from k − 12: the octave as 2:1 and 4:2, the third
// below with the tenth (M3–M10), fourth with fifth, and the double octave.
const up = (k) => [[k - 12, k, [2, 1]], [k - 12, k, [4, 2]], [k - 16, k - 12], [k - 16, k], [k - 12, k - 7], [k - 7, k], [k - 24, k]];
// Downwards from k + 12: in the bass also the twelfth and the seventeenth.
const down = (k) => [[k, k + 12, [2, 1]], [k, k + 12, [4, 2]], [k, k + 12, [6, 3]], [k + 12, k + 16], [k, k + 16], [k, k + 19], [k, k + 24], [k, k + 28]];

// strings: { top, twoStringsTo, oneStringTo } from the settings. recheck:
// keys to go over again in the last step.
export function buildOrder({ top, twoStringsTo = 0, oneStringTo = 0 }, recheck = []) {
  const strings = (k) => (k <= oneStringTo ? 1 : k <= twoStringsTo ? 2 : 3);
  const bass = [];
  for (let k = STRIP[0] - 1; k >= 1; k -= 2) {
    const pair = k > 1 ? [k, k - 1] : [k];
    bass.push(...pair.map((x) => ({ k: x, from: x + 12, what: 'one', checks: down(x) })));
    bass.push(...pair.filter((x) => strings(x) > 1).map((x) => ({ k: x, what: 'unison' })));
  }
  return [
    { id: 'pitch', tasks: [] },
    // From the middle up, then down: all strings, within a few cents.
    { id: 'raise', loose: true, tasks: [...range(37, top), ...range(36, 1)].map((k) => ({ k, what: 'raise' })) },
    { id: 'strip', tasks: [] },
    { id: 'middle', tasks: [{ k: 49, what: 'middle' }, { k: 37, from: 49, what: 'middle', checks: [[33, 37], [33, 49]] }] },
    { id: 'temperament', tasks: TEMPERAMENT.map(([k, from, checks]) => ({ k, from, what: 'middle', checks })) },
    { id: 'upper', tasks: range(45, STRIP[1] - 1).map((k) => ({ k, from: k - 12, what: 'middle', checks: up(k) })) },
    { id: 'treble', tasks: range(STRIP[1] + 1, top).flatMap((k) => [{ k, from: k - 12, what: 'one', checks: up(k) }, { k, what: 'unison' }]) },
    { id: 'pull', tasks: range(STRIP[1], STRIP[0]).map((k) => ({ k, what: 'pull' })) },
    { id: 'bass', tasks: bass },
    { id: 'finish', tasks: recheck.map((k) => ({ k, what: 'recheck' })) },
  ];
}

// Positions: { step, i }. A step without tasks is one position of its own.
const count = (s) => Math.max(1, s.tasks.length);

export function clampPos(order, pos) {
  const step = Math.max(0, Math.min(order.length - 1, Number(pos?.step) || 0));
  return { step, i: Math.max(0, Math.min(count(order[step]) - 1, Number(pos?.i) || 0)) };
}

export function nextPos(order, { step, i }) {
  if (i + 1 < count(order[step])) return { step, i: i + 1 };
  return step + 1 < order.length ? { step: step + 1, i: 0 } : null;
}

export function prevPos(order, { step, i }) {
  if (i > 0) return { step, i: i - 1 };
  return step > 0 ? { step: step - 1, i: count(order[step - 1]) - 1 } : null;
}

export const taskAt = (order, { step, i }) => order[step].tasks[i] || null;

// Share of the order before pos, 0–1.
export function progress(order, { step, i }) {
  const total = order.reduce((s, x) => s + count(x), 0);
  return (order.slice(0, step).reduce((s, x) => s + count(x), 0) + i) / total;
}

// A task is done after two strikes in a row that end in tune: the note as
// tuned, and a firm test blow that shows the pin holds. A strike counts by
// its last steady reading, since the pin is often turned while it rings.
// Strikes up to `attack` (when the task started) do not count.
export const newConfirm = (attack) => ({ since: attack, cur: attack, ok: null, streak: 0 });

export function confirmReading(c, attack, ok) {
  if (attack <= c.since) return false;
  if (attack !== c.cur) {
    if (c.ok !== null) c.streak = c.ok ? c.streak + 1 : 0;
    c.cur = attack;
  }
  c.ok = ok;
  return ok && c.streak >= 1;
}

// The checks of a task with their beat rates at the targets T: the interval
// it is tuned by first, then the others, each once. Left out: keys off the
// keyboard and coincident partials too low or too high to hear (40 Hz–5 kHz).
export function checkRows(T, task, top) {
  const list = [...(task.from ? [[Math.min(task.k, task.from), Math.max(task.k, task.from)]] : []), ...(task.checks || [])];
  const seen = new Set();
  const rows = [];
  for (const [lo, hi, p = COINCIDENT[hi - lo]] of list) {
    const id = `${lo}-${hi}-${p}`;
    if (lo < 1 || hi > top || !p || seen.has(id)) continue;
    seen.add(id);
    const f = partialFreq(T.freq[lo], T.B[lo], p[0]);
    if (f < 40 || f > 5000) continue;
    rows.push({ lo, hi, semis: hi - lo, p, beat: intervalBeat(T, lo, hi, p) });
  }
  return rows;
}
