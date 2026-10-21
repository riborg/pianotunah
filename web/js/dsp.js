// Signal processing: FFT spectrum, key detection, exact partial measurement
// and inharmonicity estimation.
//
// The exact frequency is found in two steps: a rough position from the FFT peak
// (parabolic interpolation), then the phase difference of a DFT at that
// frequency over two offset windows. That gives fractions of a cent even in the
// bass.

import { KEY_COUNT, partialFreq } from './theory.js';

class FFT {
  constructor(n) {
    this.n = n;
    this.rev = new Uint32Array(n);
    const bits = Math.log2(n);
    for (let i = 0; i < n; i++) {
      let r = 0;
      for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
      this.rev[i] = r;
    }
    this.cos = new Float64Array(n / 2);
    this.sin = new Float64Array(n / 2);
    for (let i = 0; i < n / 2; i++) {
      this.cos[i] = Math.cos((2 * Math.PI * i) / n);
      this.sin[i] = -Math.sin((2 * Math.PI * i) / n);
    }
  }

  transform(re, im) {
    const { n, rev } = this;
    for (let i = 0; i < n; i++) {
      const j = rev[i];
      if (j > i) {
        [re[i], re[j]] = [re[j], re[i]];
        [im[i], im[j]] = [im[j], im[i]];
      }
    }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1;
      const step = n / size;
      for (let start = 0; start < n; start += size) {
        for (let k = 0; k < half; k++) {
          const wr = this.cos[k * step];
          const wi = this.sin[k * step];
          const a = start + k;
          const b = a + half;
          const tr = re[b] * wr - im[b] * wi;
          const ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}

const hannCache = new Map();
function hann(n) {
  if (!hannCache.has(n)) {
    const w = new Float64Array(n);
    for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1));
    hannCache.set(n, w);
  }
  return hannCache.get(n);
}

export class Analyzer {
  constructor(sampleRate, size = 16384) {
    this.sr = sampleRate;
    this.n = size;
    this.df = sampleRate / size;
    this.fft = new FFT(size);
    this.re = new Float64Array(size);
    this.im = new Float64Array(size);
    this.db = new Float64Array(size / 2);
    this.floor = new Float64Array(size / 2);
    this.prefix = new Float64Array(size / 2 + 1);
    this.buf = null;
  }

  // Spectrum (dB) and a moving noise floor for the latest n samples.
  load(buf) {
    this.buf = buf;
    const { n, re, im, db, floor, prefix } = this;
    const w = hann(n);
    const off = buf.length - n;
    for (let i = 0; i < n; i++) {
      re[i] = buf[off + i] * w[i];
      im[i] = 0;
    }
    this.fft.transform(re, im);
    const half = n / 2;
    for (let i = 0; i < half; i++) {
      db[i] = 10 * Math.log10(re[i] * re[i] + im[i] * im[i] + 1e-20);
      prefix[i + 1] = prefix[i] + db[i];
    }
    const R = 48;
    for (let i = 0; i < half; i++) {
      const lo = Math.max(0, i - R);
      const hi = Math.min(half, i + R + 1);
      floor[i] = (prefix[hi] - prefix[lo]) / (hi - lo);
    }
  }

  // Strongest peak within ±cents of f. prom = height above the noise floor (dB).
  peakNear(f, cents) {
    const { df, db, floor } = this;
    const half = this.n / 2;
    const r = 2 ** (cents / 1200);
    let lo = Math.floor(f / r / df);
    let hi = Math.ceil((f * r) / df);
    const c = Math.round(f / df);
    lo = Math.max(1, Math.min(lo, c - 2));
    hi = Math.min(half - 2, Math.max(hi, c + 2));
    if (lo >= hi) return null;
    let best = lo;
    for (let i = lo + 1; i <= hi; i++) if (db[i] > db[best]) best = i;
    if (best === lo || best === hi) {
      // Peak at the edge: check that it really is a local maximum.
      if (db[best - 1] > db[best] || db[best + 1] > db[best]) return null;
    }
    const a = db[best - 1];
    const b = db[best];
    const g = db[best + 1];
    const den = a - 2 * b + g;
    const p = den !== 0 ? (0.5 * (a - g)) / den : 0;
    return { freq: (best + p) * df, db: b, prom: b - floor[best] };
  }

  // Phase-based refinement of a frequency near fc.
  refine(fc) {
    const buf = this.buf;
    const M = fc < 150 ? 16384 : fc < 600 ? 8192 : 4096;
    const H = M / 2;
    if (buf.length < M + H) return fc;
    const w = hann(M);
    const omega = (2 * Math.PI * fc) / this.sr;
    const s1 = buf.length - M - H;
    const s2 = buf.length - M;
    const p1 = dftPhase(buf, s1, M, omega, w);
    const p2 = dftPhase(buf, s2, M, omega, w);
    let d = p2 - p1 - omega * H;
    d -= 2 * Math.PI * Math.round(d / (2 * Math.PI));
    const f = fc + (d * this.sr) / (2 * Math.PI * H);
    return Math.abs(f - fc) < 0.6 * this.df ? f : fc;
  }

  // Exact frequency of a partial near target, or null if it is not heard.
  measure(target, cents = 60, minProm = 10) {
    const pk = this.peakNear(target, cents);
    if (!pk || pk.prom < minProm) return null;
    return { freq: this.refine(pk.freq), prom: pk.prom };
  }

  // Zoomed spectrum: magnitude (dB) at `bins` points from +cents to −cents
  // around fc. Used for the beat view.
  zoom(fc, cents, bins) {
    const buf = this.buf;
    // Whole buffer below 600 Hz: the main lobe is then ±10 cents at C4 instead
    // of ±38, so the trace is visible within ±30 cents.
    const M = Math.min(buf.length, fc < 600 ? 32768 : 16384);
    const w = hann(M);
    const start = buf.length - M;
    const out = new Float32Array(bins);
    for (let i = 0; i < bins; i++) {
      const c = cents - (2 * cents * i) / (bins - 1);
      const omega = (2 * Math.PI * fc * 2 ** (c / 1200)) / this.sr;
      out[i] = dftDb(buf, start, M, omega, w);
    }
    return out;
  }

  // Guess which key is played by scoring each key on how clearly its expected
  // partials show in the spectrum. Then a subharmonic check: the note an octave
  // (or twelfth) below the winner has all the winner's partials, so it is
  // chosen if its own partials are heard too.
  // margin = the winner's lead over its semitone neighbours (dB).
  detectKey(targets, prevKey = 0, top = KEY_COUNT) {
    const scores = new Float64Array(KEY_COUNT + 1).fill(-Infinity);
    let best = 0;
    let bestScore = -Infinity;
    for (let k = 1; k <= top; k++) {
      let sum = 0;
      let count = 0;
      for (let n = 1; n <= 8; n++) {
        const p = this.partialProm(targets, k, n);
        if (p === null) {
          if (partialFreq(targets.freq[k], targets.B[k], n) > 9000) break;
          continue;
        }
        sum += p;
        count++;
      }
      if (!count) continue;
      scores[k] = sum / Math.max(count, 2);
      const s = scores[k] + (k === prevKey ? 2 : 0);
      if (s > bestScore) {
        bestScore = s;
        best = k;
      }
    }
    if (!best) return { key: 0, score: -Infinity, margin: 0 };
    // One step at a time (octave, twelfth, two octaves and a third), repeated,
    // so two octaves down becomes two octave steps. The third step is for the
    // bass, where partial 5 can be the strongest. Own partials = those not shared with the
    // winner. The two strongest of them count, since one partial can be
    // nearly silent (strike point, unisons cancelling). The thresholds are
    // above noise peaks (~10 dB).
    const sounds = (c, own) => {
      const p = own.map((n) => this.partialProm(targets, c, n)).filter((x) => x !== null).sort((a, b) => b - a).slice(0, 2);
      return p.length >= 1 && Math.min(...p) >= 15 && p.reduce((a, x) => a + x, 0) / p.length >= 20;
    };
    for (let moved = true; moved; ) {
      moved = false;
      for (const [shift, own] of [[12, [3, 5, 7]], [19, [2, 4, 5]], [28, [2, 3, 4]]]) {
        if (best - shift >= 1 && sounds(best - shift, own)) {
          best -= shift;
          moved = true;
          break;
        }
      }
    }
    const neigh = [best - 2, best - 1, best + 1, best + 2]
      .filter((k) => k >= 1 && k <= top)
      .map((k) => scores[k]);
    return { key: best, score: scores[best], margin: scores[best] - Math.max(...neigh) };
  }

  // The partial's height above the noise floor (dB, at least 0), or null if it
  // is outside the measured range (below 50 Hz or above 9 kHz).
  partialProm(targets, k, n) {
    const fn = partialFreq(targets.freq[k], targets.B[k], n);
    if (fn < 50 || fn > Math.min(9000, this.sr * 0.45)) return null;
    const pk = this.peakNear(fn, 45);
    return pk ? Math.max(0, pk.prom) : 0;
  }

  // Estimate B from up to 16 partials. Searches upwards and refines the model
  // after each partial found, so the search window follows the string's real
  // inharmonicity. Linear fit: (f_n/n)² = f0² + f0²·B·n².
  inharmonicity(f1, Bguess) {
    let B = Bguess;
    let f0 = f1 / Math.sqrt(1 + B);
    const pts = [];
    const nyq = this.sr / 2;
    for (let n = 1; n <= 16; n++) {
      const fexp = n * f0 * Math.sqrt(1 + B * n * n);
      if (fexp > nyq * 0.8) break;
      if (fexp < 45) continue;
      const m = this.measure(fexp, n < 4 ? 30 : 20, 12);
      if (!m) continue;
      pts.push([n, m.freq]);
      if (pts.length >= 3) {
        const fit = fitB(pts);
        if (fit) ({ B, f0 } = fit);
      }
    }
    if (pts.length < 4) return null;
    const fit = fitB(pts);
    if (!fit || fit.B <= 0 || fit.B > 0.05) return null;
    return { ...fit, partials: pts.length, maxN: pts[pts.length - 1][0] };
  }
}

function dftPhase(buf, start, M, omega, w) {
  let re = 0;
  let im = 0;
  let cr = 1;
  let ci = 0;
  const c = Math.cos(omega);
  const s = -Math.sin(omega);
  for (let i = 0; i < M; i++) {
    const x = buf[start + i] * w[i];
    re += x * cr;
    im += x * ci;
    const t = cr * c - ci * s;
    ci = cr * s + ci * c;
    cr = t;
  }
  return Math.atan2(im, re);
}

function dftDb(buf, start, M, omega, w) {
  let re = 0;
  let im = 0;
  let cr = 1;
  let ci = 0;
  const c = Math.cos(omega);
  const s = -Math.sin(omega);
  for (let i = 0; i < M; i++) {
    const x = buf[start + i] * w[i];
    re += x * cr;
    im += x * ci;
    const t = cr * c - ci * s;
    ci = cr * s + ci * c;
    cr = t;
  }
  return 10 * Math.log10(re * re + im * im + 1e-20);
}

function fitB(pts) {
  const n = pts.length;
  let sx = 0;
  let sy = 0;
  let sxx = 0;
  let sxy = 0;
  for (const [k, f] of pts) {
    const x = k * k;
    const y = (f / k) ** 2;
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
  }
  const den = n * sxx - sx * sx;
  if (den === 0) return null;
  const slope = (n * sxy - sx * sy) / den;
  const icept = (sy - slope * sx) / n;
  if (icept <= 0) return null;
  return { B: slope / icept, f0: Math.sqrt(icept) };
}

export function rmsDb(buf, len = 2048) {
  let s = 0;
  for (let i = buf.length - len; i < buf.length; i++) s += buf[i] * buf[i];
  return 10 * Math.log10(s / len + 1e-20);
}

export function median(a) {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
