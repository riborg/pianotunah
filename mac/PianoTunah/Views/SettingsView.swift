import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): what the web's App tab holds, one tab per
/// section. The language is not here: the app follows macOS (System
/// Settings › General › Language & Region).
///
/// Needs `TunerModel`, `InputDevices`, `RecordingModel` and `Updater` in
/// the environment.
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
            // Ended only by onCompletion or onCancellation, never by the binding.
            isPresented: Binding(get: { recording.savesInSettings }, set: { _ in }),
            document: recording.pending,
            contentTypes: [.wav],
            defaultFilename: recording.pending?.name,
            onCompletion: { recording.exported($0) },
            onCancellation: { recording.cancelled() }
        )
    }
}

/// The color mode, and whether to update to beta versions.
struct GeneralSettings: View {
    @Environment(Updater.self) private var updater
    @AppStorage(ColorMode.storageKey) private var colorMode = ColorMode.auto
    @AppStorage(Updater.betaKey) private var getsBetas = false

    var body: some View {
        Form {
            Picker("Color mode", selection: $colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            // Only in builds that update themselves, as Check for Updates….
            if updater.offersBetas {
                Section {
                    Toggle(isOn: $getsBetas) {
                        Text("Get beta versions", tableName: "Updates",
                             comment: "Settings: also update to pre-releases.")
                    }
                } header: {
                    Text("Updates", tableName: "Updates", comment: "Settings: section header.")
                } footer: {
                    Text("Beta versions come before a release and may have faults. Turned off, the beta stays until a release is newer.",
                         tableName: "Updates", comment: "Settings: under Get beta versions.")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: getsBetas) { updater.betaChanged(getsBetas) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: colorMode, initial: true) { colorMode.apply() }
    }
}
