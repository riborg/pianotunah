import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): what the web's App tab holds, one tab per
/// section. The language is not here: the app follows macOS (System
/// Settings › General › Language & Region).
///
/// Needs `TunerModel`, `InputDevices` and `RecordingModel` in the
/// environment.
struct SettingsView: View {
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        TabView {
            Tab(String(localized: "General", table: "AppSettings", comment: "Settings tab."),
                systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab(String(localized: "Microphone", table: "AppSettings", comment: "Settings tab: the audio input."),
                systemImage: "mic") {
                MicrophoneSettings()
            }
            Tab(String(localized: "Recording", table: "AppSettings", comment: "Settings tab: record the input to a WAV file."),
                systemImage: "record.circle") {
                RecordingSettings()
            }
            Tab(String(localized: "About", table: "AppSettings", comment: "Settings tab: version, links, licences."),
                systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 480)
        // Here rather than on the Recording tab, so a recording that ended
        // by itself is offered for saving on whichever tab is open. One that
        // ended while the window was closed is offered in the main window
        // (RecordingNotice), and here once the window opens.
        .onAppear { recording.settingsOpen = true }
        .onDisappear { recording.settingsOpen = false }
        .fileExporter(
            isPresented: Binding(get: { recording.savesInSettings }, set: { if !$0 { recording.dismissed() } }),
            document: recording.pending,
            contentType: .wav,
            defaultFilename: recording.pending?.name,
            onCompletion: { recording.exported($0) }
        )
    }
}

/// The color mode.
struct GeneralSettings: View {
    @AppStorage(ColorMode.storageKey) private var colorMode = ColorMode.auto

    var body: some View {
        Form {
            Picker("Color mode", selection: $colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: colorMode, initial: true) { colorMode.apply() }
    }
}
