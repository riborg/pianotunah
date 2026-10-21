// Microphone. AnalyserNode is only used as a ring buffer: read() returns the
// latest 32768 samples (~0.7 s); all analysis happens in dsp.js. Recording
// goes through an AudioWorklet (recorder.js), which sees every sample.

export class Mic {
  ctx = null;
  stream = null;
  analyser = null;
  source = null;
  buf = null;
  rec = null; // { node, chunks } while recording

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
    // Created before the permission prompt, while the click still counts as a
    // user gesture; Safari otherwise starts it suspended and the analyser reads silence.
    const ctx = new AudioContext();
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio });
    } catch (e) {
      ctx.close();
      throw e;
    }
    this.ctx = ctx;
    this.resume();
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 32768;
    this.source = this.ctx.createMediaStreamSource(this.stream);
    this.source.connect(this.analyser);
    this.buf = new Float32Array(this.analyser.fftSize);
  }

  // Audio inputs. Names and ids are empty until the page has had microphone
  // access; Chrome's "default" and "communications" aliases are left out.
  static async inputs() {
    const all = (await navigator.mediaDevices?.enumerateDevices?.()) || [];
    return all.filter((d) => d.kind === 'audioinput' && d.deviceId && !['default', 'communications'].includes(d.deviceId));
  }

  // Safari suspends the context when the screen locks or another app takes the audio.
  resume() {
    this.ctx?.resume().catch(() => {});
  }

  stop() {
    this.stream?.getTracks().forEach((t) => t.stop());
    this.ctx?.close();
    this.ctx = this.stream = this.analyser = this.source = this.rec = null;
  }

  get recording() {
    return !!this.rec;
  }

  get recordedSeconds() {
    return this.rec ? (this.rec.chunks.length * 4096) / this.ctx.sampleRate : 0;
  }

  // Records the unprocessed input until stopRecording().
  async startRecording() {
    if (!this.ctx.recorderLoaded) {
      await this.ctx.audioWorklet.addModule(new URL('./recorder.js', import.meta.url));
      this.ctx.recorderLoaded = true;
    }
    const node = new AudioWorkletNode(this.ctx, 'recorder', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit' });
    const chunks = [];
    node.port.onmessage = (e) => chunks.push(e.data);
    this.source.connect(node);
    // The output is silent; the connection makes sure the node is processed.
    node.connect(this.ctx.destination);
    this.rec = { node, chunks };
  }

  // Ends the recording and returns it as a WAV file.
  stopRecording() {
    const { node, chunks } = this.rec;
    this.rec = null;
    node.port.postMessage('stop');
    node.disconnect();
    this.source.disconnect(node);
    return wavBlob(chunks, this.ctx.sampleRate);
  }

  read() {
    this.analyser.getFloatTimeDomainData(this.buf);
    return this.buf;
  }
}

// Mono 32-bit float WAV from blocks of samples.
export function wavBlob(chunks, sampleRate) {
  const n = chunks.reduce((a, c) => a + c.length, 0);
  const h = new DataView(new ArrayBuffer(44));
  const str = (o, t) => [...t].forEach((c, i) => h.setUint8(o + i, c.charCodeAt(0)));
  str(0, 'RIFF');
  h.setUint32(4, 36 + n * 4, true);
  str(8, 'WAVE');
  str(12, 'fmt ');
  h.setUint32(16, 16, true);
  h.setUint16(20, 3, true); // IEEE float
  h.setUint16(22, 1, true); // mono
  h.setUint32(24, sampleRate, true);
  h.setUint32(28, sampleRate * 4, true);
  h.setUint16(32, 4, true);
  h.setUint16(34, 32, true);
  str(36, 'data');
  h.setUint32(40, n * 4, true);
  return new Blob([h, ...chunks], { type: 'audio/wav' });
}
