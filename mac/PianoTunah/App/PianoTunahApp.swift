import SwiftUI

// PianoTunahCore is not imported here: its `Settings` (a piano's settings)
// would hide SwiftUI's Settings scene.

/// The app: one main window with the pianos, and the Settings window (⌘,).
@main
struct PianoTunahApp: App {
    @State private var library = PianoLibrary()

    var body: some Scene {
        Window("Piano Tunah", id: "main") {
            ContentView()
                .environment(library)
        }
        .commands {
            PianoCommands(library: library)
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }
}
