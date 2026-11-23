import SwiftUI
import UniformTypeIdentifiers

/// At the bottom of the main window: a recording that ended while the
/// Settings window was closed (full, the microphone stopped, the input cut)
/// waits to be saved; Save… opens the save panel here. Its own view, so its
/// save panel is not one of ContentView's (the piano's export).
///
/// Needs `RecordingModel` in the environment.
struct RecordingNotice: View {
    @Environment(RecordingModel.self) private var recording

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .allowsHitTesting(false)
            if recording.showsNotice {
                HStack(spacing: 10) {
                    Label {
                        Text("Recording finished", tableName: "AppSettings",
                             comment: "Main window: a recording ended while Settings was closed and is not saved yet.")
                    } icon: {
                        Image(systemName: "record.circle")
                    }
                    Button {
                        recording.saveFromMain = true
                    } label: {
                        Text("Save…", tableName: "AppSettings",
                             comment: "Button: open the save panel for the recording.")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 1)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: recording.showsNotice)
        .fileExporter(
            // Ended only by onCompletion or onCancellation, never by the binding.
            isPresented: Binding(get: { recording.savesInMain }, set: { _ in }),
            document: recording.pending,
            contentTypes: [.wav],
            defaultFilename: recording.pending?.name,
            onCompletion: { recording.exported($0) },
            onCancellation: { recording.cancelled() }
        )
    }
}
