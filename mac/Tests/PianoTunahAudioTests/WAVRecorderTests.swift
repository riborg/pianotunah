import Foundation
import Testing
@testable import PianoTunahAudio

@Test func wavHeaderIsTheWebsByteForByte() {
    // What wavBlob in web/static/js/mic.js writes for 3 samples at 48 kHz.
    let want: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, 0x30, 0x00, 0x00, 0x00, // RIFF, 36 + 12
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20, // WAVE fmt
        0x10, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, // 16, IEEE float, mono
        0x80, 0xBB, 0x00, 0x00, 0x00, 0xEE, 0x02, 0x00, // 48000 Hz, 192000 B/s
        0x04, 0x00, 0x20, 0x00, 0x64, 0x61, 0x74, 0x61, // align 4, 32 bits, data
        0x0C, 0x00, 0x00, 0x00, // 12 bytes
    ]
    #expect(WAVWriter.header(sampleCount: 3, sampleRate: 48000) == want)
    let wav = WAVWriter.wav([1, -0.5, 0], sampleRate: 48000)
    #expect(Array(wav) == want + [0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x00, 0x00])
}

@Test func wavIsCutAt120s() {
    #expect(WAVWriter.maxSamples(sampleRate: 48000) == 5_760_000)
    let samples = [Float](repeating: 0.25, count: 130)
    let wav = WAVWriter.wav(samples, sampleRate: 1) // 120 s at 1 Hz
    #expect(wav.count == 44 + 120 * 4)
    #expect(wav[40..<44].elementsEqual([0xE0, 0x01, 0x00, 0x00]))
}

private func ramp(_ range: Range<Int>) -> [Float] { range.map { Float($0) } }

private func floats(_ wav: Data) -> [Float] {
    stride(from: 44, to: wav.count, by: 4).map { (i: Int) -> Float in
        var bits: UInt32 = 0
        for j in 0..<4 { bits |= UInt32(wav[i + j]) << (8 * j) }
        return Float(bitPattern: bits)
    }
}

@Test func recorderKeepsSamplesUpToItsLimit() throws {
    let rec = Recorder()
    #expect(!rec.isRecording)
    #expect(rec.stop() == nil)
    rec.append(ramp(0..<10), count: 10) // not recording: ignored
    #expect(rec.start(sampleRate: 1000, maxSeconds: 1))
    #expect(!rec.start(sampleRate: 1000)) // one at a time
    #expect(rec.isRecording && !rec.isFull)
    rec.append(ramp(0..<600), count: 600)
    #expect(rec.recordedSeconds == 0.6)
    rec.append(ramp(600..<1200), count: 600)
    #expect(rec.isFull)
    #expect(rec.recordedSeconds == 1)
    let wav = try #require(rec.stop())
    #expect(Array(wav.prefix(44)) == WAVWriter.header(sampleCount: 1000, sampleRate: 1000))
    #expect(floats(wav) == ramp(0..<1000))
    #expect(!rec.isRecording && rec.recordedSeconds == 0)
}

@Test func recorderClosedTakesNoMore() throws {
    let rec = Recorder()
    rec.start(sampleRate: 100)
    let stereo: [Float] = [1, 9, 2, 9, 3, 9]
    stereo.withUnsafeBufferPointer { rec.append($0.baseAddress!, count: 3, stride: 2) }
    rec.close()
    #expect(rec.isFull && rec.isRecording)
    rec.append(ramp(0..<5), count: 5)
    #expect(floats(try #require(rec.stop())) == [1, 2, 3])
}

private extension Recorder {
    func append(_ samples: [Float], count: Int) {
        samples.withUnsafeBufferPointer { append($0.baseAddress!, count: count) }
    }
}

/// Stopping while the audio thread appends: the file is an unbroken prefix
/// of what was appended.
@Test func recorderStopsWhileTheAudioThreadWrites() throws {
    for _ in 0..<20 {
        let rec = Recorder()
        rec.start(sampleRate: 48000)
        let done = Atomicish()
        let audio = Thread {
            var next = 0
            var block = [Float](repeating: 0, count: 256)
            while !done.value {
                for i in 0..<256 { block[i] = Float(next + i) }
                block.withUnsafeBufferPointer { rec.append($0.baseAddress!, count: 256) }
                next += 256
            }
        }
        audio.start()
        usleep(2000)
        let got = floats(try #require(rec.stop()))
        done.value = true
        #expect(got == ramp(0..<got.count))
        #expect(got.count % 256 == 0)
    }
}

private final class Atomicish: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
