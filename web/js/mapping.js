// Kartläggning: mät pianot ton för ton innan stämningen.
// Per tangent samlas tonhöjdsavläsningar (median, så att svävande unisoner inte
// stör) och skattningar av B. B ges upp efter en viss klingtid och interpoleras
// då från grannarna.

export const PITCH_READINGS = 8;
export const B_READINGS = 5;

// Snabb: B på A0–A6 räcker för kurvans form; tangenterna däremellan
// interpoleras. A0 är med eftersom de lägsta strängarna ofta avviker från
// modellen och ger störst stretch.
export const QUICK_KEYS = [1, 13, 25, 37, 49, 61, 73];

export const planKeys = (plan, top) =>
  plan === 'quick' ? QUICK_KEYS.filter((k) => k <= top) : Array.from({ length: top }, (_, i) => i + 1);

export const nextInPlan = (plan, top, k) => planKeys(plan, top).find((x) => x > k) ?? null;

// Snabbläget finns till för B och väntar därför längre på tydliga övertoner.
export const bTimeoutMs = (plan) => (plan === 'quick' ? 6000 : 3000);

export const newKeyState = () => ({ waitAttack: true, pitch: [], bs: [], ms: 0, lost: false });

export const bGivenUp = (mp, plan) => mp.bs.length < B_READINGS && mp.ms >= bTimeoutMs(plan);

export const keyDone = (mp, needB, plan) =>
  mp.pitch.length >= PITCH_READINGS && (!needB || mp.bs.length >= B_READINGS || bGivenUp(mp, plan));
