import PianoTunahCore
import Synchronization

/// The microphone's latest samples: a single-producer, single-consumer ring
/// of Float32 without locks.
///
/// Threads: one producer (the audio input's real-time callback) calls
/// ``write(_:count:stride:)``; one consumer (the analysis queue) calls
/// ``latest(count:into:)``. ``written`` may be read from any thread. Neither
/// side allocates or blocks, so the producer is safe on the audio thread.
///
/// The producer publishes how many samples it has written in all with a
/// release store after copying them; that count is also the audio clock,
/// in samples since the ring was made. The consumer copies the newest
/// samples and then checks that the producer did not lap into them while
/// it copied; if it did, it copies again. With the default capacity, twice
/// ``Engine/bufferSize``, the producer would have to write 0.7 s of sound
/// during one copy of a few microseconds.
public final class RingBuffer: @unchecked Sendable {
    /// The number of samples the ring holds, a power of two.
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let total = Atomic<Int>(0)

    /// A ring of at least `minimumCapacity` samples, rounded up to a power of
    /// two and never below ``Engine/bufferSize``.
    public init(minimumCapacity: Int = 2 * Engine.bufferSize) {
        var c = Engine.bufferSize
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit {
        storage.deallocate()
    }

    /// Samples written since the ring was made: the audio clock in samples.
    public var written: Int {
        total.load(ordering: .acquiring)
    }

    // MARK: Producer

    /// Appends `count` samples read every `stride` floats from `samples`
    /// (stride 2 takes the first channel of interleaved stereo). Producer
    /// only; no allocation, no locks.
    public func write(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        guard count > 0 else { return }
        let start = total.load(ordering: .relaxed) // only this thread stores it
        // More than the ring holds: only the newest fit.
        let skip = max(0, count - capacity)
        var src = samples + skip * stride
        var pos = (start + skip) & mask
        var left = count - skip
        if stride == 1 {
            while left > 0 {
                let n = min(left, capacity - pos)
                (storage + pos).update(from: src, count: n)
                src += n
                left -= n
                pos = 0
            }
        } else {
            while left > 0 {
                storage[pos] = src.pointee
                src += stride
                pos = (pos + 1) & mask
                left -= 1
            }
        }
        total.store(start + count, ordering: .releasing)
    }

    /// Appends a buffer of samples. Producer only.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        write(base, count: samples.count)
    }

    // MARK: Consumer

    /// Copies the newest `out.count` samples into `out`, oldest first, and
    /// returns the sample count at the end of what was copied (the audio
    /// clock of the last sample + 1). Before that many samples have been
    /// written, the start of `out` is zeros, as the web's AnalyserNode
    /// gives. Consumer only; no allocation, no locks.
    @discardableResult
    public func latest(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let count = out.count
        precondition(count <= capacity, "RingBuffer.latest: \(count) samples from a ring of \(capacity)")
        guard let dst = out.baseAddress, count > 0 else { return written }
        var end = 0
        // A few tries: a tear needs the producer to write capacity − count
        // samples during one copy, so the second try is all but certain.
        for _ in 0..<4 {
            end = total.load(ordering: .acquiring)
            let have = min(end, count)
            let zeros = count - have
            if zeros > 0 { dst.update(repeating: 0, count: zeros) }
            var pos = (end - have) & mask
            var at = zeros
            var left = have
            while left > 0 {
                let n = min(left, capacity - pos)
                (dst + at).update(from: storage + pos, count: n)
                at += n
                left -= n
                pos = 0
            }
            // The copies above must happen before the check below.
            atomicMemoryFence(ordering: .acquiring)
            let now = total.load(ordering: .relaxed)
            if now - end <= capacity - count { break }
        }
        return end
    }

    /// The newest `count` samples as a new array, oldest first. Allocates;
    /// for tests and tools, not the analysis loop.
    public func latest(count: Int) -> (samples: [Float], end: Int) {
        var out = [Float](repeating: 0, count: count)
        let end = out.withUnsafeMutableBufferPointer { latest(into: $0) }
        return (out, end)
    }
}
