import Dispatch
import PianoTunahCore

/// One analysis frame: what `Engine.frame` takes.
public struct AnalysisFrame: Sendable {
    /// The latest ``Engine/bufferSize`` samples, oldest first. Zeros at the
    /// start until that many have arrived, as the web's AnalyserNode gives.
    public var samples: [Float]
    /// The audio clock in s where the samples end. It goes on across
    /// restarts of the input.
    public var time: Double
    public var sampleRate: Double
    /// Counts the starts of the input: when it changes, the sample rate may
    /// have changed and `Engine.startAudio(sampleRate:)` is due.
    public var generation: Int

    public init(samples: [Float], time: Double, sampleRate: Double, generation: Int) {
        self.samples = samples
        self.time = time
        self.sampleRate = sampleRate
        self.generation = generation
    }
}

/// Drives the analysis frames: every 90 ms of samples in a ``RingBuffer``
/// it copies the latest ``Engine/bufferSize`` of them and calls `onFrame`
/// with them, on its own serial queue.
///
/// The frames follow the audio clock (``FrameClock``), not a timer. A timer
/// on the queue only looks every few ms whether the ring has reached the
/// next frame, so the audio thread need not signal anything.
///
/// Threads: ``attach(_:sampleRate:)`` and ``detach()`` may be called from
/// any thread; they hand over to ``queue``. Everything else, `onFrame`
/// included, runs on ``queue``, never on the audio thread. The samples
/// array is reused from frame to frame, so a frame allocates nothing unless
/// `onFrame` keeps the previous one.
public final class Analysis: @unchecked Sendable {
    public let queue: DispatchQueue
    public let frameMs: Double
    public let bufferSize: Int
    private let pollInterval: DispatchTimeInterval
    private let onFrame: @Sendable (AnalysisFrame) -> Void

    // Only on `queue`.
    private var ring: RingBuffer?
    private var clock: FrameClock?
    private var timer: DispatchSourceTimer?
    private var samples: [Float]
    private var generation = 0
    private var lastTime = 0.0

    public init(
        frameMs: Double = Engine.frameMs, bufferSize: Int = Engine.bufferSize,
        pollInterval: DispatchTimeInterval = .milliseconds(5),
        queue: DispatchQueue = DispatchQueue(label: "PianoTunah.analysis", qos: .userInteractive),
        onFrame: @escaping @Sendable (AnalysisFrame) -> Void
    ) {
        self.frameMs = frameMs
        self.bufferSize = bufferSize
        self.pollInterval = pollInterval
        self.queue = queue
        self.onFrame = onFrame
        samples = [Float](repeating: 0, count: bufferSize)
    }

    /// Starts frames from a new ring (a new start of the input) at
    /// `sampleRate`. Its sample 0 is where the previous ring stopped, so the
    /// time goes on.
    public func attach(_ ring: RingBuffer, sampleRate: Double) {
        precondition(ring.capacity >= bufferSize, "the ring must hold a frame's samples")
        queue.async { self.attachOnQueue(ring, sampleRate: sampleRate) }
    }

    /// Stops the frames.
    public func detach() {
        queue.async { self.detachOnQueue() }
    }

    private func attachOnQueue(_ ring: RingBuffer, sampleRate: Double) {
        detachOnQueue()
        self.ring = ring
        clock = FrameClock(sampleRate: sampleRate, frameMs: frameMs, startTime: lastTime)
        generation += 1
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func detachOnQueue() {
        timer?.cancel()
        timer = nil
        if let ring, let clock { lastTime = clock.time(atSample: ring.written) }
        ring = nil
        clock = nil
    }

    /// Delivers a frame if one is due. On ``queue``.
    func pump() {
        guard let ring, var clock, clock.frameDue(written: ring.written) else { return }
        self.clock = clock
        let end = samples.withUnsafeMutableBufferPointer { ring.latest(into: $0) }
        onFrame(AnalysisFrame(
            samples: samples, time: clock.time(atSample: end), sampleRate: clock.sampleRate, generation: generation
        ))
    }
}
