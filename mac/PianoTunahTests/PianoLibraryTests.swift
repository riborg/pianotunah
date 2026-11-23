import Foundation
import PianoTunahCore
import Testing
@testable import PianoTunah

// Saving the pianos: a piano that keeps changing, as with every frame of a
// ringing note, is still saved within the delay of its first change.

@MainActor @Suite struct LibrarySaving {
    @Test func aPianoThatKeepsChangingIsSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "PianoTunahTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = PianoLibrary(directory: dir)
        library.newPiano()
        let id = try #require(library.selectedID)
        // A change every 0.5 s for 4 s: the first is due at 2.5 s, while
        // they still come. Restarting the timer on each change would save
        // only 2.5 s after the last one, at 6 s.
        for i in 0..<8 {
            library.rename(id, to: "Change \(i)")
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(try PianoStore(directory: dir).list().map(\.id) == [id])
    }
}
