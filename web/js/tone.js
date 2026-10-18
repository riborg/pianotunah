// Referenstoner. Egen AudioContext så att uppspelning fungerar oberoende av
// mikrofonen.

import { partialFreq } from './theory.js';

export class TonePlayer {
  ctx = null;
  sine = null;

  get sineOn() {
    return !!this.sine;
  }

  #context() {
    this.ctx ||= new AudioContext();
    this.ctx.resume?.();
    return this.ctx;
  }

  // Kort pianolik ton: tio inharmoniska deltoner som klingar av, de höga
  // snabbare. Returnerar hur länge den hörs (ms).
  pluck(f1, B) {
    const ctx = this.#context();
    const now = ctx.currentTime;
    const out = ctx.createGain();
    out.gain.value = 0.22;
    out.connect(ctx.destination);
    let longest = 0;
    for (let n = 1; n <= 10; n++) {
      const f = partialFreq(f1, B, n);
      if (f > ctx.sampleRate * 0.45) break;
      const decay = Math.max(0.4, 3.2 - n * 0.25);
      longest = Math.max(longest, decay);
      const osc = ctx.createOscillator();
      osc.frequency.value = f;
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, now);
      g.gain.exponentialRampToValueAtTime(1 / n ** 1.1, now + 0.008);
      g.gain.exponentialRampToValueAtTime(0.0001, now + decay);
      osc.connect(g).connect(out);
      osc.start(now);
      osc.stop(now + decay + 0.05);
    }
    return longest * 1000;
  }

  // Ren, ihållande sinuston. Anropas igen för att byta frekvens.
  startSine(f) {
    if (this.sine) return this.setSine(f);
    const ctx = this.#context();
    const t = ctx.currentTime;
    const osc = ctx.createOscillator();
    osc.frequency.value = f;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.18, t + 0.04);
    osc.connect(g).connect(ctx.destination);
    osc.start(t);
    this.sine = { osc, g };
  }

  setSine(f) {
    this.sine?.osc.frequency.setTargetAtTime(f, this.ctx.currentTime, 0.01);
  }

  stopSine() {
    if (!this.sine) return;
    const { osc, g } = this.sine;
    const t = this.ctx.currentTime;
    g.gain.cancelScheduledValues(t);
    g.gain.setValueAtTime(g.gain.value, t);
    g.gain.linearRampToValueAtTime(0, t + 0.06);
    osc.stop(t + 0.08);
    this.sine = null;
  }
}
