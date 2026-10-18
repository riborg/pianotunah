// Number formatting with the language's decimal separator.

import { decimal } from './i18n.js';

const dec = (s) => s.replace('.', decimal());

export const num = (x, d = 1) => dec(Math.abs(x).toFixed(d));

// Shortest form: 0.5 → "0.5", 1 → "1".
export const short = (x) => dec(String(x));

// Cents with sign: +1.2 / −0.4 / ±0.0. NaN becomes a dash.
export const fmtC = (c, d = 1) =>
  Number.isFinite(c) ? (c > 0.049 ? '+' : c < -0.049 ? '−' : '±') + num(c, d) : '–';

export const fmtHz = (f, d = 2) => dec(f.toFixed(d)) + ' Hz';

export const fmtB = (b) => dec(b.toExponential(2));
