import SwiftUI
import UniformTypeIdentifiers

/// The main window: the pianos in the sidebar, the open one beside them.
/// It also shows the file panels, the confirmation and the errors that the
/// library asks for, and a recording that waits to be saved
/// (RecordingNotice). Needs `RecordingModel` in the environment too.
struct ContentView: View {
    @Environment(PianoLibrary.self) private var library
    @Environment(TunerModel.self) private var tuner
    @AppStorage(ColorMode.storageKey) private var colorMode = ColorMode.auto
    /// The piano's settings beside the tuner, open or closed across launches.
    @AppStorage(Self.inspectorShownKey) private var inspectorShown = true
    /// The UserDefaults key of the inspector's state; the View menu's
    /// Show/Hide Piano Settings (PianoCommands) toggles it too.
    static let inspectorShownKey = "inspectorShown"
    /// The narrowest the tuner gets: the dial, the header's controls and the
    /// title above them.
    static let tunerMinWidth: CGFloat = 440

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            PianoList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let piano = library.selected {
                TunerView()
                    // The tuner keeps room of its own beside the sidebar and
                    // the inspector, so the window grows for them instead.
                    .frame(minWidth: Self.tunerMinWidth)
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
        .overlay { RecordingNotice() }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: colorMode, initial: true) { colorMode.apply() }
        // One engine per open piano: a new one when another is selected.
        .onChange(of: library.selectedID, initial: true) { tuner.open(library.selected) }
        // A new piano needs its key count and reference set first.
        .onChange(of: library.createdID) {
            if library.createdID != nil { inspectorShown = true }
        }
        // The import panel on a view of its own: SwiftUI has presented only
        // one of a fileImporter and a fileExporter on the same view in
        // earlier versions.
        .background {
            Color.clear.fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { library.importFile(at: url) }
            }
        }
        .fileExporter(
            isPresented: $library.isExporting,
            document: library.exportFile,
            contentType: .json,
            defaultFilename: library.exportName
        ) { result in
            // A write that fails (a full disk, a volume gone) closed the panel
            // without a word, as if the piano were saved. Cancel is no error.
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                library.errorMessage = String(localized: "Could not export the piano.")
            }
        }
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
