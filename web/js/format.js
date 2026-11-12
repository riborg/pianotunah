// Number formatting with the language's decimal separator.

import { decimal } from './i18n.js';

const dec = (s) => s.replace('.', decimal());

export const num = (x, d = 1) => dec(Math.abs(x).toFixed(d));

// Shortest form: 0.5 → "0.5", 1 → "1".
export const short = (x) => dec(String(x));

// Cents with sign: +1.2 / −0.4 / ±0.0. The sign follows the rounded value, so
// 0.3 without decimals is ±0, not +0. NaN becomes a dash.
export function fmtC(c, d = 1) {
  if (!Number.isFinite(c)) return '–';
  const zero = Number(Math.abs(c).toFixed(d)) === 0;
  return (zero ? '±' : c > 0 ? '+' : '−') + num(c, d);
}

export const fmtHz = (f, d = 2) => dec(f.toFixed(d)) + ' Hz';

export const fmtB = (b) => dec(b.toExponential(2));
