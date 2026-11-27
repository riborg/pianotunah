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

/// Every update the core delivered, and a steady clock the test moves.
private final class Recorded: @unchecked Sendable {
    var updates: [TunerCore.Update] = []
    var now = 0.0
    var core: TunerCore!
}

/// A ringing note changes the piano every frame; the library gets those
/// changes at most once a second, so the views that read it are not drawn
/// again with every frame. Nothing is lost: the rest comes when the
/// microphone stops.
@MainActor @Suite struct TunerCoreFrames {
    @Test func aRingingNoteHandsItsChangesOverOnceASecond() throws {
        let recorded = try Self.playA4(changesInterval: 1)
        let handedOver = recorded.updates.compactMap(\.changes)
        #expect(!handedOver.isEmpty, "the strikes were saved")
        #expect(handedOver.count <= 5, "at most once a second over 4.1 s")
    }

    @Test func whatIsHeldBackComesWhenTheMicrophoneStops() throws {
        // Longer than the take: only the first strike's changes are handed
        // over while it plays; the later strikes' wait.
        let recorded = try Self.playA4(changesInterval: 100)
        #expect(recorded.updates.filter { $0.changes != nil }.count <= 1)
        recorded.core.stopAudio()
        let changes = try #require(recorded.updates.last?.changes)
        #expect(changes.keys[a4] != nil)
        #expect(recorded.core.takeChanges() == nil)
        // At quit: nothing unsaved, but the model has not applied the last
        // hand-over yet, so the piano goes again; once it has, nothing.
        let quit = try #require(recorded.core.changesAtQuit(applied: changes.serial - 1))
        #expect(quit.keys[a4] != nil)
        #expect(recorded.core.changesAtQuit(applied: quit.serial) == nil)
    }

    /// 4.1 s of the A4 take into a new piano locked on A4, as the
    /// lock-save scenario plays it, one update per frame.
    private static func playA4(changesInterval: Double) throws -> Recorded {
        let take = try a4()
        let recorded = Recorded()
        let core = TunerCore(tones: TonePlayer(), changesInterval: changesInterval, clock: { recorded.now }) {
            recorded.updates.append($0)
        }
        recorded.core = core
        core.open(Piano(name: "Test"))
        core.perform { $0.selectKey(a4); return nil }
        recorded.updates = []
        let hop = 3969 // 90 ms at 44.1 kHz
        let frames = 46
        for i in 1...frames {
            let end = i * hop
            var b = [Float](repeating: 0, count: Engine.bufferSize)
            let from = end - Engine.bufferSize
            for j in max(0, from)..<min(end, take.count) { b[j - from] = take[j] }
            recorded.now = Double(i) * 0.09
            core.frame(AnalysisFrame(samples: b, time: recorded.now, sampleRate: 44100, generation: 1))
        }
        #expect(recorded.updates.count == frames)
        return recorded
    }

    /// The A4 take the engine scenarios play (44.1 kHz, little-endian
    /// Float32), read from the core's test fixtures.
    private static func a4() throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/PianoTunahCoreTests/Fixtures/engine/a4.f32")
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}
