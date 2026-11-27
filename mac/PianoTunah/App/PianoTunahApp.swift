import AppKit
import PianoTunahAudio
import SwiftUI

// PianoTunahCore is not imported here: its `Settings` (a piano's settings)
// would hide SwiftUI's Settings scene.

/// The app: one main window with the pianos, the Settings window (⌘,) and
/// the help window.
@main
struct PianoTunahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library: PianoLibrary
    @State private var tuner: TunerModel
    @State private var updater = Updater()
    /// The inputs for the Settings picker; one for the app's life, as its
    /// Core Audio listener is never removed.
    @State private var inputs = InputDevices()
    @State private var recording: RecordingModel

    init() {
        let library = PianoLibrary()
        _library = State(initialValue: library)
        let tuner = TunerModel(library: library)
        tuner.restoreInput()
        _tuner = State(initialValue: tuner)
        let recording = RecordingModel(session: tuner.session)
        _recording = State(initialValue: recording)
        AppDelegate.recording = recording
    }

    var body: some Scene {
        Window("Piano Tunah", id: "main") {
            ContentView()
                .environment(library)
                .environment(tuner)
                .environment(recording)
        }
        // Room at first launch for the sidebar, the tuner and the inspector.
        .defaultSize(width: 1280, height: 820)
        .commands {
            UpdateCommands(updater: updater)
            PianoCommands(library: library)
            HelpCommands()
        }

        SwiftUI.Settings {
            SettingsView()
                .environment(tuner)
                .environment(updater)
                .environment(inputs)
                .environment(recording)
        }

        Window(Text("Piano Tunah Help", tableName: "AppSettings", comment: "Help menu item; also the help window's title."),
               id: HelpCommands.windowID) {
            HelpView()
        }
        .defaultSize(width: 620, height: 720)
    }
}

/// Asks before quitting with a recording that is not saved.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's recording, set as the app starts.
    static var recording: RecordingModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.recording?.confirmQuit() ?? .terminateNow
    }
}
