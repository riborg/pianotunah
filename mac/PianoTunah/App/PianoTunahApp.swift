import SwiftUI

// PianoTunahCore is not imported here: its `Settings` (a piano's settings)
// would hide SwiftUI's Settings scene.

/// The app: one main window with the pianos, and the Settings window (⌘,).
@main
struct PianoTunahApp: App {
    @State private var library: PianoLibrary
    @State private var tuner: TunerModel

    init() {
        let library = PianoLibrary()
        _library = State(initialValue: library)
        _tuner = State(initialValue: TunerModel(library: library))
    }

    var body: some Scene {
        Window("Piano Tunah", id: "main") {
            ContentView()
                .environment(library)
                .environment(tuner)
        }
        .commands {
            PianoCommands(library: library)
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }
}
