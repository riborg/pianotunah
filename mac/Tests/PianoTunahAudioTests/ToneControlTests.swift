import Testing
@testable import PianoTunahAudio

private func render(_ control: ToneControl, samples: Int) -> [Float] {
    var out = [Float](repeating: 0, count: samples)
    out.withUnsafeMutableBufferPointer { buf in
        var at = 0
        while at < buf.count {
            let n = min(256, buf.count - at)
            control.render(into: UnsafeMutableBufferPointer(rebasing: buf[at..<(at + n)]))
            at += n
        }
    }
    return out
}

@Test func sineStopWinsOverAFullQueue() {
    let control = ToneControl(sampleRate: 8000, queueCapacity: 4)
    control.setSine(440)
    _ = render(control, samples: 800)
    #expect(control.synth.sineOn)
    // The queue fills up with plucks that the render side has not taken.
    for _ in 0..<4 { #expect(control.pluck(f1: 220, b: 0)) }
    #expect(!control.pluck(f1: 220, b: 0))
    control.setSine(nil)
    _ = render(control, samples: 1)
    #expect(!control.synth.sineOn)
}

@Test func sineStateIsTheLatestSet() throws {
    let control = ToneControl(sampleRate: 8000)
    control.setSine(500)
    control.setSine(600) // before any render: starts at 600
    _ = render(control, samples: 1)
    #expect(control.synth.sineHz == 600)
    control.setSine(700) // on: glides there
    _ = render(control, samples: 800)
    #expect(abs(try #require(control.synth.sineHz) - 700) < 0.01)
    control.setSine(nil)
    control.setSine(nil)
    let off = render(control, samples: 800)
    #expect(!control.synth.sineOn)
    #expect(off[600...].allSatisfy { $0 == 0 }) // 60 ms release, then silence
    control.setSine(.nan) // not a frequency: stays off
    control.setSine(0)
    _ = render(control, samples: 1)
    #expect(!control.synth.sineOn)
}

@Test func plucksReachTheSynthThroughTheQueue() {
    let control = ToneControl(sampleRate: 8000)
    #expect(control.synth.isSilent)
    #expect(control.pluck(f1: 220, b: 0))
    let s = render(control, samples: 400)
    #expect(!control.synth.isSilent && !control.synth.sineOn)
    #expect(s.contains { $0 != 0 })
}
