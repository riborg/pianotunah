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
/// Restarts follow a ``RestartPolicy``: the engine's configuration change
/// and the wake restart it 0.5 s later; a failed input is tried again when
/// the inputs change or the Mac wakes, and a running one when the inputs
/// change so that it is no longer the one to use (unplugged, the chosen
/// one back, the default moved); and after three automatic restarts in
/// 10 s (an engine whose start changes its own configuration) the next is
/// refused and the state stays ``State/failed(_:)`` until one of those
/// or ``restart()``. While a restart waits, the state stays as it was.
///
/// Threads: main actor. `onFrame` runs on ``analysisQueue``, a serial queue
/// of its own: never the audio thread, never the main thread. When a
/// frame's ``AnalysisFrame/generation`` changes, the input was started
/// again and its sample rate may differ: call `Engine.startAudio` with it.
/// `onStop` runs on the same queue, after the last frame, when the input
/// stops and no frames follow: ``stop()``, an input that failed or did
/// not start, and the restart limit. Call `Engine.stopAudio` there. It
/// may also come with no input running before it (``stop()`` when stopped).
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
        /// The input did not start, or stopped and restarted too often; the
        /// reason is for the debug log. It is tried again when the inputs
        /// change, after sleep, and by ``restart()``.
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

    /// Why a recording stopped taking samples before it was full.
    public enum RecordingCut: Sendable, Equatable {
        /// The input started again (a device change, sleep, a new device
        /// choice). A recording never spans two starts: the new start may
        /// have another sample rate, and the gap between them would be
        /// spliced in silently.
        case inputRestarted
        /// The input stopped on its own and did not start again.
        case inputFailed
    }

    /// Why the last recording was cut short, for the app to show next to
    /// it; nil if it was not. Reset by ``startRecording()``. The recording
    /// itself is kept for ``stopRecording()``, and ``Recorder/isFull`` is
    /// true once it is cut.
    public private(set) var recordingCut: RecordingCut?

    private let mic = MicInput()
    private let analysis: Analysis
    private let onStop: @Sendable () -> Void
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// Watched for retrying a failed input when the inputs change.
    private let devices = InputDevices()
    @ObservationIgnored private var policy = RestartPolicy()
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    public init(
        onFrame: @escaping @Sendable (AnalysisFrame) -> Void,
        onStop: @escaping @Sendable () -> Void = {}
    ) {
        analysis = Analysis(onFrame: onFrame)
        self.onStop = onStop
        mic.onConfigurationChange = { [weak self] in self?.trigger(.configurationChange) }
        devices.onChange = { [weak self] in self?.trigger(.inputsChanged) }
        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger(.wake) }
        }
        #endif
    }

    /// The queue `onFrame` runs on.
    public nonisolated var analysisQueue: DispatchQueue { analysis.queue }

    /// Asks for the permission if need be, then starts listening.
    public func start() async {
        guard state != .running, state != .starting else { return }
        cancelRestart()
        policy.reset()
        state = .starting
        let permission = await MicPermission.request()
        guard state == .starting else { return } // stopped meanwhile
        guard permission == .authorized else {
            state = .denied
            return
        }
        open()
    }

    /// Starts the input again now: for a new device choice, or to retry a
    /// failed input (a retry button). Does nothing unless running or
    /// failed. An open recording is cut (``recordingCut``). Configuration
    /// changes and sleep restart it by themselves.
    public func restart() {
        guard isRestartable else { return }
        cancelRestart()
        if policy.request(.user, at: Self.now()) == .now { reopen() }
    }

    /// Stops listening. A recording takes no more samples but is kept for
    /// ``stopRecording()``, as app.js saves it when the microphone stops.
    public func stop() {
        cancelRestart()
        policy.reset()
        analysis.detach()
        mic.stop()
        recorder.close()
        input = nil
        state = .stopped
        endActivity()
        inputStopped()
    }

    // MARK: Restarts

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private var isRestartable: Bool {
        switch state {
        case .running, .failed: true
        case .stopped, .starting, .denied: false
        }
    }

    /// A reason to start the input again: which apply depends on the state,
    /// and when is the policy's.
    private func trigger(_ trigger: RestartPolicy.Trigger) {
        let applies = switch (trigger, state) {
        case (.configurationChange, .running), (.wake, .running), (.wake, .failed), (.inputsChanged, .failed): true
        case (.inputsChanged, .running): input.map {
            Self.isStale($0, chosenUID: deviceUID, connected: Set(devices.devices.map(\.uid)), defaultUID: devices.defaultUID)
        } ?? false
        default: false
        }
        guard applies, case let .at(due)? = policy.request(trigger, at: Self.now()) else { return }
        scheduleRestart(at: due)
    }

    /// Whether the input in use is no longer the one to use, now that the
    /// inputs changed: it was unplugged, the chosen one is back after a
    /// fallback to the default, or the default moved while it is in use.
    /// AVAudioEngine is not documented to restart for any of these, and
    /// without a restart the app would go on with the built-in microphone
    /// after the chosen one is plugged in, while Settings says it is not
    /// connected and lists it.
    nonisolated static func isStale(
        _ input: MicInput.Info, chosenUID: String?, connected: Set<String>, defaultUID: String?
    ) -> Bool {
        guard let used = input.deviceUID else { return false }
        if !connected.contains(used) { return true }
        if let chosenUID { return input.usedFallback && connected.contains(chosenUID) }
        return defaultUID != nil && used != defaultUID
    }

    private func scheduleRestart(at due: Double) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due - Self.now())))
            guard !Task.isCancelled else { return }
            self?.restartDue()
        }
    }

    private func restartDue() {
        restartTask = nil
        guard isRestartable else { return policy.reset() }
        if policy.due(at: Self.now()) {
            reopen()
        } else if let later = policy.pending {
            // A change of inputs waits for room in the budget.
            scheduleRestart(at: later)
        } else if policy.isExhausted, state == .running {
            // The engine keeps changing its own configuration: leave it off.
            close()
            state = .failed("the input restarted too often; waiting for a device change, wake or retry")
        }
    }

    private func cancelRestart() {
        restartTask?.cancel()
        restartTask = nil
    }

    private func reopen() {
        analysis.detach()
        mic.stop()
        open()
    }

    /// Stops the input after it failed: as ``stop()``, but the recording is
    /// cut with a reason.
    private func close() {
        analysis.detach()
        mic.stop()
        cutRecording(.inputFailed)
        input = nil
        endActivity()
        inputStopped()
    }

    /// Tells the owner on the analysis queue, after the detach queued
    /// before it, so no frame of the stopped input comes after `onStop`.
    private func inputStopped() {
        analysis.queue.async(execute: onStop)
    }

    // MARK: Engine

    private func open() {
        // Before the new engine starts: its tap writes to the recorder from
        // its first buffer, and only a closed recorder ignores that.
        let cutHere = recorder.isRecording && !recorder.isFull
        cutRecording(.inputRestarted)
        let ring = RingBuffer()
        do {
            let info = try mic.start(deviceUID: deviceUID, ring: ring, recorder: recorder)
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
            // Cut here and the input did not start: it failed.
            if cutHere { recordingCut = .inputFailed }
            input = nil
            state = .failed(String(describing: error))
            endActivity()
            // A failed restart had frames (reopen() detached them); a
            // failed first start had none, and onStop is harmless then.
            inputStopped()
        }
    }

    /// Closes an open recording, saying why if it was not full yet.
    private func cutRecording(_ why: RecordingCut) {
        if recorder.isRecording, !recorder.isFull { recordingCut = why }
        recorder.close()
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
        guard state == .running, let rate = input?.sampleRate, recorder.start(sampleRate: rate) else { return false }
        recordingCut = nil
        return true
    }

    /// The recording as a WAV file, or nil if there is none.
    public func stopRecording() -> Data? {
        recorder.stop()
    }
}
#endif
