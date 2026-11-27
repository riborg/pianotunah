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

  // Audio clock (s); read() returns the samples up to about now.
  get time() {
    return this.ctx.currentTime;
  }

  // Name of the input in use, e.g. "MacBook Pro Microphone".
  get label() {
    return this.stream?.getAudioTracks()[0]?.label || '';
  }

  // The deviceId of the input in use, '' where the browser does not say.
  get deviceId() {
    return this.stream?.getAudioTracks()[0]?.getSettings?.().deviceId || '';
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

// Whether the input in use is no longer the one to use, now that the inputs
// changed (as AudioSession.isStale in the Mac app): it was unplugged, the
// chosen one is back after a fallback to the default, or the default moved
// while it is in use. used: Mic.deviceId. chosen: the chosen deviceId, ''
// for the default. defaultGroup: defaultGroup(devices) when the input
// started. devices: enumerateDevices(), all kinds.
//
// As in the Mac app, a default that moves after a fallback is not followed
// (the chosen input is what the user wants); its return is.
export function inputIsStale(used, { chosen, usedFallback, defaultGroup: atStart, devices }) {
  if (!used) return false;
  const inputs = devices.filter((d) => d.kind === 'audioinput');
  if (!inputs.some((d) => d.deviceId === used)) return true;
  if (chosen) return usedFallback && inputs.some((d) => d.deviceId === chosen);
  const now = defaultGroup(devices);
  return !!(atStart && now && now !== atStart);
}

// The groupId of the device behind the default input, '' if the browser
// does not show it: only Chrome lists the default as an entry of its own,
// so elsewhere a moved default is not seen. Compared with itself over time,
// not with the track's groupId, which need not match it.
export function defaultGroup(devices) {
  return devices.find((d) => d.kind === 'audioinput' && d.deviceId === 'default')?.groupId || '';
}

// The automatic restarts of the microphone: at most max in windowMs (as the
// Mac app's RestartPolicy), so an input whose start changes the devices
// again, such as a Bluetooth headset switching profiles, cannot loop.
export class RestartBudget {
  constructor(max = 3, windowMs = 10000) {
    this.max = max;
    this.windowMs = windowMs;
    this.times = [];
  }

  // True, and counted, if a restart at now (ms) is within the budget.
  take(now) {
    this.times = this.times.filter((t) => now - t < this.windowMs);
    if (this.times.length >= this.max) return false;
    this.times.push(now);
    return true;
  }

  // The user started the microphone: a fresh budget.
  reset() {
    this.times = [];
  }
}
