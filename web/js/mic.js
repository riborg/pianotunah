// Mikrofon. AnalyserNode används bara som ringbuffert: read() ger de senaste
// 32768 samplen (~0,7 s), all analys sker i dsp.js.

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

  // Kastar 'insecure' utan https, annars getUserMedia-fel (t.ex. NotAllowedError).
  async start() {
    if (!navigator.mediaDevices?.getUserMedia) throw Object.assign(new Error('insecure'), { name: 'insecure' });
    // Röstbehandling stör mätningen och måste av.
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
