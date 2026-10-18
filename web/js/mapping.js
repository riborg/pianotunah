// Survey: measure the piano note by note before tuning.
// Per key, pitch readings (median, so beating unisons do not interfere) and
// estimates of B are collected. B is given up after a certain ringing time and
// then interpolated from the neighbours.

export const PITCH_READINGS = 8;
export const B_READINGS = 5;

// Quick: B at A0–A6 is enough for the shape of the curve; the keys in between
// are interpolated. A0 is included because the lowest strings often deviate
// from the model and give the most stretch.
export const QUICK_KEYS = [1, 13, 25, 37, 49, 61, 73];

export const planKeys = (plan, top) =>
  plan === 'quick' ? QUICK_KEYS.filter((k) => k <= top) : Array.from({ length: top }, (_, i) => i + 1);

export const nextInPlan = (plan, top, k) => planKeys(plan, top).find((x) => x > k) ?? null;

// The quick survey exists for B, so it waits longer for clear overtones.
export const bTimeoutMs = (plan) => (plan === 'quick' ? 6000 : 3000);

export const newKeyState = () => ({ waitAttack: true, pitch: [], bs: [], ms: 0, lost: false });

export const bGivenUp = (mp, plan) => mp.bs.length < B_READINGS && mp.ms >= bTimeoutMs(plan);

export const keyDone = (mp, needB, plan) =>
  mp.pitch.length >= PITCH_READINGS && (!needB || mp.bs.length >= B_READINGS || bGivenUp(mp, plan));
