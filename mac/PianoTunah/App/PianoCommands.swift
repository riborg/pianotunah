import SwiftUI

/// The Piano menu. The commands act on the library; the window shows the
/// file panels and the confirmation they ask for.
struct PianoCommands: Commands {
    let library: PianoLibrary

    var body: some Commands {
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
