import PianoTunahAudio
import SwiftUI

// PianoTunahCore is not imported here: its `Settings` (a piano's settings)
// would hide SwiftUI's Settings scene.

/// The app: one main window with the pianos, the Settings window (⌘,) and
/// the help window.
@main
struct PianoTunahApp: App {
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
        _recording = State(initialValue: RecordingModel(session: tuner.session))
    }

    var body: some Scene {
        Window("Piano Tunah", id: "main") {
            ContentView()
                .environment(library)
                .environment(tuner)
        }
        .commands {
            UpdateCommands(updater: updater)
            PianoCommands(library: library)
            HelpCommands()
        }

        SwiftUI.Settings {
            SettingsView()
                .environment(tuner)
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
