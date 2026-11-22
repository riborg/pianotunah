import SwiftUI
import UniformTypeIdentifiers

/// The main window: the pianos in the sidebar, the open one beside them.
/// It also shows the file panels, the confirmation and the errors that the
/// library asks for.
struct ContentView: View {
    @Environment(PianoLibrary.self) private var library
    @Environment(TunerModel.self) private var tuner
    @AppStorage(ColorMode.storageKey) private var colorMode = ColorMode.auto
    /// The piano's settings beside the tuner, open or closed across launches.
    @AppStorage("inspectorShown") private var inspectorShown = true

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            PianoList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let piano = library.selected {
                TunerView()
                    .navigationTitle(Binding(
                        get: { piano.name },
                        set: { library.rename(piano.id, to: $0) }
                    ))
                    .inspector(isPresented: $inspectorShown) {
                        PianoInspector()
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                inspectorShown.toggle()
                            } label: {
                                Label {
                                    Text("Piano Settings", tableName: "Inspector")
                                } icon: {
                                    Image(systemName: "sidebar.trailing")
                                }
                            }
                            .keyboardShortcut("i", modifiers: [.command, .option])
                            .help(Text("Show or hide the piano’s settings (⌥⌘I)", tableName: "Inspector"))
                        }
                    }
            } else {
                ContentUnavailableView(
                    "No piano",
                    systemImage: "pianokeys",
                    description: Text("Make a new piano or import one from the Piano menu.")
                )
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: colorMode, initial: true) { colorMode.apply() }
        // One engine per open piano: a new one when another is selected.
        .onChange(of: library.selectedID, initial: true) { tuner.open(library.selected) }
        // A new piano needs its key count and reference set first.
        .onChange(of: library.createdID) {
            if library.createdID != nil { inspectorShown = true }
        }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { library.importFile(at: url) }
        }
        .fileExporter(
            isPresented: $library.isExporting,
            document: library.exportFile,
            contentType: .json,
            defaultFilename: library.exportName
        ) { _ in }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { library.pendingDeleteID != nil },
                set: { if !$0 { library.pendingDeleteID = nil } }
            ),
            presenting: library.pendingDeleteID
        ) { id in
            Button("Delete", role: .destructive) { library.delete(id) }
        } message: { _ in
            Text("All its measurements are deleted too. This cannot be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var deleteTitle: Text {
        let name = library.pianos.first { $0.id == library.pendingDeleteID }?.name ?? ""
        return Text("Delete “\(name)”?")
    }
}
