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
/// say), and the render block on the audio thread. The render block owns a
/// ``ToneControl``: plucks reach it through a lock-free queue, the sine's
/// on/off and frequency through an atomic it reads every block, so a stop
/// is never lost. It renders without allocating or locking. The engine
/// starts with the first tone, is rebuilt when the output device changes,
/// and stops ``idleSeconds`` after the last tone fell silent: an output
/// that runs, even silent, keeps Core Audio from letting the Mac idle-sleep
/// (`kAudioHardwarePropertySleepingIsAllowed` is off by default). While the
/// sine is on, the engine is checked every ``sineCheckSeconds``: one that
/// stopped without a configuration change is built again.
@MainActor
public final class TonePlayer {
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
    private var state: ToneControl?
    private var observer: (any NSObjectProtocol)?
    private var idleStop: Task<Void, Never>?
    private var sineWatch: Task<Void, Never>?

    /// How long the engine keeps running after the last tone, in s: long
    /// enough that tuning, with a tone every few seconds, never waits for
    /// it to start (a Bluetooth output can take a moment to wake).
    public let idleSeconds: Double
    /// How often the engine is checked while the sine is on, in s.
    public let sineCheckSeconds: Double

    public init(idleSeconds: Double = 60, sineCheckSeconds: Double = 1) {
        self.idleSeconds = idleSeconds
        self.sineCheckSeconds = sineCheckSeconds
    }

    /// The engine is running; for tests.
    var isEngineRunning: Bool { engine?.isRunning == true }

    /// Stops the engine as the system might, with no configuration change
    /// and the sine left on; for tests.
    func stopEngineSilently() { engine?.stop() }

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
        guard seconds > 0, state.pluck(f1: f1, b: b) else { return 0 }
        pluckUntil = max(pluckUntil, Self.now() + seconds)
        publish()
        return seconds
    }

    /// The sustained sine at `hz`; if it is on, a new frequency. Ignored
    /// unless `hz` is positive and finite.
    public func startSine(_ hz: Double) {
        guard hz > 0, hz.isFinite else { return }
        if isSineOn { return setSine(hz) }
        guard let state = running() else { return }
        state.setSine(hz)
        isSineOn = true
        sineHz = hz
        watchSine()
        publish()
    }

    /// A new frequency for the sine, approached with τ = 10 ms.
    public func setSine(_ hz: Double) {
        guard isSineOn, hz > 0, hz.isFinite, let state else { return }
        state.setSine(hz)
        sineHz = hz
    }

    public func stopSine() {
        guard isSineOn else { return }
        isSineOn = false
        sineWatch?.cancel()
        sineWatch = nil
        state?.setSine(nil) // cannot fail, unlike a queued command
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
        sineWatch?.cancel()
        sineWatch = nil
        if isSineOn {
            isSineOn = false
            releaseUntil = Self.now()
        }
        publish()
    }

    private func publish() {
        let t = isSineOn ? Double.infinity : max(pluckUntil, releaseUntil)
        until.store(t.bitPattern, ordering: .releasing)
        scheduleIdleStop(after: t)
    }

    /// Stops the engine ``idleSeconds`` after `silentFrom`, unless a tone
    /// comes first (every tone publishes and so moves this). Nothing while
    /// the sine is on or no engine runs.
    private func scheduleIdleStop(after silentFrom: Double) {
        idleStop?.cancel()
        idleStop = nil
        guard engine != nil, silentFrom.isFinite else { return }
        let due = silentFrom + idleSeconds
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due - Self.now())))
            guard !Task.isCancelled, let self, !self.isSineOn else { return }
            self.idleStop = nil
            self.shutdown()
        }
    }

    /// While the sine is on: an engine that stopped with no configuration
    /// change (around sleep and wake, say) would leave ``isSineOn`` true
    /// and the readings gated until ▶ is pressed again, with nothing
    /// sounding. Built again as for a configuration change; if that fails,
    /// the sine is off.
    private func watchSine() {
        sineWatch?.cancel()
        let interval = sineCheckSeconds
        sineWatch = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.isSineOn else { return }
                if !self.isEngineRunning { return self.configurationChanged() }
            }
        }
    }

    // MARK: Engine

    private func running() -> ToneControl? {
        if let state, engine?.isRunning == true { return state }
        shutdown()
        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1)
        else { return nil }
        let state = ToneControl(sampleRate: output.sampleRate)
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
        // Stopped when idle even if the tone that started it never plays.
        scheduleIdleStop(after: Self.now())
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

    private nonisolated static func renderBlock(_ state: ToneControl) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count > 0, let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = min(Int(frameCount), Int(buffers[0].mDataByteSize) / 4)
            let audible = state.render(into: UnsafeMutableBufferPointer(start: first, count: count))
            for i in 1..<max(1, buffers.count) {
                buffers[i].mData?.copyMemory(from: first, byteCount: count * 4)
            }
            if !audible { isSilence.pointee = true }
            return noErr
        }
    }
}
#endif
