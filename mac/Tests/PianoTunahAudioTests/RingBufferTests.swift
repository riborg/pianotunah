import Foundation
import Testing
@testable import PianoTunahAudio

private func ramp(_ range: Range<Int>) -> [Float] {
    range.map { Float($0) }
}

private func write(_ ring: RingBuffer, _ samples: [Float]) {
    samples.withUnsafeBufferPointer { ring.write($0) }
}

@Test func ringCapacityIsAPowerOfTwoOfAtLeastAFrame() {
    #expect(RingBuffer().capacity == 65536)
    #expect(RingBuffer(minimumCapacity: 1).capacity == 32768)
    #expect(RingBuffer(minimumCapacity: 40000).capacity == 65536)
}

@Test func ringCountsEverySample() {
    let ring = RingBuffer()
    #expect(ring.written == 0)
    write(ring, ramp(0..<512))
    #expect(ring.written == 512)
    // More than the ring holds at once: all counted, the newest kept.
    write(ring, ramp(512..<(512 + 70000)))
    #expect(ring.written == 70512)
    let (s, end) = ring.latest(count: 32768)
    #expect(end == 70512)
    #expect(s == ramp((70512 - 32768)..<70512))
}

@Test func ringZeroFillsBeforeAFrameHasArrived() {
    let ring = RingBuffer()
    write(ring, ramp(1..<101))
    let (s, end) = ring.latest(count: 32768)
    #expect(end == 100)
    #expect(s.count == 32768)
    #expect(s[..<(32768 - 100)].allSatisfy { $0 == 0 })
    #expect(Array(s[(32768 - 100)...]) == ramp(1..<101))
}

@Test func ringWrapsAroundOldestFirst() {
    let ring = RingBuffer(minimumCapacity: 32768)
    // Odd block sizes, so writes straddle the end of the storage.
    var next = 0
    for size in [1000, 777, 1023, 513, 4096, 999] {
        for _ in 0..<15 {
            write(ring, ramp(next..<(next + size)))
            next += size
        }
    }
    #expect(next > 2 * ring.capacity)
    #expect(ring.written == next)
    for count in [1, 100, 4320, 32768] {
        let (s, end) = ring.latest(count: count)
        #expect(end == next)
        #expect(s == ramp((next - count)..<next), "latest(\(count))")
    }
}

@Test func ringTakesOneChannelOfInterleavedSamples() {
    let ring = RingBuffer()
    let stereo: [Float] = [1, -1, 2, -2, 3, -3]
    stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3, stride: 2) }
    #expect(ring.written == 3)
    #expect(ring.latest(count: 3).samples == [1, 2, 3])
}

/// A producer writes a ramp in audio-sized blocks on its own thread while
/// the consumer reads frames as fast as it can; every frame must be one
/// unbroken stretch of the ramp ending where the returned count says.
@Test func ringProducerAndConsumerOnTwoThreads() {
    let ring = RingBuffer()
    let blocks = 4000
    let block = 512
    let producer = Thread {
        var buf = [Float](repeating: 0, count: block)
        for b in 0..<blocks {
            for i in 0..<block { buf[i] = Float((b * block + i) % (1 << 24)) }
            buf.withUnsafeBufferPointer { ring.write($0) }
            if b % 32 == 0 { usleep(100) }
        }
    }
    producer.start()
    var frames = 0
    var bad = 0
    var out = [Float](repeating: 0, count: 32768)
    while ring.written < blocks * block {
        let end = out.withUnsafeMutableBufferPointer { ring.latest(into: $0) }
        frames += 1
        let have = min(end, out.count)
        for i in 0..<have where out[out.count - have + i] != Float((end - have + i) % (1 << 24)) {
            bad += 1
            break
        }
    }
    #expect(frames > 10)
    #expect(bad == 0)
    #expect(ring.written == blocks * block)
}

private enum Command: BitwiseCopyable, Equatable {
    case startSine(Double), setSine(Double), stopSine, pluck(f1: Double, b: Double)
}

@Test func commandQueueKeepsOrderAndRefusesWhenFull() {
    let q = SPSCQueue<Command>(capacity: 3)
    #expect(q.pop() == nil)
    #expect(q.push(.startSine(440)))
    #expect(q.push(.setSine(441)))
    #expect(q.push(.stopSine))
    #expect(!q.push(.pluck(f1: 1, b: 0)))
    #expect(q.pop() == .startSine(440))
    #expect(q.push(.pluck(f1: 1, b: 0)))
    #expect(q.pop() == .setSine(441))
    #expect(q.pop() == .stopSine)
    #expect(q.pop() == .pluck(f1: 1, b: 0))
    #expect(q.pop() == nil)
}

@Test func commandQueueAcrossThreads() {
    let q = SPSCQueue<Int>(capacity: 16)
    let n = 100_000
    let producer = Thread {
        var i = 0
        while i < n { if q.push(i) { i += 1 } }
    }
    producer.start()
    var expected = 0
    var ok = true
    while expected < n {
        if let v = q.pop() {
            if v != expected { ok = false }
            expected += 1
        }
    }
    #expect(ok)
}
