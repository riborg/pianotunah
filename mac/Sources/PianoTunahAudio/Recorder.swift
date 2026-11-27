import Foundation
import Synchronization

/// Records the unprocessed input, at most ``WAVWriter/maxSeconds``, for a
/// WAV file (web/js/recorder.js and `Mic.startRecording`).
///
/// Threads: the control side (``start(sampleRate:maxSeconds:)``,
/// ``close()``, ``stop()``) runs on one thread at a time, the main actor in
/// the app. ``append(_:count:stride:)`` runs on the audio thread, from the
/// same callback that fills the ``RingBuffer``; it neither allocates nor
/// blocks, and does nothing unless a recording is open. The buffer for the
/// whole recording is allocated and zeroed in `start` (46 MB at 96 kHz),
/// so the audio thread only copies, into pages already mapped.
/// ``isRecording``, ``recordedSeconds`` and ``isFull`` may be read from any
/// thread.
///
/// A small state machine hands the buffer between the two sides: the audio
/// thread claims it (open → writing) for one copy and gives it back; the
/// control side closes it only while it is not claimed, waiting out a copy
/// in progress, so it never frees or reads a buffer being written.
public final class Recorder: @unchecked Sendable {
    private enum State: Int {
        case idle, open, writing, closed
    }

    private let state = Atomic<Int>(State.idle.rawValue)
    private let count = Atomic<Int>(0)
    // Set by the control side only while the state is idle or closed, and
    // published to the audio thread by the store of `open`. Atomics rather
    // than plain properties, so the audio thread does no exclusivity checks
    // and the getters may read them from any thread.
    private let buffer = Atomic<UnsafeMutablePointer<Float>?>(nil)
    private let limitSamples = Atomic<Int>(0)
    private let rateBits = Atomic<UInt64>(0)

    private var limit: Int { limitSamples.load(ordering: .relaxed) }
    /// The sample rate of the recording, 0 before the first.
    public var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }

    public init() {}

    deinit {
        buffer.load(ordering: .relaxed)?.deallocate()
    }

    /// A recording is open or closed but not yet taken with ``stop()``.
    public var isRecording: Bool {
        state.load(ordering: .acquiring) != State.idle.rawValue
    }

    /// The length of the recording so far, in s.
    public var recordedSeconds: Double {
        let rate = sampleRate
        return rate > 0 ? Double(count.load(ordering: .acquiring)) / rate : 0
    }

    /// The recording has reached its limit or was closed; it takes no more
    /// samples. The app polls this (as app.js does every 250 ms) and calls
    /// ``stop()``.
    public var isFull: Bool {
        let s = state.load(ordering: .acquiring)
        return s == State.closed.rawValue || (s != State.idle.rawValue && count.load(ordering: .acquiring) >= limit)
    }

    // MARK: Control side

    /// Opens a recording at `sampleRate`. Returns false if one is open.
    @discardableResult
    public func start(sampleRate: Double, maxSeconds: Double = WAVWriter.maxSeconds) -> Bool {
        guard state.load(ordering: .acquiring) == State.idle.rawValue, sampleRate > 0 else { return false }
        buffer.load(ordering: .relaxed)?.deallocate()
        let n = max(1, WAVWriter.maxSamples(sampleRate: sampleRate, maxSeconds: maxSeconds))
        limitSamples.store(n, ordering: .relaxed)
        // Zeroed here, so its pages are mapped before the audio thread
        // writes to them. Otherwise that thread takes a page fault on each
        // new page (16 kB, 4096 samples, on Apple silicon), and a callback
        // that runs late drops samples from the recording. This reduces the
        // faults, not rules them out: under memory pressure macOS can still
        // compress pages not yet written (mlock would pin them, at 46 MB of
        // wired memory). The zeroing, some 10–30 ms on the main actor in
        // the app, comes once as the recording starts.
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: n)
        samples.initialize(repeating: 0, count: n)
        buffer.store(samples, ordering: .relaxed)
        rateBits.store(sampleRate.bitPattern, ordering: .relaxed)
        count.store(0, ordering: .relaxed)
        state.store(State.open.rawValue, ordering: .releasing)
        return true
    }

    /// Takes no more samples, keeping what is recorded: for a restart of the
    /// input at another sample rate, which would not fit this file.
    public func close() {
        while true {
            let (done, s) = state.compareExchange(
                expected: State.open.rawValue, desired: State.closed.rawValue, ordering: .acquiringAndReleasing
            )
            if done || s != State.writing.rawValue { return }
            Thread.sleep(forTimeInterval: 0.0002) // the audio thread is copying; a few µs
        }
    }

    /// Ends the recording and returns it as a WAV file, or nil if there is
    /// none.
    public func stop() -> Data? {
        close()
        guard state.load(ordering: .acquiring) == State.closed.rawValue,
              let samples = buffer.load(ordering: .relaxed) else { return nil }
        let n = min(count.load(ordering: .acquiring), limit)
        let wav = WAVWriter.wav(UnsafeBufferPointer(start: samples, count: n), sampleRate: sampleRate)
        samples.deallocate()
        buffer.store(nil, ordering: .relaxed)
        count.store(0, ordering: .relaxed)
        state.store(State.idle.rawValue, ordering: .releasing)
        return wav
    }

    // MARK: Audio thread

    /// Appends `count` samples read every `stride` floats. Audio thread only.
    public func append(_ samples: UnsafePointer<Float>, count n: Int, stride: Int = 1) {
        guard n > 0, state.compareExchange(
            expected: State.open.rawValue, desired: State.writing.rawValue, ordering: .acquiring
        ).exchanged else { return }
        if let buffer = buffer.load(ordering: .relaxed) {
            let have = count.load(ordering: .relaxed)
            let take = min(n, limit - have)
            if take > 0 {
                if stride == 1 {
                    (buffer + have).update(from: samples, count: take)
                } else {
                    for i in 0..<take { buffer[have + i] = samples[i * stride] }
                }
                count.store(have + take, ordering: .releasing)
            }
        }
        state.store(State.open.rawValue, ordering: .releasing)
    }
}
