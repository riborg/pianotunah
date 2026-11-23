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
        .toolbar {
            if !ToolbarProbe.on("noNewPiano") {
                ToolbarItem {
                    Button("New Piano", systemImage: "plus") { library.newPiano() }
                }
            }
        }
    }
}
