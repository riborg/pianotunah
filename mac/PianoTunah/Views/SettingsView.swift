import SwiftUI

/// The Settings window (⌘,). For now only the color mode; the microphone
/// and recording come with the audio.
struct SettingsView: View {
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
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: colorMode, initial: true) { colorMode.apply() }
    }
}
