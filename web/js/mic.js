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

  // Name of the input in use, e.g. "MacBook Pro Microphone".
  get label() {
    return this.stream?.getAudioTracks()[0]?.label || '';
  }

  // deviceId: an input from inputs(), or '' for the system default.
  // Throws 'insecure' without https, otherwise getUserMedia errors (e.g. NotAllowedError,
  // OverconstrainedError when the chosen input is not connected).
  async start(deviceId = '') {
    if (!navigator.mediaDevices?.getUserMedia) throw Object.assign(new Error('insecure'), { name: 'insecure' });
    // Voice processing disturbs the measurement and must be off.
    const audio = { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 };
    if (deviceId) audio.deviceId = { exact: deviceId };
    this.stream = await navigator.mediaDevices.getUserMedia({ audio });
    this.ctx = new AudioContext();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 32768;
    this.ctx.createMediaStreamSource(this.stream).connect(this.analyser);
    this.buf = new Float32Array(this.analyser.fftSize);
  }

  // Audio inputs. Names and ids are empty until the page has had microphone
  // access; Chrome's "default" and "communications" aliases are left out.
  static async inputs() {
    const all = (await navigator.mediaDevices?.enumerateDevices?.()) || [];
    return all.filter((d) => d.kind === 'audioinput' && d.deviceId && !['default', 'communications'].includes(d.deviceId));
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
