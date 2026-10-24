// End-to-end test of the tuning order: headless Chrome with a synthetic piano
// as the microphone, struck in tune or off on the keys the order asks for.
// Creates a temporary tuning and deletes it afterwards.
//   docker run --rm --network container:pianotunah -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
//     node pt/test/order.mjs http://localhost:8080
import puppeteer from 'puppeteer';
import { computeTargets, partialFreq, DEFAULT_SETTINGS } from '../web/js/theory.js';

const base = process.argv[2] || 'http://localhost:8080';
const T = computeTargets(DEFAULT_SETTINGS);
const id = 'order-' + Date.now().toString(36);
const api = (p, init) => fetch(base + '/api/tunings' + p, init);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = 0;
function check(ok, text) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${text}`);
  if (!ok) failed++;
}

await api('/' + id, {
  method: 'PUT',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ id, name: 'Order test', rev: 0, settings: DEFAULT_SETTINGS, keys: {}, inharmonicity: {}, partials: {}, history: [] }),
});

const browser = await puppeteer.launch({
  args: ['--no-sandbox', '--autoplay-policy=no-user-gesture-required',
    `--unsafely-treat-insecure-origin-as-secure=${base}`, '--user-data-dir=/tmp/order-profile'],
});
const page = await browser.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));

// Fake microphone as in survey.mjs: struck tones over faint room noise, the
// previous one damped.
await page.evaluateOnNewDocument((tid) => {
  localStorage.setItem('pianotunah.lastTuning', tid);
  localStorage.setItem('pianotunah.lang', 'en');
  const ctx = new AudioContext();
  const dest = ctx.createMediaStreamDestination();
  const noise = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
  const nd = noise.getChannelData(0);
  for (let i = 0; i < nd.length; i++) nd[i] = (Math.random() - 0.5) * 0.004;
  const ns = Object.assign(ctx.createBufferSource(), { buffer: noise, loop: true });
  ns.connect(dest);
  ns.start();
  navigator.mediaDevices.getUserMedia = async () => {
    await ctx.resume();
    return dest.stream;
  };
  let prev = null;
  window.strike = (partials) => {
    const t = ctx.currentTime;
    if (prev) {
      prev.gain.cancelScheduledValues(t);
      prev.gain.setTargetAtTime(0.0001, t, 0.03);
    }
    const g = ctx.createGain();
    prev = g;
    g.connect(dest);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.3, t + 0.005);
    g.gain.exponentialRampToValueAtTime(0.001, t + 4);
    for (const [f, a] of partials) {
      const o = ctx.createOscillator();
      o.frequency.value = f;
      const og = ctx.createGain();
      og.gain.value = a;
      o.connect(og).connect(g);
      o.start(t);
      o.stop(t + 4.1);
    }
  };
}, id);
await page.setViewport({ width: 1360, height: 1000 });
await page.goto(base + '/', { waitUntil: 'networkidle0' });

const read = () =>
  page.evaluate(() => {
    const $ = (id) => document.getElementById(id);
    return {
      key: Number($('note-sub').textContent.match(/\d+/)?.[0]),
      mode: ['auto', 'lock', 'survey'].find((m) => $('mode-' + m).getAttribute('aria-pressed') === 'true'),
      open: !$('order-panel').hidden,
      step: Number($('order-step').value),
      task: $('order-task').textContent,
      progress: $('order-progress').textContent,
      checks: [...$('order-checks').children].map((c) => c.textContent),
      back: $('order-back').hidden ? '' : $('order-back').textContent,
    };
  });

function strike(k, detune = 0) {
  const f1 = T.freq[k] * 2 ** (detune / 1200);
  const ps = [];
  for (let n = 1; n <= 16; n++) {
    const f = partialFreq(f1, T.B[k], n);
    if (f > 20000) break;
    ps.push([f, (k < 20 && n === 1 ? 0.05 : 1) / n ** 0.8 / 4]);
  }
  return page.evaluate((p) => window.strike(p), ps);
}

// The panel is under the sticky top bar once a key low on the page is clicked.
async function press(sel) {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.click(sel);
}

// Strikes key k every 2.5 s until the order leaves the task (or maxMs).
async function playUntilMoved(k, detune = 0, maxMs = 15000) {
  const before = await read();
  const t0 = Date.now();
  let strikes = 0;
  while (Date.now() - t0 < maxMs) {
    await strike(k, detune);
    strikes++;
    for (let i = 0; i < 10; i++) {
      await sleep(250);
      const s = await read();
      if (s.task !== before.task || s.step !== before.step) return { moved: true, strikes, s };
    }
  }
  return { moved: false, strikes, s: await read() };
}

await page.click('#btn-mic');
await press('#btn-order');
await sleep(300);
let s = await read();
check(s.open && s.step === 0 && s.mode === 'lock', `order opens on step 1 in Lock: ${s.task}`);

// Through the steps without tasks to A4.
await press('#order-next'); // pitch check
await press('#order-skip'); // no pitch raise
await press('#order-next'); // strip
await sleep(300);
s = await read();
check(s.step === 3 && s.key === 49, `step 4 selects A4: ${s.task}`);

let r = await playUntilMoved(49, 8, 8000);
check(!r.moved, `A4 8 cents sharp does not move on (${r.strikes} strikes)`);
r = await playUntilMoved(49);
check(r.moved && r.s.key === 37 && r.strikes >= 2, `A4 in tune moves on after ${r.strikes} strikes: ${r.s.task}`);
check(r.s.checks.some((c) => /^F3–A3 major third 6\.\d\/s wide$/.test(c)), `A3 lists F3–A3 ≈ 7/s: ${r.s.checks.join(' | ')}`);

// Another key meanwhile: the order waits on its own.
await page.click('.key[data-k="16"]');
await sleep(200);
r = await playUntilMoved(16, 0, 6000);
check(!r.moved && r.s.back === 'Back to A3', `another key does not move the order: ${r.s.back}`);
await press('#order-back');
await sleep(200);
check((await read()).key === 37, 'Back returns to A3');

// The temperament, all eleven keys.
r = await playUntilMoved(37);
const seq = [];
while (r.moved && r.s.step === 4) {
  seq.push(r.s.key);
  r = await playUntilMoved(r.s.key);
}
check(seq.join(',') === '42,35,40,33,38,43,36,41,34,39,44', `temperament order ${seq.join(',')}`);
check(r.s.step === 5 && r.s.key === 45, `then the octaves above: ${r.s.task}`);

// The position is kept with the piano.
await sleep(3000); // saving
await page.reload({ waitUntil: 'networkidle0' });
await page.click('#btn-mic');
await sleep(500);
s = await read();
check(s.open && s.step === 5 && s.key === 45, `after reload: step ${s.step + 1}, ${s.task}`);

// Treble: one string, then the unison on the same key.
await page.select('#order-step', '6');
await sleep(300);
s = await read();
check(s.key === 50 && /^Wedge B♭4/.test(s.task), `treble starts with one string: ${s.task}`);
r = await playUntilMoved(50);
check(r.moved && r.s.key === 50 && /strings 1 and 2/.test(r.s.task), `then the unison on B♭4: ${r.s.task}`);
r = await playUntilMoved(50);
check(r.moved && r.s.key === 51, `clean unison moves on: ${r.s.task}`);

await press('#order-close');
await sleep(200);
s = await read();
check(!s.open, 'Close hides the panel');

check(!errors.length, `no page errors${errors.length ? ': ' + errors.join('; ') : ''}`);
await browser.close();
await api('/' + id, { method: 'DELETE' });
process.exit(failed ? 1 : 0);
