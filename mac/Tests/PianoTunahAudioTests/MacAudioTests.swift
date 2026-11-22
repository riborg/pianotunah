#if canImport(AVFoundation) && os(macOS)
import Testing
@testable import PianoTunahAudio

// The Mac glue needs a microphone and a person to test; CI's runners have
// neither. These only check that it links and that the queries that need
// no device or permission prompt work.

@Test func inputDevicesHaveUniqueUIDs() {
    let list = InputDevices.list()
    #expect(Set(list.map(\.uid)).count == list.count)
}

@Test func micPermissionCanBeAskedWithoutAPrompt() {
    _ = MicPermission.current
    #expect(MicPermission.settingsURL.scheme == "x-apple.systempreferences")
}

@MainActor @Test func sessionAndToneStartStopped() {
    let session = AudioSession { _ in }
    #expect(session.state == .stopped)
    #expect(session.input == nil)
    #expect(!session.startRecording())
    #expect(session.recordingCut == nil)
    session.restart() // only from running or failed
    #expect(session.state == .stopped)
    let tones = TonePlayer()
    #expect(!tones.isSineOn)
    #expect(tones.audibleUntil == 0)
    #expect(!tones.gatesReadings(now: 1))
}
#endif
