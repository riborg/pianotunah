// AudioWorklet for recording: passes the microphone's samples on in blocks of
// 4096 (the processor gets 128 at a time). 'stop' ends it.

class Recorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(4096);
    this.n = 0;
    this.done = false;
    this.port.onmessage = () => (this.done = true);
  }

  process([input]) {
    const ch = input[0];
    if (ch) {
      for (let i = 0; i < ch.length; i++) {
        this.buf[this.n++] = ch[i];
        if (this.n === this.buf.length) {
          this.port.postMessage(this.buf, [this.buf.buffer]);
          this.buf = new Float32Array(4096);
          this.n = 0;
        }
      }
    }
    return !this.done;
  }
}

registerProcessor('recorder', Recorder);
