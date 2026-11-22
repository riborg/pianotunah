#if canImport(AVFoundation) && os(macOS)
import AVFoundation
import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Listening: the permission, the ``MicInput``, a ``RingBuffer`` per start
/// and the ``Analysis`` that calls `onFrame` every 90 ms of sound with the
/// latest ``Engine/bufferSize`` samples, the audio clock and the sample
/// rate. It also owns the ``Recorder`` fed from the same input, keeps the
/// display awake and App Nap away while listening (the web's wake lock),
/// and starts the input again after a device change or sleep.
///
/// Threads: main actor. `onFrame` runs on ``analysisQueue``, a serial queue
/// of its own: never the audio thread, never the main thread. When a
/// frame's ``AnalysisFrame/generation`` changes, the input was started
/// again and its sample rate may differ: call `Engine.startAudio` with it.
@MainActor @Observable
public final class AudioSession {
    public enum State: Sendable, Equatable {
        case stopped
        /// Waiting for the permission prompt or the engine.
        case starting
        case running
        /// The microphone is not allowed; it would deliver silence. Point to
        /// ``MicPermission/settingsURL``.
        case denied
        /// The input did not start; the reason is for the debug log.
        case failed(String)
    }

    public private(set) var state = State.stopped
    /// The input in use while running: device, sample rate, and whether the
    /// chosen device was missing so the default is used (the web's
    /// `mic.missing`).
    public private(set) var input: MicInput.Info?
    /// The chosen input's UID; nil for the system default. Takes effect at
    /// the next start; call ``restart()`` to switch now.
    public var deviceUID: String?

    /// The recording of the input; see ``startRecording()``.
    public let recorder = Recorder()

    private let mic = MicInput()
    private let analysis: Analysis
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    public init(onFrame: @escaping @Sendable (AnalysisFrame) -> Void) {
        analysis = Analysis(onFrame: onFrame)
        mic.onConfigurationChange = { [weak self] in self?.restart() }
        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        #endif
    }

    /// The queue `onFrame` runs on.
    public nonisolated var analysisQueue: DispatchQueue { analysis.queue }

    /// Asks for the permission if need be, then starts listening.
    public func start() async {
        guard state != .running, state != .starting else { return }
        state = .starting
        let permission = await MicPermission.request()
        guard state == .starting else { return } // stopped meanwhile
        guard permission == .authorized else {
            state = .denied
            return
        }
        open()
    }

    /// Starts the input again, for a new device choice, after a
    /// configuration change, or after sleep. Does nothing unless running.
    public func restart() {
        guard state == .running else { return }
        analysis.detach()
        mic.stop()
        open()
    }

    /// Stops listening. A recording takes no more samples but is kept for
    /// ``stopRecording()``, as app.js saves it when the microphone stops.
    public func stop() {
        analysis.detach()
        mic.stop()
        recorder.close()
        input = nil
        state = .stopped
        endActivity()
    }

    private func open() {
        let ring = RingBuffer()
        do {
            let info = try mic.start(deviceUID: deviceUID, ring: ring, recorder: recorder)
            // A recording cannot change its rate halfway.
            if recorder.isRecording, recorder.sampleRate != info.sampleRate { recorder.close() }
            analysis.attach(ring, sampleRate: info.sampleRate)
            input = info
            state = .running
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Listening to the piano"
                )
            }
        } catch {
            mic.stop()
            recorder.close()
            input = nil
            state = .failed(String(describing: error))
            endActivity()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Recording

    /// Starts recording the input, at most ``WAVWriter/maxSeconds``. Poll
    /// ``Recorder/isFull`` (app.js does every 250 ms) and then call
    /// ``stopRecording()``.
    @discardableResult
    public func startRecording() -> Bool {
        guard state == .running, let rate = input?.sampleRate else { return false }
        return recorder.start(sampleRate: rate)
    }

    /// The recording as a WAV file, or nil if there is none.
    public func stopRecording() -> Data? {
        recorder.stop()
    }
}
#endif
