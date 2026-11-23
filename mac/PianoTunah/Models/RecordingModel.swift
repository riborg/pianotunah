import AppKit
import Foundation
import Observation
import PianoTunahAudio
import SwiftUI
import UniformTypeIdentifiers

/// A finished recording, for the save panel (`fileExporter`).
struct WAVFile: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }

    var data: Data
    /// The suggested name, pianotunah-YYYYMMDD-HHMMSS.wav as on the web.
    var name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.filename ?? "pianotunah.wav"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Recording the microphone input to a WAV file (app.js `toggleRecording`
/// and `finishRecording`): at most ``WAVWriter/maxSeconds``, then the save
/// panel. Lives as long as the app, so a recording goes on while the
/// Settings window is closed.
///
/// The recording ends by itself when it is full, when the microphone is
/// stopped, or when the input is cut (``AudioSession/recordingCut``); it is
/// then waiting in ``pending`` for the save panel: the Settings window's
/// if it is open, else the main window's, from the notice there
/// (``saveFromMain``). Quitting with a recording not yet saved asks first
/// (``confirmQuit()``).
@MainActor @Observable
final class RecordingModel {
    enum Outcome: Equatable {
        /// Saved under this file name.
        case saved(String)
        /// The save panel was cancelled.
        case discarded
        /// The audio session refused to start one.
        case notStarted
        /// The recorder had nothing to save.
        case empty
        /// Writing the file failed, with the reason.
        case saveFailed(String)
    }

    private(set) var isRecording = false
    /// The length so far, s.
    private(set) var seconds = 0.0
    /// The finished recording, until it is saved or discarded.
    var pending: WAVFile?
    /// What became of the latest recording.
    private(set) var outcome: Outcome?
    /// The Settings window is open, so its save panel offers ``pending``.
    var settingsOpen = false
    /// The main window's save panel offers ``pending`` (its notice's Save…).
    var saveFromMain = false
    /// Quitting asks what to do with ``pending``; neither save panel opens
    /// meanwhile.
    private(set) var quitting = false

    let session: AudioSession
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(session: AudioSession) {
        self.session = session
    }

    static var maxSeconds: Double { WAVWriter.maxSeconds }

    var canStart: Bool {
        !isRecording && pending == nil && session.state == .running
    }

    func toggle() {
        if isRecording { finish() } else { start() }
    }

    func start() {
        guard canStart else { return }
        outcome = nil
        guard session.startRecording() else {
            outcome = .notStarted
            return
        }
        isRecording = true
        seconds = 0
        // app.js polls every 250 ms as well.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// Ends the recording and hands it to the save panel.
    func finish() {
        guard isRecording else { return }
        ticker?.cancel()
        ticker = nil
        isRecording = false
        guard let data = session.stopRecording() else {
            outcome = .empty
            return
        }
        pending = WAVFile(data: data, name: Self.fileName(Date()))
    }

    /// Whether the Settings window's save panel is up. The quit alert
    /// leaves it alone: hiding it would read as the user dismissing it.
    var savesInSettings: Bool {
        pending != nil && !saveFromMain
    }

    /// Whether the main window's save panel is up.
    var savesInMain: Bool {
        pending != nil && saveFromMain
    }

    /// Whether the main window says that a recording waits to be saved:
    /// it ended while the Settings window was closed.
    var showsNotice: Bool {
        pending != nil && !settingsOpen && !saveFromMain && !quitting
    }

    /// The save panel's answer.
    func exported(_ result: Result<URL, any Error>) {
        pending = nil
        saveFromMain = false
        switch result {
        case .success(let url): outcome = .saved(url.lastPathComponent)
        case .failure(let error): outcome = .saveFailed(error.localizedDescription)
        }
    }

    /// The save panel closed. Without a call of ``exported(_:)`` it was
    /// cancelled; that call may also come after this one and then wins.
    func dismissed() {
        // While the quit alert is up the save panels' bindings read false,
        // and SwiftUI may report that as a dismissal: the recording must
        // survive it, so Cancel in the alert still finds it.
        guard !quitting else { return }
        saveFromMain = false
        guard pending != nil else { return }
        pending = nil
        outcome = .discarded
    }

    /// Before the app quits (`applicationShouldTerminate`): a recording
    /// still going is ended, and one not yet saved is offered for saving,
    /// discarding or staying.
    func confirmQuit() -> NSApplication.TerminateReply {
        quitting = true
        defer { quitting = false }
        if isRecording { finish() }
        guard let file = pending else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the recording before quitting?", table: "AppSettings",
                                   comment: "Quit alert: a finished recording is not saved yet.")
        alert.informativeText = String(localized: "If you quit without saving, the recording is lost.", table: "AppSettings",
                                       comment: "Quit alert: what Discard means.")
        alert.addButton(withTitle: String(localized: "Save…", table: "AppSettings",
                                          comment: "Button: open the save panel for the recording."))
        let discard = alert.addButton(withTitle: String(localized: "Discard", table: "AppSettings",
                                                        comment: "Quit alert: quit without saving the recording."))
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", table: "AppSettings",
                                          comment: "Quit alert: do not quit."))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A save panel is open already: save there, and quit again.
            if savesInSettings || savesInMain { return .terminateCancel }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = file.name
            guard panel.runModal() == .OK, let url = panel.url else { return .terminateCancel }
            do {
                try file.data.write(to: url, options: .atomic)
            } catch {
                // Kept, to be saved elsewhere.
                NSAlert(error: error).runModal()
                return .terminateCancel
            }
            exported(.success(url))
            return .terminateNow
        case .alertSecondButtonReturn:
            pending = nil
            outcome = .discarded
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func tick() {
        let recorder = session.recorder
        seconds = min(recorder.recordedSeconds, Self.maxSeconds)
        // Full, or closed by a stop or a cut of the input.
        if recorder.isFull || !recorder.isRecording { finish() }
    }

    /// pianotunah-YYYYMMDD-HHMMSS.wav in local time, as app.js names it.
    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "pianotunah-\(f.string(from: date)).wav"
    }

    /// m:ss, as app.js shows it.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
