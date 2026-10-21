// End-to-end: headless Chrome with a synthetic piano tone as the microphone.
// Creates a temporary tuning, clicks Start microphone, reads the result and deletes it.
//   docker run --rm --network container:pianotunah -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
//     node pt/test/e2e.mjs http://localhost:8080 [screenshot dir]
import { writeFileSync, mkdirSync } from 'node:fs';
import puppeteer from 'puppeteer';
import { computeTargets, partialFreq, defaultPartial, DEFAULT_SETTINGS } from '../web/js/theory.js';

const base = process.argv[2] || 'http://localhost:8080';
const shots = process.argv[3];
const settings = { ...DEFAULT_SETTINGS };
const T = computeTargets(settings);

// Tone: key k, detune in cents, with inharmonicity and a soft decay.
// unison: a second string that many cents above, at the same strength.
// Chrome loops the file, so every loop is a new attack.
function wav(path, k, detune, unison = 0, secs = 3) {
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
      if (unison) x += Math.sin(2 * Math.PI * f * 2 ** (unison / 1200) * t + 2 * p) / p;
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

async function run({ key, detune, unison = 0, theme = 'light', shot, seed, record }) {
  const file = `/tmp/tone-${key}-${unison}.wav`;
  wav(file, key, detune, unison);
  const tuning = {
    id, name: seed?.name || 'E2E-test', rev: 0, updatedAt: new Date().toISOString(),
    settings: { ...settings, ...(seed?.settings || {}) }, keys: seed?.keys || {}, inharmonicity: {}, partials: {}, history: [],
  };
  await api('/' + id, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(tuning) });
  const browser = await puppeteer.launch({
    args: ['--no-sandbox', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${file}`, '--autoplay-policy=no-user-gesture-required',
      // The microphone needs a secure context; the test server is reached over http.
      `--unsafely-treat-insecure-origin-as-secure=${base}`, '--user-data-dir=/tmp/e2e-profile'],
  });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
    await page.setViewport({ width: 1360, height: 1400, deviceScaleFactor: shot ? 2 : 1 });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }]);
    await page.evaluateOnNewDocument((tid) => {
      localStorage.setItem('pianotunah.lastTuning', tid);
      // Keep downloaded files for the recording check.
      const create = URL.createObjectURL;
      URL.createObjectURL = (b) => ((window.lastBlob = b), create(b));
    }, id);
    await page.goto(base + '/', { waitUntil: 'networkidle0' });
    await page.click('#btn-mic');
    await new Promise((r) => setTimeout(r, shot ? 9000 : 4000));
    const read = (sel) => page.$eval(sel, (el) => el.textContent.trim());
    const res = {
      note: await read('#note-name'), cents: await read('#cents-num'),
      pill: await read('#status-pill'), beat: await read('#beat-rate'), measured: await read('#measured'), errors,
      unisonHint: await page.$eval('#unison-hint', (el) => !el.hidden),
    };
    if (record) {
      // Record 1.5 s (the button is in the closed drawer) and read the WAV file.
      await page.$eval('#btn-rec', (b) => b.click());
      await new Promise((r) => setTimeout(r, 1500));
      await page.click('#btn-rec-stop');
      res.rec = await page.evaluate(async () => {
        const v = new DataView(await window.lastBlob.arrayBuffer());
        const n = v.getUint32(40, true) / 4;
        let s = 0;
        for (let i = 0; i < n; i++) s += v.getFloat32(44 + i * 4, true) ** 2;
        return { format: v.getUint16(20, true), sr: v.getUint32(24, true), secs: n / v.getUint32(24, true), rms: Math.sqrt(s / n), name: document.getElementById('message-text').textContent };
      });
    }
    if (shot) {
      mkdirSync(shots, { recursive: true });
      // The whole page, without the empty viewport below it.
      const clip = { x: 0, y: 0, width: 1360, height: await page.evaluate(() => Math.ceil(document.querySelector('.layout').getBoundingClientRect().bottom) + 24) };
      await page.screenshot({ path: `${shots}/${shot}`, clip });
      // The settings drawer with the reference and stretch.
      await page.click('#btn-settings');
      await page.click('[data-tab="tuning"]');
      await new Promise((r) => setTimeout(r, 400));
      await page.screenshot({ path: `${shots}/${shot.replace('screenshot', 'settings')}`, clip });
    }
    return res;
  } finally {
    await browser.close();
    await api('/' + id, { method: 'DELETE' });
  }
}

const cases = [
  { key: 49, detune: 0, unison: 15 }, // A4 with two strings 15 cents apart: the beat hint shows
  { key: 49, detune: 3, record: true }, // A4, +3 cents, and a recording
  { key: 25, detune: -12 }, // A2, −12 cents (measured on partial 4)
];
let ok = true;
for (const c of cases) {
  const r = await run(c);
  const cents = parseFloat(r.cents.replace('−', '-').replace('±', '').replace(',', '.'));
  // The measured partial in Hz: partial 1, or the partial measured in the bass.
  const n = defaultPartial(c.key);
  const want = partialFreq(T.freq[c.key] * 2 ** (c.detune / 1200), T.B[c.key], n);
  const hz = parseFloat(r.measured.match(/([\d.,]+) Hz/)?.[1].replace(',', '.'));
  const pass = c.unison
    ? r.unisonHint && r.errors.length === 0
    : Math.abs(cents - c.detune) < 0.6 && Math.abs(1200 * Math.log2(hz / want)) < 0.6 && !r.unisonHint && r.errors.length === 0;
  ok &&= pass;
  if (r.rec) {
    const recOk = r.rec.format === 3 && r.rec.secs > 1.2 && r.rec.secs < 1.8 && r.rec.rms > 0.01;
    ok &&= recOk;
    console.log(`${recOk ? 'OK  ' : 'FAIL'} recording: ${r.rec.secs.toFixed(2)} s at ${r.rec.sr} Hz, rms ${r.rec.rms.toFixed(3)} | ${r.rec.name}`);
  }
  console.log(`${pass ? 'OK  ' : 'FAIL'} key ${c.key} ${c.detune} cents${c.unison ? ` + string at ${c.unison}` : ''} → ${r.note} ${r.cents} | ${r.measured} (${want.toFixed(2)} Hz) | ${r.pill} | ${r.beat}${r.unisonHint ? ' | beat hint' : ''}${r.errors.length ? ' | ' + r.errors.join('; ') : ''}`);
}

if (shots) {
  // Example tuning for the README: some measured keys and a sounding note.
  const keys = {};
  const devs = { 37: 0.4, 39: -0.6, 40: 1.8, 42: 0.2, 44: -3.1, 45: 0.8, 47: -0.3, 49: 0.1, 51: 6.5, 52: -0.4, 54: 2.6, 56: 0.6 };
  for (const [k, d] of Object.entries(devs)) {
    const hz = partialFreq(T.freq[k], T.B[k], 1) * 2 ** (d / 1200);
    keys[k] = { n: 1, hz, bn: 1, bhz: hz * 2 ** (-14 / 1200), at: Date.now() };
  }
  const seed = { name: 'Jehle 115 cm', settings: { pianoKind: 'upright', sizeCm: 115, keyCount: 85 }, keys };
  for (const theme of ['light', 'dark']) await run({ key: 40, detune: 2.3, theme, shot: `screenshot-${theme}.png`, seed });
  console.log(`Screenshots in ${shots}`);
}
process.exit(ok ? 0 : 1);
