// Talformat med svenskt decimalkomma.

export const num = (x, d = 1) => Math.abs(x).toFixed(d).replace('.', ',');

// Cent med tecken: +1,2 / −0,4 / ±0,0. NaN blir ett streck.
export const fmtC = (c, d = 1) =>
  Number.isFinite(c) ? (c > 0.049 ? '+' : c < -0.049 ? '−' : '±') + num(c, d) : '–';

export const fmtHz = (f, d = 2) => f.toFixed(d).replace('.', ',') + ' Hz';

export const fmtB = (b) => b.toExponential(2).replace('.', ',');
