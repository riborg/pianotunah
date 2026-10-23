// End-to-end test of the survey: headless Chrome with a synthetic piano as
// the microphone that plays whatever key the app asks for. Creates a
// temporary tuning and deletes it afterwards.
//   docker run --rm --network container:pianotunah -v "$PWD":/usr/src/app/pt zenika/alpine-chrome:with-puppeteer \
//     node pt/test/survey.mjs http://localhost:8080 [full]
import puppeteer from 'puppeteer';
import { computeTargets, partialFreq, DEFAULT_SETTINGS } from '../web/js/theory.js';

const base = process.argv[2] || 'http://localhost:8080';
const withFull = process.argv[3] === 'full';
const DETUNE = -8; // the synthetic piano is this many cents flat
const T = computeTargets(DEFAULT_SETTINGS);
const id = 'survey-' + Date.now().toString(36);
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
  body: JSON.stringify({ id, name: 'Survey test', rev: 0, settings: DEFAULT_SETTINGS, keys: {}, inharmonicity: {}, partials: {}, history: [] }),
});

const browser = await puppeteer.launch({
  args: ['--no-sandbox', '--autoplay-policy=no-user-gesture-required',
    // The microphone needs a secure context; the test server is reached over http.
    `--unsafely-treat-insecure-origin-as-secure=${base}`, '--user-data-dir=/tmp/survey-profile'],
});
const page = await browser.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));

// Fake microphone: struck tones on top of faint room noise. A new key
// damps the previous one, except in the undamped treble (above F6).
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
  window.strike = (partials, damped) => {
    const t = ctx.currentTime;
    if (prev?.damped) {
      prev.g.gain.cancelScheduledValues(t);
      prev.g.gain.setTargetAtTime(0.0001, t, 0.03);
    }
    const g = ctx.createGain();
    prev = { g, damped };
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
      note: $('note-name').textContent,
      mode: ['auto', 'lock', 'survey'].find((m) => $('mode-' + m).getAttribute('aria-pressed') === 'true'),
      progress: $('survey-progress').textContent,
      step: $('survey-step').textContent,
      msg: $('message').hidden ? '' : $('message-text').textContent,
    };
  });

function strike(k) {
  const f1 = T.freq[k] * 2 ** (DETUNE / 1200);
  const ps = [];
  for (let n = 1; n <= 16; n++) {
    const f = partialFreq(f1, T.B[k], n);
    if (f > 20000) break;
    ps.push([f, (k < 20 && n === 1 ? 0.05 : 1) / n ** 0.8 / 4]);
  }
  return page.evaluate((p, d) => window.strike(p, d), ps, k <= 69);
}

// Plays the keys the survey asks for until it ends. wrong: { asked: struck }
// for the first 4 s on that key. skip: key to skip. stopAfter: number of keys
// after which Finish is clicked.
async function survey(plan, { wrong = {}, skip, stopAfter, maxMs = 400000 } = {}) {
  if ((await read()).mode !== 'survey') await page.click('#mode-survey');
  await page.click(`[data-plan="${plan}"]`);
  await sleep(300);
  const start = await read();
  const t0 = Date.now();
  const seq = [];
  const hints = {};
  let cur = 0;
  let onKeySince = 0;
  let last = 0;
  while (Date.now() - t0 < maxMs) {
    const s = await read();
    if (s.mode !== 'survey') break;
    if (s.key !== cur) {
      cur = s.key;
      seq.push(cur);
      onKeySince = Date.now();
      last = 0;
      if (stopAfter && seq.length > stopAfter) {
        await page.click('#survey-stop');
        break;
      }
      if (cur === skip) {
        await page.click('#survey-skip');
        continue;
      }
      await sleep(400);
    }
    const onKey = Date.now() - onKeySince;
    const wrongNow = wrong[cur] && onKey < 4000;
    if (wrongNow && onKey > 2500) hints[cur] = s.step;
    if (Date.now() - last > 2500 || (wrong[cur] && !wrongNow && last < onKeySince + 4000)) {
      await strike(wrongNow ? wrong[cur] : cur);
      last = Date.now();
    }
    await sleep(150);
  }
  const end = await read();
  return { start, end, seq, hints, secs: (Date.now() - t0) / 1000 };
}

const tuning = async () => (await api('/' + id)).json();
const offset = (t, k) => 1200 * Math.log2(t.keys[k].hz / (partialFreq(T.freq[k], T.B[k], t.keys[k].n) * 2 ** (DETUNE / 1200)));

try {
  await page.click('#btn-mic');
  await sleep(1000);

  let r = await survey('quick', { wrong: { 1: 40, 25: 37, 49: 50 } });
  const allA = [1, 13, 25, 37, 49, 61, 73, 85];
  check(JSON.stringify(r.seq) === JSON.stringify(allA), `all A: asks for A0–A7 (${r.secs.toFixed(0)} s)`);
  check(r.end.mode === 'lock' && r.end.note === 'A4' && /done/.test(r.end.msg), `all A: ends by itself on A4: "${r.end.msg}"`);
  check(/C4/.test(r.hints[1] || ''), `C4 struck for A0 is noticed: "${r.hints[1]}"`);
  check(/A3/.test(r.hints[25] || ''), `A3 struck for A2 is noticed: "${r.hints[25]}"`);
  check(/B♭4/.test(r.hints[49] || ''), `B♭4 struck for A4 is noticed: "${r.hints[49]}"`);
  await sleep(3000); // autosave
  let t = await tuning();
  for (const k of [25, 49]) {
    const c = offset(t, k);
    const b = t.inharmonicity[k] / T.B[k];
    check(Math.abs(c) < 1 && Math.abs(b - 1) < 0.1, `key ${k} saved from the right note: ${c.toFixed(1)} cents, B ${b.toFixed(2)} × model`);
  }

  r = await survey('quick', { skip: 37 });
  check(/^0 /.test(r.start.progress), `second run starts at 0: "${r.start.progress}"`);
  check(/Skipped: A3/.test(r.end.msg), `skipped key is reported: "${r.end.msg}"`);

  if (withFull) {
    r = await survey('full', { stopAfter: 10 });
    await sleep(3000); // autosave
    t = await tuning();
    const left = Array.from({ length: 88 }, (_, i) => i + 1).filter((k) => !t.keys[k]?.mapped);
    r = await survey('full');
    check(JSON.stringify(r.seq) === JSON.stringify(left), `all keys: resumes at key ${left[0]} and asks only for the ${left.length} keys not yet surveyed (${r.secs.toFixed(0)} s)`);
    check(r.end.mode === 'lock' && r.end.note === 'A4' && /done/.test(r.end.msg), `all keys: ends by itself on A4: "${r.end.msg}"`);
  }
  check(errors.length === 0, `no page errors ${errors.join('; ')}`);
} finally {
  await browser.close();
  await api('/' + id, { method: 'DELETE' });
}
process.exit(failed ? 1 : 0);
