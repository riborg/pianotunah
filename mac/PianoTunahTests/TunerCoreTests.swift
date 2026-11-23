import Foundation
import PianoTunahAudio
import PianoTunahCore
import Testing
@testable import PianoTunah

// The core on the test's thread instead of the analysis queue: what it
// delivers after a command from the inspector.

/// The latest update the core delivered; the core calls back on the caller's
/// thread here, so no lock is needed.
private final class Delivered: @unchecked Sendable {
    var last: TunerCore.Update?
}

@MainActor @Suite struct TunerCoreEdits {
    @Test func changingTheStringsRebuildsTheOrderPanel() throws {
        let delivered = Delivered()
        let core = TunerCore(tones: TonePlayer()) { delivered.last = $0 }
        let piano = Piano(name: "Test")
        core.open(piano)
        // The order on A4, the middle step's first task: three strings.
        core.perform { engine in
            engine.setOrderOn(true)
            engine.goOrder(TuningOrder.Position(step: engine.orderStepIndex(.middle), index: 0))
            return nil
        }
        let before = try #require(delivered.last?.snapshot?.order)
        #expect(before.task?.key == a4)
        #expect(before.strings == 3)

        // Two strings on every key, from the inspector.
        _ = core.edit(piano.id) { $0.setStrings(two: Double(keyCount), one: 0) }
        let after = try #require(delivered.last?.snapshot?.order)
        #expect(after.task?.key == a4)
        #expect(after.strings == 2)
    }
}
