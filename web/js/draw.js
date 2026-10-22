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
  // not be read back, or the canvas grows every frame on HiDPI screens. A
  // canvas marked data-fluid takes its height from CSS instead.
  const fluid = 'fluid' in c.dataset;
  if (!fluid) c.dataset.h ||= c.getAttribute('height');
  const h = fluid ? c.clientHeight : Number(c.dataset.h);
  if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
    if (!fluid) c.style.height = h + 'px';
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

// Dial: a half circle with the needle over a ±50 cent scale, compressed so
// the centre gets the most room, and strobe rings behind it. Proportions are
// of the canvas width; the note hub is HTML, placed by .dial in style.css
// (DIAL.cy, DIAL.hub). Rings as on a mechanical strobe: one per band
// (bands: [{ p, c }], innermost first), still = in tune, clockwise = too high,
// a ring an octave up turns twice as fast. Each ring is a whole circle clipped
// to the upper half, so it never runs empty. A ring without a reading is grey
// and still. phases (three angles) is updated.
const DIAL = { cy: 0.54, hub: 0.15, rings: [[0.185, 0.25], [0.26, 0.325], [0.335, 0.39]], segs: [10, 14, 18], r: 0.41, max: (80 * Math.PI) / 180 };

export function drawDial(canvas, { display, signal, bands, live, tol }, C, dt, phases) {
  const { ctx, w } = fitCanvas(canvas);
  const cx = w / 2;
  const cy = w * DIAL.cy;
  const R = w * DIAL.r;
  const still = reducedMotion();
  // Angle from straight up, and the canvas angle for it.
  const ang = (c) => Math.sign(c) * Math.sqrt(Math.min(Math.abs(c), 50) / 50) * DIAL.max;
  const ca = (a) => -Math.PI / 2 + a;
  const at = (a, r) => [cx + r * Math.sin(a), cy - r * Math.cos(a)];

  ctx.save();
  ctx.beginPath();
  ctx.rect(0, 0, w, cy);
  ctx.clip();
  DIAL.rings.forEach(([f0, f1], i) => {
    const r0 = w * f0;
    const r1 = w * f1;
    const band = bands[i];
    const on = live && Number.isFinite(band?.c);
    ctx.fillStyle = C.stripe2;
    ctx.beginPath();
    ctx.arc(cx, cy, r1, 0, 2 * Math.PI);
    ctx.arc(cx, cy, r0, 2 * Math.PI, 0, true);
    ctx.fill();
    if (on && !still) phases[i] = (phases[i] + Math.max(-30, Math.min(30, band.c)) * 0.045 * 2 ** i * dt) % (2 * Math.PI);
    const step = Math.PI / DIAL.segs[i];
    ctx.fillStyle = on ? scaleColor(band.c, tol, C) : C.faint;
    for (let j = 0; j < 2 * DIAL.segs[i]; j++) {
      const s = phases[i] + j * step;
      ctx.beginPath();
      ctx.arc(cx, cy, r1, s, s + step / 2);
      ctx.arc(cx, cy, r0, s + step / 2, s, true);
      ctx.fill();
    }
  });
  ctx.restore();

  // Partial number at the right end of each ring.
  ctx.font = `600 ${Math.max(10, w * 0.022)}px ${MONO}`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  DIAL.rings.forEach(([f0, f1], i) => {
    if (!bands[i]) return;
    const [x, y] = at((84 * Math.PI) / 180, (w * (f0 + f1)) / 2);
    ctx.fillStyle = C.surface;
    ctx.beginPath();
    ctx.arc(x, y - 2, Math.max(8, w * 0.018), 0, 2 * Math.PI);
    ctx.fill();
    ctx.fillStyle = C.muted;
    ctx.fillText(bands[i].p, x, y - 1.5);
  });

  // Tolerance and scale.
  ctx.fillStyle = C.good;
  ctx.globalAlpha = 0.22;
  ctx.beginPath();
  ctx.arc(cx, cy, R + w * 0.04, ca(ang(-tol)), ca(ang(tol)));
  ctx.arc(cx, cy, R, ca(ang(tol)), ca(ang(-tol)), true);
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.strokeStyle = C.muted;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.arc(cx, cy, R, ca(-DIAL.max), ca(DIAL.max));
  ctx.stroke();
  const tick = (t, len, color, width = 1) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(...at(ang(t), R));
    ctx.lineTo(...at(ang(t), R + len));
    ctx.stroke();
  };
  for (const t of [3, 4, 6, 7, 8, 9, 15, 25, 30, 35, 40, 45]) {
    tick(t, w * 0.014, C.faint);
    tick(-t, w * 0.014, C.faint);
  }
  ctx.font = `${Math.max(10, Math.min(12, w * 0.022))}px ${MONO}`;
  ctx.fillStyle = C.muted;
  for (const t of [-50, -20, -10, -5, -2, -1, 0, 1, 2, 5, 10, 20, 50]) {
    if (t === 0) tick(t, w * 0.045, C.ink, 2);
    else tick(t, w * 0.026, C.muted);
    if (Math.abs(t) !== 1 || w > 450) ctx.fillText(signed(t), ...at(ang(t), R + w * 0.065));
  }

  // Needle, with a halo in the card color so it reads over the rings.
  if (!Number.isFinite(display)) return;
  const a = ang(display);
  const from = at(a, w * DIAL.hub + 4);
  const to = at(a, R + w * 0.03);
  ctx.lineCap = 'round';
  ctx.globalAlpha = signal ? 1 : 0.35;
  for (const [color, width] of [[C.surface, Math.max(6, w * 0.013)], [scaleColor(display, tol, C), Math.max(3, w * 0.006)]]) {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(...from);
    ctx.lineTo(...to);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

// Strobe: one band per partial, an octave apart (bands: [{ p, c }], top
// first). As on a mechanical strobe, a band an octave up moves twice as fast
// for the same deviation. Still = in tune, moving right = too high. A band
// without a reading is grey and still. phases (three numbers) is updated.
export function drawStrobe(canvas, { bands, live, tol }, C, dt, phases) {
  const { ctx, w, h } = fitCanvas(canvas);
  const still = reducedMotion();
  const bandH = (h - 8) / 3;
  const period = 28;
  const labelW = 26;
  ctx.font = `11px ${MONO}`;
  ctx.textAlign = 'center';
  for (let i = 0; i < 3; i++) {
    const band = bands[i];
    const on = live && Number.isFinite(band?.c);
    const c = on ? Math.max(-30, Math.min(30, band.c)) : 0;
    if (!still) phases[i] = (phases[i] + c * 9 * 2 ** i * dt) % (period * 2);
    const y = 2 + i * (bandH + 2);
    ctx.fillStyle = C.muted;
    ctx.fillText(band ? band.p : '', labelW / 2, y + bandH / 2 + 4);
    ctx.fillStyle = C.stripe2;
    ctx.fillRect(labelW, y, w - labelW, bandH);
    ctx.fillStyle = on ? scaleColor(band.c, tol, C) : C.faint;
    const p = phases[i] / 2 ** i;
    const per = period / 2 ** (i * 0.5);
    for (let x = labelW - per * 2 + (((p % per) + per) % per); x < w; x += per) {
      const x0 = Math.max(x, labelW);
      if (x + per / 2 > x0) ctx.fillRect(x0, y, x + per / 2 - x0, bandH);
    }
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

// Tuning curve: target per key (cents vs equal temperament) and measured
// positions. points: [{ k, c, status }]. ticks: [{ k, label }]. Returns the
// geometry so the caller can map pointer positions to keys.
// With xs (key centres as fractions of the keyboard width, indexed by key)
// the chart lines up with the keyboard below it: same 6 px inset as the keys
// (.keyboard in style.css), no axis margins, y labels inside the plot and C
// guides instead of x labels.
export function drawChart(canvas, { top, target, points, ticks, current, xs }, C) {
  const { ctx, w, h } = fitCanvas(canvas);
  const pad = xs ? { l: 6, r: 6, t: 8, b: 6 } : { l: 44, r: 12, t: 12, b: 28 };

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
      ctx.strokeText(signed(c), pad.l + 2, yOf(c) + 11);
      ctx.fillText(signed(c), pad.l + 2, yOf(c) + 11);
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
