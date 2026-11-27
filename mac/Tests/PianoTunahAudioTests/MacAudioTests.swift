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

/// A running output, even a silent one, keeps the Mac from idle-sleeping:
/// the tone's engine stops once nothing has sounded for `idleSeconds`, and
/// never while the sine is on. 20 Hz, so a Mac's speakers hardly play it.
@MainActor @Test func toneEngineStopsWhenIdle() async throws {
    let tones = TonePlayer(idleSeconds: 0.2)
    tones.startSine(20)
    guard tones.isSineOn else { return } // no output device on this runner
    #expect(tones.isEngineRunning)
    try await Task.sleep(for: .seconds(0.6))
    #expect(tones.isEngineRunning)
    tones.stopSine()
    try await Task.sleep(for: .seconds(1))
    #expect(!tones.isEngineRunning)
    #expect(!tones.gatesReadings())
}

/// An output engine that stops with no configuration change (as around
/// sleep) is built again while the sine is on, so the sine neither sticks
/// silently nor gates readings for good.
@MainActor @Test func sineSurvivesAnEngineThatStopsSilently() async throws {
    let tones = TonePlayer(sineCheckSeconds: 0.1)
    tones.startSine(20)
    guard tones.isSineOn else { return } // no output device on this runner
    tones.stopEngineSilently()
    #expect(!tones.isEngineRunning)
    // Up to 2 s: a loaded runner may be slow to rebuild it.
    for _ in 0..<20 where tones.isSineOn && !tones.isEngineRunning {
        try await Task.sleep(for: .seconds(0.1))
    }
    if tones.isSineOn {
        #expect(tones.isEngineRunning)
    } else {
        #expect(!tones.gatesReadings(now: TonePlayer.now() + 1))
    }
    tones.shutdown()
}

/// Which change of inputs restarts a running input: the one in use gone,
/// the chosen one back after a fallback, or the default moved while the
/// default is chosen.
@Test func runningInputIsStaleOnlyWhenNoLongerTheOneToUse() {
    func info(_ uid: String?, fallback: Bool = false) -> MicInput.Info {
        MicInput.Info(sampleRate: 48000, channels: 1, deviceName: "", deviceUID: uid, usedFallback: fallback)
    }
    let both: Set = ["builtin", "usb"]
    // The default chosen.
    #expect(!AudioSession.isStale(info("builtin"), chosenUID: nil, connected: both, defaultUID: "builtin"))
    #expect(AudioSession.isStale(info("builtin"), chosenUID: nil, connected: both, defaultUID: "usb"))
    #expect(AudioSession.isStale(info("usb"), chosenUID: nil, connected: ["builtin"], defaultUID: nil))
    // An input chosen and in use: the default moving does not matter.
    #expect(!AudioSession.isStale(info("usb"), chosenUID: "usb", connected: both, defaultUID: "builtin"))
    #expect(AudioSession.isStale(info("usb"), chosenUID: "usb", connected: ["builtin"], defaultUID: "builtin"))
    // The chosen input missing, the default in its place, until it is back.
    #expect(!AudioSession.isStale(info("builtin", fallback: true), chosenUID: "usb", connected: ["builtin"], defaultUID: "builtin"))
    #expect(AudioSession.isStale(info("builtin", fallback: true), chosenUID: "usb", connected: both, defaultUID: "builtin"))
    // The device in use unknown: no restarts on guesswork.
    #expect(!AudioSession.isStale(info(nil), chosenUID: nil, connected: both, defaultUID: "usb"))
}
#endif
