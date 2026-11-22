import PianoTunahCore

/// When the next analysis frame is due, counted in samples of the audio
/// clock rather than by a timer: every 90 ms of sound (4320 samples at
/// 48 kHz) there is one frame, however late the analysis queue looks. The
/// web version calls `engine.frame` from `setInterval(…, FRAME_MS)`.
///
/// A value type, owned by whoever drives the frames (``Analysis``, on its
/// queue).
public struct FrameClock: Sendable, Equatable {
    /// Samples per second of the input.
    public let sampleRate: Double
    /// Samples between frames: 90 ms worth, rounded.
    public let interval: Int
    /// The audio clock in s at sample 0, so that time goes on across a
    /// restart of the input.
    public let startTime: Double
    /// The sample count at which the next frame is due.
    public private(set) var next: Int

    public init(sampleRate: Double, frameMs: Double = Engine.frameMs, startTime: Double = 0) {
        precondition(sampleRate > 0 && frameMs > 0, "FrameClock needs a sample rate and an interval")
        self.sampleRate = sampleRate
        interval = max(1, Int((sampleRate * frameMs / 1000).rounded()))
        self.startTime = startTime
        next = interval
    }

    /// Whether a frame is due now that `written` samples have arrived. When
    /// it is, the next one is due on the next point of the grid after
    /// `written`: frames that were missed (the queue was busy) are dropped,
    /// not caught up on, as `setInterval` drops them.
    public mutating func frameDue(written: Int) -> Bool {
        guard written >= next else { return false }
        next += interval * ((written - next) / interval + 1)
        return true
    }

    /// The audio clock in s at sample count `sample`: for a buffer that ends
    /// there, the frame's `time`.
    public func time(atSample sample: Int) -> Double {
        startTime + Double(sample) / sampleRate
    }
}
