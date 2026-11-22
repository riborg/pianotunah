import Foundation
import PianoTunahCore

/// The reference tones, as web/js/tone.js makes them with Web Audio
/// oscillators and gain ramps, rendered sample by sample.
///
/// - Pluck: a short piano-like tone of ten inharmonic partials
///   (``partialFreq(_:_:_:)`` with the key's B). Partial n has the amplitude
///   1/n^1.1, rises exponentially from 0.0001 in 8 ms, falls exponentially
///   back to 0.0001 at max(0.4, 3.2 − 0.25n) s and stops 50 ms later. Partials
///   above 0.45 × the sample rate are left out. All of it at the gain 0.22.
///   Plucks overlap, up to ``pluckVoices`` at once; a further one replaces
///   the oldest.
/// - Sine: a pure sustained tone at the gain 0.18, ramped in linearly over
///   40 ms. A new frequency is approached with a time constant of 10 ms
///   (`setTargetAtTime`), and stopping ramps it out over 60 ms.
///
/// Threads: not thread-safe. One thread owns it: the render callback, fed
/// ``Command``s through an ``SPSCQueue``. ``apply(_:)`` and
/// ``render(into:)`` neither allocate nor lock; all state lives in buffers
/// allocated in `init`.
public final class ToneSynth {
    public enum Command: Sendable, BitwiseCopyable, Equatable {
        /// A pluck of the key whose partial 1 is `f1` Hz with inharmonicity `b`.
        case pluck(f1: Double, b: Double)
        /// The sine at `hz`; if it is already on, the same as ``setSine(_:)``.
        case startSine(Double)
        /// A new frequency for the sine, if it is on.
        case setSine(Double)
        case stopSine
    }

    public static let partials = 10
    public static let pluckGain = 0.22
    public static let pluckFloor = 0.0001
    public static let pluckAttack = 0.008
    /// How long a partial goes on at the floor after its decay (osc.stop).
    public static let pluckTail = 0.05
    public static let pluckVoices = 4
    public static let sineGain = 0.18
    public static let sineRamp = 0.04
    public static let sineGlide = 0.01
    public static let sineRelease = 0.06

    /// Partial n's peak amplitude, before the gain 0.22.
    public static func pluckAmplitude(_ n: Int) -> Double {
        1 / pow(Double(n), 1.1)
    }

    /// Partial n's decay: when it is back at 0.0001, in s from the pluck.
    public static func pluckDecay(_ n: Int) -> Double {
        max(0.4, 3.2 - Double(n) * 0.25)
    }

    /// The partials a pluck plays: those up to the first above 0.45 × the
    /// sample rate (tone.js stops there).
    public static func pluckPartialCount(f1: Double, b: Double, sampleRate: Double) -> Int {
        var count = 0
        for n in 1...partials {
            if partialFreq(f1, b, n) > sampleRate * 0.45 { break }
            count = n
        }
        return count
    }

    /// How long a pluck is audible in s: its longest decay, as
    /// `TonePlayer.pluck` returns it in ms. 0 when no partial is played.
    public static func pluckSeconds(f1: Double, b: Double, sampleRate: Double) -> Double {
        var longest = 0.0
        for n in stride(from: 1, through: pluckPartialCount(f1: f1, b: b, sampleRate: sampleRate), by: 1) {
            longest = max(longest, pluckDecay(n))
        }
        return longest
    }

    // MARK: State

    private enum Stage: UInt8 { case off, attack, decay, hold }

    private struct Partial {
        var stage = Stage.off
        var phase = 0.0
        var step = 0.0 // phase per sample
        var gain = 0.0
        var factor = 1.0 // gain per sample in this stage
        var left = 0 // samples to the end of this stage
        var peak = 0.0
        var decayFactor = 1.0
        var decaySamples = 0
    }

    private struct Sine {
        enum Stage: UInt8 { case off, ramp, hold, release }
        var stage = Stage.off
        var phase = 0.0
        var hz = 0.0
        var target = 0.0
        var gain = 0.0
        var gainStep = 0.0
        var left = 0
    }

    public let sampleRate: Double
    private let partialState: UnsafeMutablePointer<Partial>
    private let voiceAge: UnsafeMutablePointer<Int> // pluck serial per voice, 0 = never used
    private let sines: UnsafeMutablePointer<Sine> // two: one sounding, one fading out
    private let sineCount = 2
    private let state: UnsafeMutablePointer<(plucks: Int, active: Int)> // serial counter, sounding sine (−1: none)
    private let glide: Double // per-sample share of the way to the target frequency
    private let twoPi = 2 * Double.pi

    public init(sampleRate: Double) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        partialState = .allocate(capacity: Self.pluckVoices * Self.partials)
        partialState.initialize(repeating: Partial(), count: Self.pluckVoices * Self.partials)
        voiceAge = .allocate(capacity: Self.pluckVoices)
        voiceAge.initialize(repeating: 0, count: Self.pluckVoices)
        sines = .allocate(capacity: sineCount)
        sines.initialize(repeating: Sine(), count: sineCount)
        state = .allocate(capacity: 1)
        state.initialize(to: (0, -1))
        glide = 1 - exp(-1 / (Self.sineGlide * sampleRate))
    }

    deinit {
        partialState.deallocate()
        voiceAge.deallocate()
        sines.deallocate()
        state.deallocate()
    }

    private func samples(_ seconds: Double) -> Int {
        max(1, Int((seconds * sampleRate).rounded()))
    }

    // MARK: Commands

    public func apply(_ command: Command) {
        switch command {
        case let .pluck(f1, b): pluck(f1: f1, b: b)
        case let .startSine(hz): startSine(hz)
        case let .setSine(hz): if state.pointee.active >= 0 { sines[state.pointee.active].target = hz }
        case .stopSine: stopSine()
        }
    }

    private func pluck(f1: Double, b: Double) {
        let count = Self.pluckPartialCount(f1: f1, b: b, sampleRate: sampleRate)
        guard count > 0 else { return }
        // A free voice, or else the oldest.
        var voice = 0
        for v in 0..<Self.pluckVoices {
            if !voiceSounds(v) { voice = v; break }
            if voiceAge[v] < voiceAge[voice] { voice = v }
        }
        state.pointee.plucks += 1
        voiceAge[voice] = state.pointee.plucks
        let base = partialState + voice * Self.partials
        let attack = samples(Self.pluckAttack)
        for i in 0..<Self.partials {
            let n = i + 1
            guard n <= count else { base[i] = Partial(); continue }
            let peak = Self.pluckAmplitude(n)
            let decay = max(1, samples(Self.pluckDecay(n)) - attack)
            base[i] = Partial(
                stage: .attack, phase: 0, step: twoPi * partialFreq(f1, b, n) / sampleRate,
                gain: Self.pluckFloor, factor: pow(peak / Self.pluckFloor, 1 / Double(attack)), left: attack,
                peak: peak, decayFactor: pow(Self.pluckFloor / peak, 1 / Double(decay)), decaySamples: decay
            )
        }
    }

    private func voiceSounds(_ v: Int) -> Bool {
        let base = partialState + v * Self.partials
        for i in 0..<Self.partials where base[i].stage != .off { return true }
        return false
    }

    private func startSine(_ hz: Double) {
        if state.pointee.active >= 0 {
            sines[state.pointee.active].target = hz
            return
        }
        // A silent slot, or else the quieter one fading out.
        var slot = 0
        for s in 0..<sineCount {
            if sines[s].stage == .off { slot = s; break }
            if sines[s].gain < sines[slot].gain { slot = s }
        }
        let ramp = samples(Self.sineRamp)
        let from = sines[slot].stage == .off ? 0 : sines[slot].gain
        sines[slot] = Sine(
            stage: .ramp, phase: sines[slot].stage == .off ? 0 : sines[slot].phase, hz: hz, target: hz,
            gain: from, gainStep: (Self.sineGain - from) / Double(ramp), left: ramp
        )
        state.pointee.active = slot
    }

    private func stopSine() {
        let slot = state.pointee.active
        guard slot >= 0 else { return }
        state.pointee.active = -1
        let release = samples(Self.sineRelease)
        sines[slot].stage = .release
        sines[slot].gainStep = -sines[slot].gain / Double(release)
        sines[slot].left = release
    }

    // MARK: Rendering

    /// Whether the sine is on (not counting its fade-out).
    public var sineOn: Bool { state.pointee.active >= 0 }

    /// Whether nothing sounds: every partial and both sines are off.
    public var isSilent: Bool {
        for v in 0..<Self.pluckVoices where voiceSounds(v) { return false }
        for s in 0..<sineCount where sines[s].stage != .off { return false }
        return true
    }

    /// Partial n's envelope (before the gain 0.22) in pluck voice `voice`.
    func pluckEnvelope(voice: Int, partial n: Int) -> Double {
        partialState[voice * Self.partials + n - 1].gain
    }

    /// The sounding sine's current frequency, or nil.
    var sineHz: Double? { state.pointee.active >= 0 ? sines[state.pointee.active].hz : nil }

    /// Writes the next `out.count` samples into `out` (replacing what is
    /// there). Returns false if they are all silence.
    @discardableResult
    public func render(into out: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard let dst = out.baseAddress, !out.isEmpty else { return false }
        if isSilent {
            dst.update(repeating: 0, count: out.count)
            return false
        }
        for j in 0..<out.count {
            var pluckSum = 0.0
            for p in 0..<(Self.pluckVoices * Self.partials) where partialState[p].stage != .off {
                pluckSum += partialState[p].gain * sin(partialState[p].phase)
                advance(partialState + p)
            }
            var sineSum = 0.0
            for s in 0..<sineCount where sines[s].stage != .off {
                sineSum += sines[s].gain * sin(sines[s].phase)
                advance(sines + s)
            }
            dst[j] = Float(Self.pluckGain * pluckSum + sineSum)
        }
        return true
    }

    private func advance(_ p: UnsafeMutablePointer<Partial>) {
        p.pointee.phase += p.pointee.step
        if p.pointee.phase >= twoPi { p.pointee.phase -= twoPi }
        p.pointee.gain *= p.pointee.factor
        p.pointee.left -= 1
        guard p.pointee.left <= 0 else { return }
        switch p.pointee.stage {
        case .attack:
            p.pointee.stage = .decay
            p.pointee.gain = p.pointee.peak // no drift from the products
            p.pointee.factor = p.pointee.decayFactor
            p.pointee.left = p.pointee.decaySamples
        case .decay:
            p.pointee.stage = .hold
            p.pointee.gain = Self.pluckFloor
            p.pointee.factor = 1
            p.pointee.left = samples(Self.pluckTail)
        case .hold, .off:
            p.pointee = Partial()
        }
    }

    private func advance(_ s: UnsafeMutablePointer<Sine>) {
        s.pointee.phase += twoPi * s.pointee.hz / sampleRate
        if s.pointee.phase >= twoPi { s.pointee.phase -= twoPi }
        s.pointee.hz += (s.pointee.target - s.pointee.hz) * glide
        switch s.pointee.stage {
        case .ramp, .release:
            s.pointee.gain += s.pointee.gainStep
            s.pointee.left -= 1
            if s.pointee.left <= 0 {
                if s.pointee.stage == .ramp {
                    s.pointee.stage = .hold
                    s.pointee.gain = Self.sineGain
                } else {
                    s.pointee = Sine()
                }
            }
        case .hold, .off:
            break
        }
    }
}
