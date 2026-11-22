#if canImport(AVFoundation) && os(macOS)
import AudioToolbox
import AVFoundation
import Foundation
import Synchronization

/// Plays the reference tones (web/js/tone.js): its own AVAudioEngine, so the
/// tone works with the microphone off, and an AVAudioSourceNode that renders
/// a ``ToneSynth`` at the output's sample rate.
///
/// The app gates readings with ``audibleUntil``: while a tone sounds and for
/// ``ReferenceGate/margin`` after, the microphone hears it.
///
/// Threads: main actor, except ``audibleUntil`` and
/// ``gatesReadings(now:)``, which any thread may read (the analysis queue,
/// say), and the render block on the audio thread. Commands reach the
/// render block through a lock-free ``SPSCQueue``; the block drains it and
/// renders, without allocating or locking. The engine starts with the first
/// tone and is rebuilt when the output device changes.
@MainActor
public final class TonePlayer {
    /// What the render block touches: made on the main actor, then used only
    /// by the render thread (the synth) or by both ends of the queue.
    private final class RenderState: @unchecked Sendable {
        let synth: ToneSynth
        let commands = SPSCQueue<ToneSynth.Command>(capacity: 64)
        init(sampleRate: Double) { synth = ToneSynth(sampleRate: sampleRate) }
    }

    /// The steady clock ``audibleUntil`` is in: s since boot.
    public nonisolated static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    public private(set) var isSineOn = false
    private var sineHz = 0.0
    private var pluckUntil = 0.0
    private var releaseUntil = 0.0
    private let until = Atomic<UInt64>(0)

    private var engine: AVAudioEngine?
    private var state: RenderState?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// Until when (``now()``) a tone is audible: ∞ while the sine is on.
    public nonisolated var audibleUntil: Double {
        Double(bitPattern: until.load(ordering: .acquiring))
    }

    /// Whether readings at `now` must be ignored: the tone or its last
    /// 800 ms may be in the analysis buffer.
    public nonisolated func gatesReadings(now: Double = TonePlayer.now()) -> Bool {
        ReferenceGate.isShut(audibleUntil: audibleUntil, now: now)
    }

    /// A pluck of the key whose partial 1 is `f1` Hz with inharmonicity `b`.
    /// Returns how long it is audible in s (tone.js returns ms).
    @discardableResult
    public func pluck(f1: Double, b: Double) -> Double {
        guard let state = running() else { return 0 }
        let seconds = ToneSynth.pluckSeconds(f1: f1, b: b, sampleRate: state.synth.sampleRate)
        guard seconds > 0, state.commands.push(.pluck(f1: f1, b: b)) else { return 0 }
        pluckUntil = max(pluckUntil, Self.now() + seconds)
        publish()
        return seconds
    }

    /// The sustained sine at `hz`; if it is on, a new frequency.
    public func startSine(_ hz: Double) {
        if isSineOn { return setSine(hz) }
        guard let state = running(), state.commands.push(.startSine(hz)) else { return }
        isSineOn = true
        sineHz = hz
        publish()
    }

    /// A new frequency for the sine, approached with τ = 10 ms.
    public func setSine(_ hz: Double) {
        guard isSineOn, let state, state.commands.push(.setSine(hz)) else { return }
        sineHz = hz
    }

    public func stopSine() {
        guard isSineOn else { return }
        isSineOn = false
        state?.commands.push(.stopSine)
        releaseUntil = Self.now() + ToneSynth.sineRelease
        publish()
    }

    /// Stops the engine. The next tone starts it again.
    public func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        state = nil
        if isSineOn {
            isSineOn = false
            releaseUntil = Self.now()
        }
        publish()
    }

    private func publish() {
        let t = isSineOn ? Double.infinity : max(pluckUntil, releaseUntil)
        until.store(t.bitPattern, ordering: .releasing)
    }

    // MARK: Engine

    private func running() -> RenderState? {
        if let state, engine?.isRunning == true { return state }
        shutdown()
        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1)
        else { return nil }
        let state = RenderState(sampleRate: output.sampleRate)
        let source = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(state))
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return nil
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        self.engine = engine
        self.state = state
        return state
    }

    /// The output device or its format changed and the engine stopped:
    /// build it again at the new rate, and keep the sine going if it was on.
    /// Plucks in progress are cut off.
    private func configurationChanged() {
        let sine = isSineOn ? sineHz : nil
        shutdown()
        if let sine { startSine(sine) }
    }

    // MARK: Audio thread

    private nonisolated static func renderBlock(_ state: RenderState) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, bufferList in
            while let command = state.commands.pop() { state.synth.apply(command) }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count > 0, let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = min(Int(frameCount), Int(buffers[0].mDataByteSize) / 4)
            let audible = state.synth.render(into: UnsafeMutableBufferPointer(start: first, count: count))
            for i in 1..<max(1, buffers.count) {
                buffers[i].mData?.copyMemory(from: first, byteCount: count * 4)
            }
            if !audible { isSilence.pointee = true }
            return noErr
        }
    }
}
#endif
