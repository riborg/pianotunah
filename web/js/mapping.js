// Survey: measure the piano note by note before tuning.
// Per key, pitch readings (median, so beating unisons do not interfere) and
// estimates of B are collected. B is given up after a certain ringing time and
// then interpolated from the neighbours.

export const PITCH_READINGS = 8;
export const B_READINGS = 5;

// All A (the quick plan): B at A0–A7 is enough for the shape of the curve;
// the keys in between are interpolated. The ends matter most: the lowest
// strings often deviate from the model, and stretch is largest at both ends.
export const QUICK_KEYS = [1, 13, 25, 37, 49, 61, 73, 85];

export const planKeys = (plan, top) =>
  plan === 'quick' ? QUICK_KEYS.filter((k) => k <= top) : Array.from({ length: top }, (_, i) => i + 1);

// A run is one survey from start to finish: the keys measured or skipped so
// far. A full survey continues where the last one stopped (keys already
// marked as mapped); once every key is mapped it starts over.
export function newRun(plan, top, isMapped) {
  const keys = planKeys(plan, top);
  const done = plan === 'full' ? keys.filter(isMapped) : [];
  return { done: new Set(done.length < keys.length ? done : []), skipped: new Set() };
}

export const handled = (run, k) => run.done.has(k) || run.skipped.has(k);

// Next pending key after k, wrapping around; null when every key is handled.
export function nextPending(run, plan, top, k) {
  const keys = planKeys(plan, top).filter((x) => !handled(run, x));
  return keys.find((x) => x > k) ?? keys[0] ?? null;
}

// The quick plan exists for B, so it waits longer for clear overtones.
export const bTimeoutMs = (plan) => (plan === 'quick' ? 6000 : 3000);

export const newKeyState = () => ({ waitAttack: true, pitch: [], bs: [], ms: 0, lost: false });

export const bGivenUp = (mp, plan) => mp.bs.length < B_READINGS && mp.ms >= bTimeoutMs(plan);

export const keyDone = (mp, needB, plan) =>
  mp.pitch.length >= PITCH_READINGS && (!needB || mp.bs.length >= B_READINGS || bGivenUp(mp, plan));
