// Autosave of the current tuning.
// - Changes are collected for 2.5 s before saving.
// - Saves run in order, so a slow one cannot overwrite a later one.
// - 409 (saved from another tab/device since it was loaded) goes to onConflict.
// - Network errors retry after 10 s.

import { saveTuning } from './store.js';

const DELAY_MS = 2500;
const RETRY_MS = 10000;

export class Saver {
  dirty = false;
  #timer = 0;
  #chain = Promise.resolve();

  // current(): the tuning shown now. onState('idle'|'dirty'|'saving'|'error').
  constructor({ current, onState, onSaved, onConflict }) {
    Object.assign(this, { current, onState, onSaved, onConflict });
  }

  markDirty() {
    this.dirty = true;
    this.onState('dirty');
    if (!this.#timer) this.#timer = setTimeout(() => this.flush(), DELAY_MS);
  }

  // Save now; resolves when the queue is empty.
  flush() {
    clearTimeout(this.#timer);
    this.#timer = 0;
    const save = () => this.#save();
    this.#chain = this.#chain.then(save, save);
    return this.#chain;
  }

  // Drop unsaved changes (e.g. before deleting) and wait for a save in progress.
  discard() {
    clearTimeout(this.#timer);
    this.#timer = 0;
    this.dirty = false;
    return this.#chain;
  }

  async #save() {
    const t = this.current();
    if (!this.dirty || !t) return;
    this.dirty = false;
    t.updatedAt = new Date().toISOString();
    this.onState('saving');
    try {
      const r = await saveTuning(t);
      if (r?.rev) t.rev = r.rev;
      this.onSaved(t);
      if (t === this.current()) this.onState(this.dirty ? 'dirty' : 'idle');
    } catch (e) {
      if (t !== this.current()) return;
      if (e.status === 409) return this.onConflict(t);
      this.dirty = true;
      this.onState('error');
      this.#timer = setTimeout(() => this.flush(), RETRY_MS);
    }
  }
}
