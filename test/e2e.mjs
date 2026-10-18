// End-to-end: headless Chrome med syntetisk pianoton som mikrofon.
// Skapar en tillfällig stämning, klickar Starta mikrofon, läser av och raderar.
//   docker run --rm --network caddy -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
//     node pt/test/e2e.mjs http://pianotunah:8080 [skärmdumpskatalog]
import { writeFileSync, mkdirSync } from 'node:fs';
import puppeteer from 'puppeteer';
import { computeTargets, partialFreq, DEFAULT_SETTINGS } from '../web/js/theory.js';

const base = process.argv[2] || 'http://pianotunah:8080';
const shots = process.argv[3];
const settings = { ...DEFAULT_SETTINGS };
const T = computeTargets(settings);

// Ton: tangent k, detune i cent, med inharmonicitet och mjuk avklingning.
// Chrome spelar filen i loop, så varje varv blir ett nytt anslag.
function wav(path, k, detune, secs = 3) {
  const sr = 48000;
  const n = sr * secs;
  const f1 = T.freq[k] * 2 ** (detune / 1200);
  const B = T.B[k];
  const pcm = new Int16Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    let x = 0;
    for (let p = 1; p <= 10; p++) {
      const f = partialFreq(f1, B, p);
      if (f > sr / 2.2) break;
      x += Math.sin(2 * Math.PI * f * t + p) / p;
    }
    pcm[i] = Math.round(x * 0.25 * Math.exp(-t * 0.6) * Math.min(1, t * 200) * 32767);
  }
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVEfmt ', 8);
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sr, 24); buf.writeUInt32LE(sr * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  Buffer.from(pcm.buffer).copy(buf, 44);
  writeFileSync(path, buf);
}

const api = (path, init) => fetch(base + '/api/tunings' + path, init);
const id = 'e2e-' + Date.now().toString(36);

async function run({ key, detune, theme = 'light', shot, seed }) {
  const file = `/tmp/tone-${key}.wav`;
  wav(file, key, detune);
  const tuning = {
    id, name: seed?.name || 'E2E-test', rev: 0, updatedAt: new Date().toISOString(),
    settings: { ...settings, ...(seed?.settings || {}) }, keys: seed?.keys || {}, inharmonicity: {}, partials: {}, history: [],
  };
  await api('/' + id, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(tuning) });
  const browser = await puppeteer.launch({
    args: ['--no-sandbox', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${file}`, '--autoplay-policy=no-user-gesture-required',
      // Mikrofonen kräver säker kontext; testservern nås över http.
      `--unsafely-treat-insecure-origin-as-secure=${base}`, '--user-data-dir=/tmp/e2e-profile'],
  });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
    await page.setViewport({ width: 1360, height: 1180, deviceScaleFactor: shot ? 2 : 1 });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }]);
    await page.evaluateOnNewDocument((tid) => localStorage.setItem('pianotunah.lastTuning', tid), id);
    await page.goto(base + '/', { waitUntil: 'networkidle0' });
    await page.click('#btn-mic');
    await new Promise((r) => setTimeout(r, shot ? 9000 : 4000));
    const read = (sel) => page.$eval(sel, (el) => el.textContent.trim());
    const res = {
      note: await read('#note-name'), cents: await read('#cents-num'),
      pill: await read('#status-pill'), beat: await read('#beat-rate'), errors,
    };
    if (shot) {
      mkdirSync(shots, { recursive: true });
      await page.screenshot({ path: `${shots}/${shot}`, clip: { x: 0, y: 0, width: 1360, height: 1180 } });
    }
    return res;
  } finally {
    await browser.close();
    await api('/' + id, { method: 'DELETE' });
  }
}

const cases = [
  { key: 49, detune: 3 }, // A4, +3 cent
  { key: 25, detune: -12 }, // A2, −12 cent (mäts på delton 4)
];
let ok = true;
for (const c of cases) {
  const r = await run(c);
  const cents = parseFloat(r.cents.replace('−', '-').replace('±', '').replace(',', '.'));
  const pass = Math.abs(cents - c.detune) < 0.6 && r.errors.length === 0;
  ok &&= pass;
  console.log(`${pass ? 'OK  ' : 'FEL '} tangent ${c.key} ${c.detune} cent → ${r.note} ${r.cents} | ${r.pill} | ${r.beat}${r.errors.length ? ' | ' + r.errors.join('; ') : ''}`);
}

if (shots) {
  // Exempelstämning för README: några uppmätta tangenter och en ton som klingar.
  const keys = {};
  const devs = { 37: 0.4, 39: -0.6, 40: 1.8, 42: 0.2, 44: -3.1, 45: 0.8, 47: -0.3, 49: 0.1, 51: 6.5, 52: -0.4, 54: 2.6, 56: 0.6 };
  for (const [k, d] of Object.entries(devs)) {
    const hz = partialFreq(T.freq[k], T.B[k], 1) * 2 ** (d / 1200);
    keys[k] = { n: 1, hz, bn: 1, bhz: hz * 2 ** (-14 / 1200), at: Date.now() };
  }
  const seed = { name: 'Jehle 115 cm', settings: { pianoKind: 'upright', sizeCm: 115, keyCount: 85 }, keys };
  for (const theme of ['light', 'dark']) await run({ key: 40, detune: 2.3, theme, shot: `screenshot-${theme}.png`, seed });
  console.log(`Skärmdumpar i ${shots}`);
}
process.exit(ok ? 0 : 1);
