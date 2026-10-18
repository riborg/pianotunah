// Signalbehandling: FFT-spektrum, tangentigenkänning, exakt deltonsmätning och
// skattning av inharmonicitet.
//
// Exakt frekvens tas fram i två steg: grovt läge från FFT-toppen (paraboliskt
// interpolerad), sedan fasskillnaden i en DFT vid samma frekvens över två
// förskjutna fönster. Det ger bråkdelar av en cent även i basen.

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

  // Räkna spektrum (dB) och ett glidande brusgolv för de senaste n samplen.
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

  // Starkaste toppen inom ±cents runt f. prom = höjd över brusgolvet (dB).
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
      // Toppen ligger på kanten: kontrollera att det verkligen är ett lokalt max.
      if (db[best - 1] > db[best] || db[best + 1] > db[best]) return null;
    }
    const a = db[best - 1];
    const b = db[best];
    const g = db[best + 1];
    const den = a - 2 * b + g;
    const p = den !== 0 ? (0.5 * (a - g)) / den : 0;
    return { freq: (best + p) * df, db: b, prom: b - floor[best] };
  }

  // Fasbaserad förfining av en frekvens nära fc.
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

  // Exakt frekvens för en delton nära target, eller null om den inte hörs.
  measure(target, cents = 60, minProm = 10) {
    const pk = this.peakNear(target, cents);
    if (!pk || pk.prom < minProm) return null;
    return { freq: this.refine(pk.freq), prom: pk.prom };
  }

  // Zoomat spektrum: magnitud (dB) i `bins` punkter från +cents till −cents
  // runt fc. Används för svävningsvyn.
  zoom(fc, cents, bins) {
    const buf = this.buf;
    const M = fc < 600 ? 16384 : 8192;
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

  // Gissa vilken tangent som spelas genom att poängsätta varje tangent efter
  // hur tydligt dess förväntade deltoner syns i spektrumet. Därefter en
  // undertonskontroll: tonen en oktav (eller oktav + kvint, två oktaver) under
  // vinnaren har alla vinnarens deltoner, så den väljs om även dess egna
  // deltoner hörs. margin = vinnarens försprång mot halvtonsgrannarna (dB).
  detectKey(targets, prevKey = 0) {
    const scores = new Float64Array(KEY_COUNT + 1).fill(-Infinity);
    let best = 0;
    let bestScore = -Infinity;
    for (let k = 1; k <= KEY_COUNT; k++) {
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
    for (const [shift, own] of [[24, [2, 3, 5]], [19, [2, 4, 5]], [12, [3, 5, 7]]]) {
      const c = best - shift;
      if (c < 1) continue;
      const proms = own.map((n) => this.partialProm(targets, c, n)).filter((p) => p !== null);
      if (proms.length >= 2 && Math.min(...proms) >= 8 && proms.reduce((a, p) => a + p, 0) / proms.length >= 12) {
        best = c;
        break;
      }
    }
    const neigh = [best - 2, best - 1, best + 1, best + 2]
      .filter((k) => k >= 1 && k <= KEY_COUNT)
      .map((k) => scores[k]);
    return { key: best, score: scores[best], margin: scores[best] - Math.max(...neigh) };
  }

  // Deltonens höjd över brusgolvet (dB, minst 0), eller null om den ligger
  // utanför det som mäts (under 50 Hz eller över 9 kHz).
  partialProm(targets, k, n) {
    const fn = partialFreq(targets.freq[k], targets.B[k], n);
    if (fn < 50 || fn > Math.min(9000, this.sr * 0.45)) return null;
    const pk = this.peakNear(fn, 45);
    return pk ? Math.max(0, pk.prom) : 0;
  }

  // Skatta B ur upp till 16 deltoner. Söker uppåt och förfinar modellen efter
  // varje funnen delton så att sökfönstret följer strängens verkliga
  // inharmonicitet. Linjär anpassning: (f_n/n)² = f0² + f0²·B·n².
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
