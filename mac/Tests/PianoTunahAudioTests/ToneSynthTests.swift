import Foundation
import PianoTunahCore
import Testing
@testable import PianoTunahAudio

private func render(_ synth: ToneSynth, seconds: Double) -> [Float] {
    var out = [Float](repeating: 0, count: Int((seconds * synth.sampleRate).rounded()))
    // In blocks, as the render callback asks for them.
    out.withUnsafeMutableBufferPointer { buf in
        var at = 0
        while at < buf.count {
            let n = min(512, buf.count - at)
            synth.render(into: UnsafeMutableBufferPointer(rebasing: buf[at..<(at + n)]))
            at += n
        }
    }
    return out
}

/// The amplitude of a sine (or of the whole signal, for one partial) around
/// `t` s: the RMS over 2 ms × √2.
private func amplitude(_ s: [Float], at t: Double, rate: Double) -> Double {
    let c = Int(t * rate), h = Int(0.001 * rate)
    let w = s[max(0, c - h)..<min(s.count, c + h)]
    return (w.reduce(0) { $0 + Double($1) * Double($1) } / Double(w.count)).squareRoot() * 2.0.squareRoot()
}

/// A partial's amplitude at `hz` around `t` s, from a Hann-windowed DFT
/// over `window` s.
private func partialAmplitude(_ s: [Float], hz: Double, at t: Double, rate: Double, window: Double = 0.02) -> Double {
    let n = Int(window * rate), start = Int(t * rate) - n / 2
    var re = 0.0, im = 0.0, wsum = 0.0
    for i in 0..<n {
        let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
        let x = Double(s[start + i]) * w
        let ph = 2 * Double.pi * hz * Double(start + i) / rate
        re += x * cos(ph)
        im -= x * sin(ph)
        wsum += w
    }
    return 2 * (re * re + im * im).squareRoot() / wsum
}

/// What tone.js's gain ramps give partial n at `t` s after the pluck.
private func expectedPartial(_ n: Int, at t: Double) -> Double {
    let a = ToneSynth.pluckAmplitude(n), d = ToneSynth.pluckDecay(n), floor = ToneSynth.pluckFloor
    let g = t < 0.008 ? floor * pow(a / floor, t / 0.008) : a * pow(floor / a, (t - 0.008) / (d - 0.008))
    return ToneSynth.pluckGain * g
}

@Test func pluckPartialsAndLength() {
    #expect(ToneSynth.pluckAmplitude(1) == 1)
    #expect(abs(ToneSynth.pluckAmplitude(2) - pow(2, -1.1)) < 1e-15)
    #expect(ToneSynth.pluckDecay(1) == 2.95)
    #expect(abs(ToneSynth.pluckDecay(10) - 0.7) < 1e-12)
    #expect(ToneSynth.pluckDecay(12) == 0.4)
    #expect(ToneSynth.pluckPartialCount(f1: 440, b: 0.0004, sampleRate: 48000) == 10)
    // 0.45 × 96 kHz = 43.2 kHz: 8 × 5000 is in, 9 × 5000 is out.
    #expect(ToneSynth.pluckPartialCount(f1: 5000, b: 0, sampleRate: 96000) == 8)
    #expect(ToneSynth.pluckPartialCount(f1: 30000, b: 0, sampleRate: 48000) == 0)
    // What tone.js's pluck returns, in s.
    #expect(ToneSynth.pluckSeconds(f1: 440, b: 0, sampleRate: 48000) == 2.95)
    #expect(ToneSynth.pluckSeconds(f1: 30000, b: 0, sampleRate: 48000) == 0)
}

@Test func pluckEnvelopeOfOnePartial() {
    // 11 kHz at 48 kHz: partial 2 (22 kHz) is above 0.45 × the rate, so one
    // partial sounds and the signal's amplitude is its envelope.
    let rate = 48000.0
    let synth = ToneSynth(sampleRate: rate)
    synth.apply(.pluck(f1: 11000, b: 0))
    let s = render(synth, seconds: 3.2)
    func close(_ t: Double, _ want: Double, _ tol: Double = 0.06) -> Bool {
        let got = amplitude(s, at: t, rate: rate)
        return abs(got - want) <= tol * want
    }
    #expect(close(0.5, expectedPartial(1, at: 0.5)))
    #expect(close((0.008 + 2.95) / 2, 0.22 * 0.01)) // halfway down
    #expect(close(2.97, 0.22 * 1e-4, 0.1)) // at the floor until 3.0 s
    #expect(s[Int(3.01 * rate)...].allSatisfy { $0 == 0 })
    #expect(synth.isSilent)
    #expect(s.allSatisfy { abs($0) <= 0.2201 })
}

@Test func pluckSpectrumHasTheInharmonicPartials() {
    let rate = 48000.0, f1 = 220.0, b = 0.0004
    let synth = ToneSynth(sampleRate: rate)
    synth.apply(.pluck(f1: f1, b: b))
    let s = render(synth, seconds: 0.3)
    for t in [0.05, 0.2] {
        for n in 1...10 {
            let got = partialAmplitude(s, hz: partialFreq(f1, b, n), at: t, rate: rate)
            let want = expectedPartial(n, at: t)
            #expect(abs(got - want) < 0.05 * want, "partial \(n) at \(t) s: \(got), want \(want)")
        }
    }
    // Not at whole multiples: partial 10 is 2 % sharp of 10 × f1. And
    // nothing between the partials. A 100 ms window, for less leakage.
    #expect(partialAmplitude(s, hz: 10 * f1, at: 0.1, rate: rate, window: 0.1) < 0.1 * expectedPartial(10, at: 0.1))
    #expect(partialAmplitude(s, hz: 1.5 * f1, at: 0.1, rate: rate, window: 0.1) < 1e-3 * expectedPartial(1, at: 0.1))
}

@Test func pluckAttackIsExponentialOver8ms() {
    let rate = 48000.0
    let synth = ToneSynth(sampleRate: rate)
    synth.apply(.pluck(f1: 220, b: 0))
    #expect(synth.pluckEnvelope(voice: 0, partial: 3) == 1e-4)
    _ = render(synth, seconds: 0.004) // halfway: the geometric mean
    for n in 1...10 {
        let want = (1e-4 * ToneSynth.pluckAmplitude(n)).squareRoot()
        #expect(abs(synth.pluckEnvelope(voice: 0, partial: n) - want) < 1e-9 * want)
    }
    _ = render(synth, seconds: 0.004) // the peak
    for n in 1...10 {
        #expect(abs(synth.pluckEnvelope(voice: 0, partial: n) - ToneSynth.pluckAmplitude(n)) < 1e-12)
    }
    _ = render(synth, seconds: 0.5 - 0.008)
    for n in 1...10 {
        let want = expectedPartial(n, at: 0.5) / ToneSynth.pluckGain
        #expect(abs(synth.pluckEnvelope(voice: 0, partial: n) - want) < 1e-6 * want, "partial \(n)")
    }
}

@Test func pluckLeavesOutPartialsAboveTheLimit() {
    let rate = 96000.0
    let synth = ToneSynth(sampleRate: rate)
    synth.apply(.pluck(f1: 5000, b: 0))
    let s = render(synth, seconds: 0.1)
    #expect(partialAmplitude(s, hz: 40000, at: 0.05, rate: rate) > 0.5 * expectedPartial(8, at: 0.05))
    #expect(partialAmplitude(s, hz: 45000, at: 0.05, rate: rate) < 1e-6)
}

@Test func plucksOverlapAndTheOldestIsReplaced() {
    let synth = ToneSynth(sampleRate: 48000)
    synth.apply(.pluck(f1: 11000, b: 0))
    _ = render(synth, seconds: 0.5)
    synth.apply(.pluck(f1: 11000, b: 0))
    // Two at once: the new one's peak on top of the first's decay.
    let two = render(synth, seconds: 0.02)
    #expect(amplitude(two, at: 0.008, rate: 48000) > 0.22)
    for _ in 0..<ToneSynth.pluckVoices + 2 { synth.apply(.pluck(f1: 220, b: 0)) }
    let many = render(synth, seconds: 0.5)
    #expect(many.allSatisfy { $0.isFinite })
    #expect(!synth.isSilent)
}

@Test func sineRampsInGlidesAndReleases() throws {
    let rate = 48000.0
    let synth = ToneSynth(sampleRate: rate)
    #expect(!synth.sineOn)
    synth.apply(.setSine(500)) // no sine: nothing
    #expect(synth.isSilent)
    synth.apply(.startSine(1000))
    #expect(synth.sineOn)
    let on = render(synth, seconds: 0.1)
    #expect(abs(amplitude(on, at: 0.02, rate: rate) - 0.09) < 0.005) // linear, halfway
    #expect(abs(amplitude(on, at: 0.07, rate: rate) - 0.18) < 0.002)
    #expect(on.allSatisfy { abs($0) <= 0.18 + 1e-6 })
    #expect(synth.sineHz == 1000)

    // setTargetAtTime with τ = 10 ms: 63 % of the way after 10 ms.
    synth.apply(.setSine(2000))
    _ = render(synth, seconds: 0.01)
    let hz = try #require(synth.sineHz)
    #expect(abs(hz - (2000 - 1000 * exp(-1.0))) < 1)
    synth.apply(.startSine(1500)) // already on: a new frequency
    _ = render(synth, seconds: 0.2)
    #expect(abs(try #require(synth.sineHz) - 1500) < 0.01)

    synth.apply(.stopSine)
    #expect(!synth.sineOn)
    let off = render(synth, seconds: 0.1)
    #expect(abs(amplitude(off, at: 0.03, rate: rate) - 0.09) < 0.006)
    #expect(off[Int(0.061 * rate)...].allSatisfy { $0 == 0 })
    #expect(synth.isSilent)
}

@Test func sineStartedWhileTheLastFadesOut() {
    let synth = ToneSynth(sampleRate: 48000)
    synth.apply(.startSine(500))
    _ = render(synth, seconds: 0.1)
    synth.apply(.stopSine)
    _ = render(synth, seconds: 0.02)
    synth.apply(.startSine(1500))
    let s = render(synth, seconds: 0.2)
    #expect(synth.sineOn && synth.sineHz == 1500)
    #expect(abs(amplitude(s, at: 0.15, rate: 48000) - 0.18) < 0.003)
}

@Test func silenceIsZerosAndSaysSo() {
    let synth = ToneSynth(sampleRate: 44100)
    var buf = [Float](repeating: 1, count: 256)
    let audible = buf.withUnsafeMutableBufferPointer { synth.render(into: $0) }
    #expect(!audible)
    #expect(buf.allSatisfy { $0 == 0 })
}
