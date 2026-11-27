// Reference tones. Own AudioContext so playback works independently of the
// microphone.

import { partialFreq } from './theory.js';

export class TonePlayer {
  ctx = null;
  sine = null;
  // Called when the sine was stopped because the sound could not run (as
  // the Mac app's sine watch). The button would otherwise show ■ over
  // silence, with the readings held back for a tone nobody hears.
  onSineLost = null;
  #lostTimer = 0;

  // ms the sound may stay stopped under a playing sine before it is given up:
  // room for a resume that is slow, as after a change of audio route.
  static lostAfterMs = 3000;

  get sineOn() {
    return !!this.sine;
  }

  #context() {
    if (!this.ctx) {
      this.ctx = new AudioContext();
      this.ctx.addEventListener?.('statechange', () => this.#watch());
    }
    this.ctx.resume?.()?.catch?.(() => {});
    return this.ctx;
  }

  // Safari suspends or interrupts the context when the screen locks or
  // another app takes the sound. Under a playing sine: try to resume it, and
  // if it still does not run a moment later, stop the sine and say so.
  #watch() {
    clearTimeout(this.#lostTimer);
    if (!this.sine || this.ctx.state === 'running') return;
    this.ctx.resume?.()?.catch?.(() => {});
    this.#lostTimer = setTimeout(() => {
      if (!this.sine || this.ctx.state === 'running') return;
      this.stopSine();
      this.onSineLost?.();
    }, TonePlayer.lostAfterMs);
  }

  // Short piano-like tone: ten inharmonic partials that decay, the high ones
  // faster. Returns how long it is audible (ms).
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

  // Pure, sustained sine tone. Call again to change the frequency.
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
    this.#watch(); // a context that does not start runs no sine either
  }

  setSine(f) {
    this.sine?.osc.frequency.setTargetAtTime(f, this.ctx.currentTime, 0.01);
  }

  stopSine() {
    clearTimeout(this.#lostTimer);
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
