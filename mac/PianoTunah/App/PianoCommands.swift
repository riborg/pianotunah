import SwiftUI

/// The Piano menu, and Show/Hide Piano Settings in the View menu. The
/// commands act on the library; the window shows the file panels and the
/// confirmation they ask for.
struct PianoCommands: Commands {
    let library: PianoLibrary
    /// The inspector beside the tuner, the same setting the window reads.
    @AppStorage(ContentView.inspectorShownKey) private var inspectorShown = true

    /// Written out: the private @AppStorage makes the synthesized one private.
    init(library: PianoLibrary) {
        self.library = library
    }

    var body: some Commands {
        // ⌥⌘I lives here rather than on the toolbar button, so it works
        // with the toolbar hidden or the button out of sight.
        CommandGroup(after: .sidebar) {
            Button {
                inspectorShown.toggle()
            } label: {
                inspectorShown
                    ? Text("Hide Piano Settings", tableName: "Inspector")
                    : Text("Show Piano Settings", tableName: "Inspector")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(library.selected == nil)
        }
        CommandMenu("Piano") {
            Button("New Piano") { library.newPiano() }
                .keyboardShortcut("n")
            Button {
                library.duplicateSelected()
            } label: {
                Text("Duplicate Piano", tableName: "Inspector")
            }
            .keyboardShortcut("d")
            .disabled(library.selected == nil)
            Divider()
            Button("Import…") { library.isImporting = true }
                .keyboardShortcut("o")
            Button("Export…") { library.beginExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.selected == nil)
            Divider()
            Button("Delete…") { library.requestDelete() }
                .disabled(library.selected == nil)
        }
    }
}
