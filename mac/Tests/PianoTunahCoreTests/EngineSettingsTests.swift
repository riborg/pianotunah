import Foundation
import Testing
@testable import PianoTunahCore

// EngineSettings.swift: the app's settings changes go through the engine,
// and what the engine hands back for saving keeps them.

private func freshPiano(_ id: String = "settings") -> Piano {
    var p = Piano(name: id, now: Date(timeIntervalSince1970: 0), makeID: { id })
    p.settings = .defaults
    return p
}

/// Plays `frames` frames of the A4 take (44.1 kHz) into the engine, as the
/// scenarios in Fixtures/engine/ do; returns the events.
private func playA4(_ e: Engine, frames: Int) throws -> [Engine.Event] {
    let take = try Fixtures.f32("engine/a4.f32")
    let hop = 3969 // 90 ms at 44.1 kHz
    var events: [Engine.Event] = []
    for i in 1...frames {
        let end = i * hop
        var b = [Float](repeating: 0, count: Engine.bufferSize)
        let from = end - Engine.bufferSize
        for j in Swift.max(0, from)..<Swift.min(end, take.count) { b[j - from] = take[j] }
        let t = Double(i) * 0.09
        events += e.frame(b, time: t, now: t * 1000, wall: 1_790_000_000_000 + t * 1000).events
    }
    return events
}

@Test func aSettingChangesTheTargets() {
    let e = Engine(piano: freshPiano())
    var events: [Engine.Event] = []
    e.onEvent = { events.append($0) }
    e.setSettings { $0.refA4 = 442 }
    #expect(e.piano.settings.refA4 == 442)
    #expect(abs(e.targets.frequency[a4] - 442) < 1e-9)
    #expect(events == [.targets])
    e.setSettings { $0.temperament = "werckmeister3" }
    #expect(e.targets.cents == computeTargets(e.settings, measuredB: [:]).cents)
}

@Test func aKeyCountRebuildsTheOrderAndKeepsTheKeyOnTheKeyboard() {
    let e = Engine(piano: freshPiano())
    e.selectKey(88)
    e.setSettings { $0.keyCount = 85 }
    #expect(e.top == 85)
    #expect(e.key == 85)
    #expect(e.order.steps.flatMap(\.tasks).map(\.key).max() == 85)
    e.setSettings { $0.keyCount = 88 }
    #expect(e.order.steps.flatMap(\.tasks).map(\.key).max() == 88)
    // Another setting leaves the order's position alone.
    e.goOrder(TuningOrder.Position(step: 1, index: 2))
    e.setSettings { $0.tolerance = 2 }
    #expect(e.orderPos == TuningOrder.Position(step: 1, index: 2))
    #expect(e.tolerance == 2)
}

@Test func fitRefNeedsAReading() throws {
    let e = Engine(piano: freshPiano())
    #expect(e.fitRef() == nil)
    #expect(e.settings.refA4 == 440)
    // The A4 take sounding (about 440 Hz) at another reference: the
    // reading puts the reference near the piano.
    e.setSettings { $0.refA4 = 435 }
    e.startAudio(sampleRate: 44100)
    e.selectKey(a4)
    _ = try playA4(e, frames: 14)
    #expect(e.signal)
    let hz = try #require(e.fitRef())
    #expect(hz == e.settings.refA4)
    #expect(hz == Engine.clampRef(hz))
    #expect(abs(hz - 440) < 2, "\(hz)")
}

@Test func refAdviceAndMidShiftWithoutTheEngineMatchIt() {
    var p = freshPiano()
    for k in Engine.middle where k % 3 == 0 {
        p.keys[k] = Piano.Measurement(hz: 440, n: 1, beforeHz: 0, beforeN: 1, at: 0)
    }
    let e = Engine(piano: p)
    #expect(e.midShift.isNaN)
    #expect(Engine.midShift([]).isNaN && Engine.midShift([1, 2]).isNaN)
    #expect(Engine.midShift([-20, -12, -14]) == -14)
    #expect(Engine.refAdvice(midShift: .nan, refA4: 440) == .none)
    #expect(Engine.refAdvice(midShift: -2, refA4: 440) == .near(m: -2))
    guard case .off(let a) = Engine.refAdvice(midShift: -14, refA4: 440) else {
        Issue.record("not off")
        return
    }
    #expect(a.p == 25 && a.o == 3.5 && a.big == false)
    #expect(e.refAdvice == Engine.refAdvice(midShift: e.midShift, refA4: e.settings.refA4))
}

/// The library saves what the engine hands back (the app's EngineChanges:
/// settings, keys, B, partials, order, history). A settings change made
/// through the engine is in that, also after frames that save readings;
/// one made beside the engine would be lost to it.
@Test func aSettingsChangeSurvivesTheEnginesNextSave() throws {
    var library = freshPiano()
    let e = Engine(piano: library)
    var saves = 0
    e.onEvent = { if case .saved = $0 { saves += 1 } }
    e.startAudio(sampleRate: 44100)
    e.selectKey(a4)
    e.setSettings {
        $0.refA4 = 441.5
        $0.keyCount = 85
        $0.tolerance = 0.5
    }
    _ = try playA4(e, frames: 40)
    #expect(saves > 0)
    #expect(e.piano.keys[a4] != nil)

    // What the app writes back over the library's piano.
    let handedBack = e.piano
    library.keys = handedBack.keys
    library.settings = handedBack.settings
    #expect(library.settings.refA4 == 441.5)
    #expect(library.settings.keyCount == 85)
    #expect(library.settings.tolerance == 0.5)
    #expect(library.keys[a4] != nil)

    // The readings were judged against the new reference.
    #expect(abs(e.targets.frequency[a4] - 441.5) < 1e-9)
}
