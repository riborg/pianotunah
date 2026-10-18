// Sparade stämningar på servern (/api/tunings).

import { DEFAULT_SETTINGS } from './theory.js';

const API = 'api/tunings';

async function call(method, path = '', body) {
  const res = await fetch(API + path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${API}${path}: ${res.status}`);
  return res.status === 204 ? null : res.json();
}

export const listTunings = () => call('GET');
export const getTuning = (id) => call('GET', '/' + encodeURIComponent(id));
export const saveTuning = (t) => call('PUT', '/' + encodeURIComponent(t.id), t);
export const deleteTuning = (id) => call('DELETE', '/' + encodeURIComponent(id));

function newId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
}

export function newTuning(name = 'Mitt piano') {
  const now = new Date().toISOString();
  return {
    id: newId(),
    name,
    notes: '',
    createdAt: now,
    updatedAt: now,
    settings: { ...DEFAULT_SETTINGS },
    inharmonicity: {}, // tangent -> uppmätt B
    partials: {}, // tangent -> vald delton (om annan än standard)
    keys: {}, // tangent -> { cents, before, at }
    passStartedAt: now,
    history: [], // avslutade omgångar
  };
}

// Fyll i fält som saknas i äldre sparade stämningar.
export function normalize(t) {
  const base = newTuning(t.name);
  return {
    ...base,
    ...t,
    settings: { ...DEFAULT_SETTINGS, ...(t.settings || {}) },
    inharmonicity: t.inharmonicity || {},
    partials: t.partials || {},
    keys: t.keys || {},
    history: t.history || [],
  };
}

export function duplicateTuning(t, name) {
  const copy = normalize(JSON.parse(JSON.stringify(t)));
  const now = new Date().toISOString();
  return { ...copy, id: newId(), name, createdAt: now, updatedAt: now };
}
