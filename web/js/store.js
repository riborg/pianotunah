// Saved tunings on the server (/api/tunings).

import { DEFAULT_SETTINGS, migrateSettings } from './theory.js';

const API = 'api/tunings';

async function call(method, path = '', body) {
  const res = await fetch(API + path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const err = new Error(`${method} ${API}${path}: ${res.status}`);
    err.status = res.status;
    throw err;
  }
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

export function newTuning(name = '') {
  const now = new Date().toISOString();
  return {
    id: newId(),
    name,
    notes: '',
    createdAt: now,
    updatedAt: now,
    settings: { ...DEFAULT_SETTINGS },
    inharmonicity: {}, // key -> measured B
    partials: {}, // key -> chosen partial (if not the default)
    keys: {}, // key -> { hz, n, bhz, bn, at, mapped }; mapped = surveyed
    passStartedAt: now,
    rev: 0, // server revision; set on every save
    history: [], // finished passes
  };
}

// Fill in fields missing from older saved tunings.
export function normalize(t) {
  const base = newTuning(t.name);
  return {
    ...base,
    ...t,
    settings: { ...DEFAULT_SETTINGS, ...migrateSettings(t.settings) },
    inharmonicity: t.inharmonicity || {},
    partials: t.partials || {},
    keys: t.keys || {},
    history: t.history || [],
  };
}

export function duplicateTuning(t, name) {
  const copy = normalize(JSON.parse(JSON.stringify(t)));
  const now = new Date().toISOString();
  return { ...copy, id: newId(), name, createdAt: now, updatedAt: now, rev: 0 };
}
