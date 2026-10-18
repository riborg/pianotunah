// Microphone. AnalyserNode is only used as a ring buffer: read() returns the
// latest 32768 samples (~0.7 s); all analysis happens in dsp.js.

export class Mic {
  ctx = null;
  stream = null;
  analyser = null;
  buf = null;

  get running() {
    return !!this.ctx;
  }

  get sampleRate() {
    return this.ctx.sampleRate;
  }

  // Throws 'insecure' without https, otherwise getUserMedia errors (e.g. NotAllowedError).
  async start() {
    if (!navigator.mediaDevices?.getUserMedia) throw Object.assign(new Error('insecure'), { name: 'insecure' });
    // Voice processing disturbs the measurement and must be off.
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 },
    });
    this.ctx = new AudioContext();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 32768;
    this.ctx.createMediaStreamSource(this.stream).connect(this.analyser);
    this.buf = new Float32Array(this.analyser.fftSize);
  }

  stop() {
    this.stream?.getTracks().forEach((t) => t.stop());
    this.ctx?.close();
    this.ctx = this.stream = this.analyser = null;
  }

  read() {
    this.analyser.getFloatTimeDomainData(this.buf);
    return this.buf;
  }
}
