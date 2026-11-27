// Diagnostics for the server log, sent only when the server runs with
// DEBUG=1, so `docker compose logs -f` shows what the page does. Lines are
// batched every two seconds.

const id = Math.random().toString(36).slice(2, 6);
const queue = [];
let on = false;

export function enableDiag() {
  if (on) return;
  on = true;
  setInterval(flush, 2000);
  window.addEventListener('pagehide', flush);
}

export const diagOn = () => on;

export function diag(line) {
  if (on && queue.length < 200) queue.push(line);
}

function flush() {
  if (!queue.length) return;
  const body = JSON.stringify({ id, lines: queue.splice(0, 100) });
  fetch('api/log', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body, keepalive: true }).catch(() => {});
}
