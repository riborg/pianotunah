import SwiftUI

/// The sidebar: the saved pianos. Selecting one opens it.
struct PianoList: View {
    @Environment(PianoLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selectedID) {
            ForEach(library.pianos, id: \.id) { piano in
                Text(piano.name.isEmpty ? String(localized: "Untitled") : piano.name)
                    .contextMenu {
                        Button("Delete…") {
                            library.pendingDeleteID = piano.id
                        }
                    }
            }
        }
        // New Piano sits under the list, not in the toolbar. As a sidebar
        // toolbar item it made the app too slow to use from launch on
        // macOS 27, with a flickering » and the main thread busy in toolbar
        // layout; taking it out, and only that, made the app fast again.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("New Piano", systemImage: "plus") { library.newPiano() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(Text("New Piano"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
