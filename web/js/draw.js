// Canvas drawing. Pure functions: everything they need is passed in, no app
// state is read here.

const MONO = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
const signed = (v) => (v === 0 ? '0' : (v > 0 ? '+' : '−') + Math.abs(v));
const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

// Fit the canvas to its CSS width and the screen's pixel density.
export function fitCanvas(c) {
  const dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth;
  // Logical height is read once: c.height is rewritten with dpr below and must
  // not be read back, or the canvas grows every frame on HiDPI screens.
  c.dataset.h ||= c.getAttribute('height');
  const h = Number(c.dataset.h);
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
    c.style.height = h + 'px';
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  return { ctx, w, h };
}

// Theme colors from the CSS variables. Reread when the theme changes.
export function readColors() {
  const cs = getComputedStyle(document.documentElement);
  const C = {};
  for (const t of ['ink', 'muted', 'faint', 'line', 'surface', 'accent', 'good', 'warn', 'bad', 'stripe2', 'scale-yellow', 'scale-orange']) {
    C[t] = cs.getPropertyValue('--' + t).trim();
  }
  C.rgb = [C.good, C['scale-yellow'], C['scale-orange'], C.bad].map(hexRgb);
  return C;
}

function hexRgb(hex) {
  const h = hex.replace('#', '');
  const v = parseInt(h.length === 3 ? h.replace(/./g, '$&$&') : h, 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

// Color for a deviation: green within tolerance, then yellow, orange and red.
export function scaleRgb(c, tol, C) {
  const stops = [tol, Math.max(3, tol * 2.5), Math.max(6, tol * 5), Math.max(12, tol * 10)];
  const a = Math.abs(c);
  if (a <= stops[0]) return C.rgb[0];
  for (let i = 1; i < stops.length; i++) {
    if (a <= stops[i]) {
      const t = (a - stops[i - 1]) / (stops[i] - stops[i - 1]);
      return C.rgb[i - 1].map((v, j) => Math.round(v + (C.rgb[i][j] - v) * t));
    }
  }
  return C.rgb[3];
}

export const scaleColor = (c, tol, C) => `rgb(${scaleRgb(c, tol, C).join(' ')})`;

// Needle ±50 cents on a compressed scale so the centre gets the most room.
export function drawMeter(canvas, { display, signal, tol }, C) {
  const { ctx, w } = fitCanvas(canvas);
  const xOf = (c) => w / 2 + Math.sign(c) * Math.sqrt(Math.min(Math.abs(c), 50) / 50) * (w / 2 - 14);
  ctx.fillStyle = C.good;
  ctx.globalAlpha = 0.18;
  ctx.fillRect(xOf(-tol), 8, xOf(tol) - xOf(-tol), 34);
  ctx.globalAlpha = 1;
  ctx.font = `11px ${MONO}`;
  ctx.textAlign = 'center';
  for (const t of [-50, -20, -10, -5, -2, -1, 0, 1, 2, 5, 10, 20, 50]) {
    const x = xOf(t);
    ctx.strokeStyle = t === 0 ? C.ink : C.muted;
    ctx.lineWidth = t === 0 ? 2 : 1;
    ctx.beginPath();
    ctx.moveTo(x, t === 0 ? 6 : 16);
    ctx.lineTo(x, 42);
    ctx.stroke();
    if (Math.abs(t) !== 1 || w > 500) {
      ctx.fillStyle = C.muted;
      ctx.fillText(signed(t), x, 58);
    }
  }
  if (!Number.isFinite(display)) return;
  const x = xOf(display);
  ctx.globalAlpha = signal ? 1 : 0.35;
  ctx.fillStyle = scaleColor(display, tol, C);
  ctx.beginPath();
  ctx.moveTo(x, 42);
  ctx.lineTo(x - 7, 12);
  ctx.lineTo(x + 7, 12);
  ctx.closePath();
  ctx.fill();
  ctx.globalAlpha = 1;
}

// Strobe: three bands at 1, 2 and 4 times the speed. Still = in tune,
// moving right = too high. phases (three numbers) is updated.
export function drawStrobe(canvas, { display, live, tol }, C, dt, phases) {
  const { ctx, w, h } = fitCanvas(canvas);
  const c = live ? Math.max(-30, Math.min(30, display)) : 0;
  const still = reducedMotion();
  const bandH = (h - 8) / 3;
  const period = 28;
  for (let i = 0; i < 3; i++) {
    if (!still) phases[i] = (phases[i] + c * 9 * 2 ** i * dt) % (period * 2);
    const y = 2 + i * (bandH + 2);
    ctx.fillStyle = C.stripe2;
    ctx.fillRect(0, y, w, bandH);
    ctx.fillStyle = live ? scaleColor(display, tol, C) : C.faint;
    const p = phases[i] / 2 ** i;
    const per = period / 2 ** (i * 0.5);
    for (let x = -per * 2 + (((p % per) + per) % per); x < w; x += per) ctx.fillRect(x, y, per / 2, bandH);
  }
}

// Zoomed spectrogram around the target partial. cols: { col: dB per row,
// c: deviation } or null (silence), oldest first. Brightness = level within
// 12 dB of the column's peak, color = deviation at that moment.
const specImg = { canvas: null, ctx: null, data: null };
const SPEC_RANGE_DB = 12;

export function drawSpectro(canvas, cols, { capacity, bins, cents, tol }, C) {
  const { ctx, w, h } = fitCanvas(canvas);
  const padL = 30;
  const pw = w - padL;
  if (specImg.canvas?.width !== capacity || specImg.canvas?.height !== bins) {
    specImg.canvas = Object.assign(document.createElement('canvas'), { width: capacity, height: bins });
    specImg.ctx = specImg.canvas.getContext('2d');
    specImg.data = specImg.ctx.createImageData(capacity, bins);
  }
  const px = specImg.data.data;
  px.fill(0);
  const offset = capacity - cols.length;
  cols.forEach((s, i) => {
    if (!s) return;
    const peak = Math.max(...s.col);
    const [r, g, b] = scaleRgb(s.c, tol, C);
    for (let y = 0; y < bins; y++) {
      const o = (y * capacity + offset + i) * 4;
      px[o] = r;
      px[o + 1] = g;
      px[o + 2] = b;
      px[o + 3] = Math.round(Math.max(0, Math.min(1, (s.col[y] - peak + SPEC_RANGE_DB) / SPEC_RANGE_DB)) ** 1.5 * 255);
    }
  });
  specImg.ctx.putImageData(specImg.data, 0, 0);
  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(specImg.canvas, padL, 0, pw, h);

  const yOf = (c) => h / 2 - (Math.max(-cents, Math.min(cents, c)) / cents) * (h / 2);
  ctx.strokeStyle = C.muted;
  ctx.lineWidth = 1;
  ctx.setLineDash([2, 4]);
  for (const c of [-tol, tol]) {
    ctx.beginPath();
    ctx.moveTo(padL, yOf(c));
    ctx.lineTo(w, yOf(c));
    ctx.stroke();
  }
  ctx.setLineDash([]);
  ctx.strokeStyle = C.ink;
  ctx.globalAlpha = 0.5;
  ctx.beginPath();
  ctx.moveTo(padL, h / 2);
  ctx.lineTo(w, h / 2);
  ctx.stroke();
  ctx.globalAlpha = 1;

  // Exact measured deviation as a thin line on top.
  const colW = pw / capacity;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  let drawing = false;
  cols.forEach((s, i) => {
    if (!s) return void (drawing = false);
    const x = padL + (offset + i + 0.5) * colW;
    if (drawing) ctx.lineTo(x, yOf(s.c));
    else ctx.moveTo(x, yOf(s.c));
    drawing = true;
  });
  ctx.stroke();

  ctx.fillStyle = C.muted;
  ctx.font = `10px ${MONO}`;
  ctx.textAlign = 'right';
  ctx.fillText('+' + cents, padL - 4, 11);
  ctx.fillText('0', padL - 4, h / 2 + 3);
  ctx.fillText('−' + cents, padL - 4, h - 3);
}

// Beat strip: two tones Δf Hz apart pulse Δf times per second. Shows the
// last 3 seconds. Returns the new phase.
export function drawBeat(canvas, { beatHz, display, live, tol }, C, dt, phase) {
  const { ctx, w, h } = fitCanvas(canvas);
  if (!live) {
    ctx.strokeStyle = C.faint;
    ctx.beginPath();
    ctx.moveTo(0, h / 2);
    ctx.lineTo(w, h / 2);
    ctx.stroke();
    return phase;
  }
  const df = Math.min(Math.abs(beatHz), 40);
  if (!reducedMotion()) phase = (phase + df * dt) % 1000;
  const span = 3;
  const edge = [];
  for (let x = 0; x <= w; x += 2) {
    const env = df < 0.1 ? 1 : Math.abs(Math.cos(Math.PI * (phase - (df * (w - x) * span) / w)));
    edge.push([x, h / 2 - env * (h / 2 - 3)]);
  }
  ctx.fillStyle = scaleColor(display, tol, C);
  ctx.globalAlpha = 0.85;
  ctx.beginPath();
  edge.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
  for (let i = edge.length - 1; i >= 0; i--) ctx.lineTo(edge[i][0], h - edge[i][1]);
  ctx.closePath();
  ctx.fill();
  ctx.globalAlpha = 1;
  return phase;
}

// Deviation per key as bars around the target (zero line), drawn on the
// piano case's dark background in both color modes. bars: [{ x: 0..1, d: cents }].
// The scale is ±5, 10, 20 or 30 cents after the largest deviation; larger are
// clipped. Returns the scale.
export function drawDeviations(canvas, { bars, current, barW, tol }, C) {
  const { ctx, w, h } = fitCanvas(canvas);
  const max = Math.max(0, ...bars.map((b) => Math.abs(b.d)));
  const range = [5, 10, 20, 30].find((r) => max <= r) ?? 30;
  const mid = h / 2;
  const yOf = (d) => mid - (Math.max(-range, Math.min(range, d)) / range) * (mid - 3);
  ctx.fillStyle = C.good;
  ctx.globalAlpha = 0.16;
  ctx.fillRect(0, yOf(tol), w, yOf(-tol) - yOf(tol));
  ctx.globalAlpha = 1;
  ctx.fillStyle = 'rgb(255 255 255 / 0.22)';
  ctx.fillRect(0, mid - 0.5, w, 1);
  if (current != null) {
    ctx.fillStyle = C.accent;
    ctx.globalAlpha = 0.5;
    ctx.fillRect(current * w - 1, 0, 2, h);
    ctx.globalAlpha = 1;
  }
  const bw = Math.max(2, barW * w);
  for (const { x, d } of bars) {
    const y = yOf(d);
    ctx.fillStyle = scaleColor(d, tol, C);
    ctx.fillRect(x * w - bw / 2, Math.min(y, mid), bw, Math.max(1.5, Math.abs(y - mid)));
  }
  return range;
}

// Tuning curve: target per key (cents vs equal temperament) and measured
// positions. points: [{ k, c, status }]. ticks: [{ k, label }]. Returns the
// geometry so the caller can map pointer positions to keys.
// With xs (key centres as fractions of the keyboard width, indexed by key)
// the chart lines up with the keyboard: same 10 px inset as the keyboard
// case, no axis margins, y labels inside the plot and C guides instead of
// x labels. labelX keeps the y labels at the visible left edge when the
// keyboard is scrolled.
export function drawChart(canvas, { top, target, points, ticks, current, xs, labelX = 0 }, C) {
  const { ctx, w, h } = fitCanvas(canvas);
  const pad = xs ? { l: 10, r: 10, t: 8, b: 8 } : { l: 44, r: 12, t: 12, b: 28 };

  const vals = [...target.slice(1, top + 1), ...points.map((p) => p.c)];
  const lo = Math.min(-10, ...vals);
  const hi = Math.max(10, ...vals);
  // Coarser grid when the range is large or the chart is low.
  const lines = (s) => Math.ceil(hi / s) - Math.floor(lo / s);
  const step = [10, 20, 50, 100].find((s) => lines(s) <= (h - pad.t - pad.b) / 18) ?? 100;
  const yMin = Math.floor(lo / step) * step;
  const yMax = Math.ceil(hi / step) * step;
  const xOf = xs ? (k) => pad.l + xs[k] * (w - pad.l - pad.r) : (k) => pad.l + ((k - 1) / (top - 1)) * (w - pad.l - pad.r);
  const yOf = (c) => pad.t + ((yMax - c) / (yMax - yMin)) * (h - pad.t - pad.b);

  ctx.font = `11px ${MONO}`;
  ctx.lineWidth = 1;
  ctx.textAlign = 'right';
  for (let c = yMin; c <= yMax; c += step) {
    ctx.strokeStyle = c === 0 ? C.muted : C.line;
    ctx.beginPath();
    ctx.moveTo(pad.l, yOf(c));
    ctx.lineTo(w - pad.r, yOf(c));
    ctx.stroke();
    if (xs) continue;
    ctx.fillStyle = C.muted;
    ctx.fillText(signed(c), pad.l - 6, yOf(c) + 4);
  }
  ctx.textAlign = 'center';
  if (xs) {
    ctx.strokeStyle = C.line;
    for (const { k } of ticks) {
      ctx.beginPath();
      ctx.moveTo(xOf(k), pad.t);
      ctx.lineTo(xOf(k), h - pad.b);
      ctx.stroke();
    }
  }
  if (!xs) ticks.forEach(({ k, label }, i) => {
    ctx.strokeStyle = C.line;
    ctx.beginPath();
    ctx.moveTo(xOf(k), h - pad.b);
    ctx.lineTo(xOf(k), h - pad.b + 4);
    ctx.stroke();
    if (w > 420 || i % 2 === 0) {
      ctx.fillStyle = C.muted;
      ctx.fillText(label, xOf(k), h - 8);
    }
  });

  ctx.strokeStyle = C.accent;
  ctx.globalAlpha = 0.35;
  ctx.setLineDash([3, 3]);
  ctx.beginPath();
  ctx.moveTo(xOf(current), pad.t);
  ctx.lineTo(xOf(current), h - pad.b);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;

  // The target is drawn key by key so the temperament's jaggedness shows.
  ctx.strokeStyle = C.accent;
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.beginPath();
  for (let k = 1; k <= top; k++) (k === 1 ? ctx.moveTo : ctx.lineTo).call(ctx, xOf(k), yOf(target[k]));
  ctx.stroke();

  for (const p of points) {
    ctx.fillStyle = C.surface;
    ctx.beginPath();
    ctx.arc(xOf(p.k), yOf(p.c), 5.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = C[p.status];
    ctx.beginPath();
    ctx.arc(xOf(p.k), yOf(p.c), 4, 0, Math.PI * 2);
    ctx.fill();
  }

  if (xs) {
    // On top of the curve, with a halo so they stay readable where it passes.
    ctx.font = `10px ${MONO}`;
    ctx.textAlign = 'left';
    ctx.lineWidth = 3;
    ctx.strokeStyle = C.surface;
    ctx.fillStyle = C.muted;
    for (let c = yMin; c <= yMax; c += step) {
      if (c === yMin) continue; // no room below the bottom line
      ctx.strokeText(signed(c), labelX + pad.l + 2, yOf(c) + 11);
      ctx.fillText(signed(c), labelX + pad.l + 2, yOf(c) + 11);
    }
  }

  const nearest = (x) => {
    let best = 1;
    for (let k = 2; k <= top; k++) if (Math.abs(xOf(k) - x) < Math.abs(xOf(best) - x)) best = k;
    return best;
  };
  return {
    xOf,
    yOf,
    keyAt: xs ? nearest : (x) => Math.round(((x - pad.l) / (w - pad.l - pad.r)) * (top - 1)) + 1,
  };
}
