import SwiftUI

/// The sidebar: the saved pianos. Selecting one opens it.
struct PianoList: View {
    @Environment(PianoLibrary.self) private var library

    var body: some View {
        // A click on the empty space under the pianos (or ⌘-click on the
        // open one) clears a List's selection. Passed on, that closed the
        // tuner mid-tuning and its engine with it, a survey under way too,
        // and showed "No piano" though there are pianos. Only another piano
        // changes the selection here; deleting the last one clears it in
        // the library.
        List(selection: Binding(
            get: { library.selectedID },
            set: { if let id = $0 { library.selectedID = id } }
        )) {
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
