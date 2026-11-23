import Foundation
import Testing
@testable import PianoTunahAudio

@Test func frameEvery90msOfSamples() {
    #expect(FrameClock(sampleRate: 48000).interval == 4320)
    #expect(FrameClock(sampleRate: 44100).interval == 3969)
    #expect(FrameClock(sampleRate: 96000).interval == 8640)
}

private func due(_ c: inout FrameClock, _ written: Int) -> Bool {
    c.frameDue(written: written)
}

@Test func framesFollowTheSampleCount() {
    var c = FrameClock(sampleRate: 48000)
    #expect(!due(&c, 0))
    #expect(!due(&c, 4319))
    #expect(due(&c, 4320))
    #expect(!due(&c, 4320)) // once per frame
    #expect(!due(&c, 8000))
    #expect(due(&c, 8640 + 100))
    #expect(c.next == 12960)
}

@Test func missedFramesAreDroppedNotCaughtUp() {
    var c = FrameClock(sampleRate: 48000)
    // The queue was busy for half a second.
    #expect(due(&c, 24000))
    #expect(c.next == 25920) // the grid point after 24000
    #expect(!due(&c, 25919))
    #expect(due(&c, 25920))
}

@Test func frameTimeIsTheAudioClockAtTheEnd() {
    let c = FrameClock(sampleRate: 48000, startTime: 10)
    #expect(c.time(atSample: 0) == 10)
    #expect(abs(c.time(atSample: 4320) - 10.09) < 1e-12)
    #expect(c.time(atSample: 48000) == 11)
}

/// Writes `blocks` blocks of 480 samples of 0.5, each followed by a pump on
/// the queue, so the frames do not depend on how fast the timer runs.
private func feed(_ analysis: Analysis, _ ring: RingBuffer, blocks: Int) {
    let block = [Float](repeating: 0.5, count: 480)
    for _ in 0..<blocks {
        block.withUnsafeBufferPointer { ring.write($0) }
        analysis.queue.sync { analysis.pump() }
    }
}

@Test func analysisDeliversFramesOnItsQueue() throws {
    let got = Collector()
    let analysis = Analysis { frame in
        dispatchPrecondition(condition: .notOnQueue(.main))
        got.add(frame)
    }
    let ring = RingBuffer()
    analysis.attach(ring, sampleRate: 48000)
    // 0.5 s of samples: frames are due at 4320 × 1…5.
    feed(analysis, ring, blocks: 50)
    analysis.detach()
    analysis.queue.sync {}
    let frames = got.frames
    #expect(frames.count == 5)
    #expect(frames.allSatisfy { $0.samples.count == 32768 && $0.sampleRate == 48000 && $0.generation == 1 })
    // Each frame ends at the first block at or after its point on the grid.
    #expect(frames.map { Int(($0.time * 48000).rounded()) } == [4320, 8640, 12960, 17280, 21600])
    // The samples end where the time says: that many samples of 0.5 at the
    // end, zeros before.
    let last = try #require(frames.last)
    #expect(last.samples[32768 - 21600] == 0.5 && last.samples[32768 - 21600 - 1] == 0)

    // A restart: a new generation, and the time goes on from 0.5 s.
    let ring2 = RingBuffer()
    analysis.attach(ring2, sampleRate: 44100)
    feed(analysis, ring2, blocks: 10)
    analysis.detach()
    analysis.queue.sync {}
    let after = Array(got.frames.dropFirst(frames.count))
    #expect(after.count == 1)
    let first = try #require(after.first)
    #expect(first.generation == 2 && first.sampleRate == 44100)
    #expect(abs(first.time - (0.5 + 4320 / 44100.0)) < 1e-9, "\(first.time)") // 9 blocks of 480 ≥ 3969
}

@Test func analysisTimerFindsTheFramesByItself() async throws {
    let got = Collector()
    let analysis = Analysis(pollInterval: .milliseconds(1)) { got.add($0) }
    let ring = RingBuffer()
    analysis.attach(ring, sampleRate: 48000)
    [Float](repeating: 0.1, count: 9000).withUnsafeBufferPointer { ring.write($0) }
    for _ in 0..<200 where got.frames.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    analysis.detach()
    #expect(got.frames.count == 1)
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AnalysisFrame] = []
    func add(_ f: AnalysisFrame) { lock.withLock { list.append(f) } }
    var frames: [AnalysisFrame] { lock.withLock { list } }
}

@Test func referenceGateCoversTheToneAnd800ms() {
    #expect(ReferenceGate.isShut(audibleUntil: 10, now: 9))
    #expect(ReferenceGate.isShut(audibleUntil: 10, now: 10.79))
    #expect(!ReferenceGate.isShut(audibleUntil: 10, now: 10.8))
    #expect(ReferenceGate.isShut(audibleUntil: .infinity, now: 1e9))
    #expect(!ReferenceGate.isShut(audibleUntil: 0, now: 1))
}
