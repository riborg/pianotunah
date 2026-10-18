// Autosparning av aktuell stämning.
// - Ändringar samlas i 2,5 s innan de sparas.
// - Sparningar körs i tur och ordning, så en långsam kan inte skriva över en senare.
// - 409 (sparad från annan flik/enhet sedan den laddades) går till onConflict.
// - Nätverksfel försöker igen efter 10 s.

import { saveTuning } from './store.js';

const DELAY_MS = 2500;
const RETRY_MS = 10000;

export class Saver {
  dirty = false;
  #timer = 0;
  #chain = Promise.resolve();

  // current(): stämningen som visas nu. onState('idle'|'dirty'|'saving'|'error').
  constructor({ current, onState, onSaved, onConflict }) {
    Object.assign(this, { current, onState, onSaved, onConflict });
  }

  markDirty() {
    this.dirty = true;
    this.onState('dirty');
    if (!this.#timer) this.#timer = setTimeout(() => this.flush(), DELAY_MS);
  }

  // Spara direkt; löses när kön är tom.
  flush() {
    clearTimeout(this.#timer);
    this.#timer = 0;
    const save = () => this.#save();
    this.#chain = this.#chain.then(save, save);
    return this.#chain;
  }

  // Släng osparade ändringar (t.ex. före radering) och vänta in pågående sparning.
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
