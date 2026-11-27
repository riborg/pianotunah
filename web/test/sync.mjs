// End-to-end test of coming back to a tab: two browser contexts are two
// devices on the same tuning. The one left behind shows where the other got
// to when the tuning order is opened again, and keeps the conflict warning
// when it had unsaved changes of its own.
// Creates a temporary tuning and deletes it afterwards.
//   docker run --rm --network container:pianotunah -v "$PWD":/home/pptruser/pt ghcr.io/puppeteer/puppeteer \
//     node pt/web/test/sync.mjs http://localhost:8080
import puppeteer from 'puppeteer';
import { DEFAULT_SETTINGS } from '../static/js/theory.js';

const base = process.argv[2] || 'http://localhost:8080';
const id = 'sync-' + Date.now().toString(36);
const api = (p, init) => fetch(base + '/api/tunings' + p, init);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = 0;
function check(ok, text) {
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${text}`);
  if (!ok) failed++;
}

const browser = await puppeteer.launch({ args: ['--no-sandbox', `--unsafely-treat-insecure-origin-as-secure=${base}`] });
const errors = [];

// The order on its second step (the pitch raise), first key.
async function reset() {
  const cur = await (await api('/' + id)).json().catch(() => null);
  const r = await api('/' + id, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, name: 'Sync test', rev: cur?.rev ?? 0, settings: DEFAULT_SETTINGS, keys: {}, inharmonicity: {}, partials: {}, history: [], order: { step: 1, i: 0 } }),
  });
  if (!r.ok) throw new Error(`reset: ${r.status}`);
}

// A device: its own storage, the order open.
async function device() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  await page.evaluateOnNewDocument((tid) => {
    try {
      localStorage.setItem('pianotunah.lastTuning', tid);
      localStorage.setItem('pianotunah.lang', 'en');
      localStorage.setItem('pianotunah.order', 'on');
    } catch { /* about:blank */ }
  }, id);
  await page.setViewport({ width: 390, height: 844 });
  await page.goto(base + '/', { waitUntil: 'networkidle0' });
  await page.waitForFunction(() => !document.getElementById('order-panel').hidden);
  return { page, close: () => ctx.close() };
}

const read = (page) =>
  page.evaluate(() => ({
    progress: document.getElementById('order-progress').textContent,
    task: document.getElementById('order-task').textContent,
    message: document.getElementById('message').hidden ? '' : document.getElementById('message-text').textContent,
  }));
const click = (page, sel) => page.evaluate((s) => document.querySelector(s).click(), sel);
const serverPos = async () => (await (await api('/' + id)).json()).order;

// The other device moves on n keys and saves.
async function moveOn(page, n) {
  for (let k = 0; k < n; k++) await click(page, '#order-next');
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange'))); // hidden or not, the queue is flushed soon
  for (let t = 0; t < 40 && (await serverPos()).i !== n; t++) await sleep(250);
}

// Opens the order again, as after a break, and waits for it to settle.
async function reopen(page) {
  await click(page, '#order-close');
  await click(page, '#btn-order');
  await sleep(1500);
  return read(page);
}

try {
  await reset();
  {
    const laptop = await device();
    const phone = await device();
    const before = await read(laptop.page);
    check(before.progress.startsWith('key 1 of'), `the laptop starts on the first key: ${before.progress}, ${before.task}`);
    await moveOn(phone.page, 5);
    const there = await read(phone.page);
    check((await serverPos()).i === 5, `the phone moved on 5 keys and saved: ${there.progress}, ${there.task}`);
    const back = await reopen(laptop.page);
    check(back.progress === there.progress && back.task === there.task, `the laptop shows where the phone got to: ${back.progress}, ${back.task}`);
    check(/latest from another tab/.test(back.message), `and says why: ${back.message}`);
    const again = await reopen(laptop.page);
    check(again.task === back.task, `opened once more, it stays there: ${again.task}`);
    await laptop.close();
    await phone.close();
  }

  await reset();
  {
    const laptop = await device();
    const phone = await device();
    await moveOn(phone.page, 5);
    // An unsaved change on the laptop: its save ends in a conflict.
    await click(laptop.page, '#order-next');
    const back = await reopen(laptop.page);
    check(/not saved/.test(back.message), `with unsaved changes the conflict warning stays: ${back.message}`);
    const there = await read(phone.page);
    check(back.task === there.task, `and the laptop shows the server's position: ${back.task}`);
    check((await serverPos()).i === 5, 'the server keeps the phone\'s position');
    await laptop.close();
    await phone.close();
  }
} finally {
  await browser.close();
  await api('/' + id, { method: 'DELETE' });
}
check(!errors.length, `no page errors${errors.length ? ': ' + errors.join('; ') : ''}`);
process.exit(failed ? 1 : 0);
