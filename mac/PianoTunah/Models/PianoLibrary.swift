import AppKit
import Foundation
import Observation
import PianoTunahCore

/// The saved pianos and which one is open: one JSON file per piano in
/// ~/Library/Application Support/Piano Tunah/, in the web's format
/// (docs/adr/0002). A change is saved 2.5 s after the last one, and
/// whatever is left when the app quits.
@MainActor @Observable
final class PianoLibrary {
    /// The pianos, in the order they were listed at launch (latest updated
    /// first), new and imported ones on top.
    private(set) var pianos: [Piano] = []
    /// The open piano's id.
    var selectedID: String?
    /// The last error, shown in an alert until it is dismissed.
    var errorMessage: String?

    /// The window shows the file panels and the confirmation while these
    /// are set; the menu commands set them.
    var isImporting = false
    var isExporting = false
    private(set) var exportFile: JSONFile?
    private(set) var exportName = ""
    var pendingDeleteID: String?

    /// How long after a change the piano is saved.
    static let saveDelay: Duration = .seconds(2.5)
    /// How long after a failed save it is tried again (as the web's saver).
    static let retryDelay: Duration = .seconds(10)
    /// A save has failed and has not succeeded since: the error was shown
    /// once, and saves are retried every `retryDelay`.
    @ObservationIgnored private var saveFailing = false

    @ObservationIgnored private let store: PianoStore
    @ObservationIgnored private var unsaved: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// ~/Library/Application Support/Piano Tunah/.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Piano Tunah", directoryHint: .isDirectory)
    }

    init(directory: URL = PianoLibrary.defaultDirectory) {
        store = PianoStore(directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            errorMessage = String(localized: "Could not create the folder for the pianos.")
        }
        load()
        selectedID = pianos.first?.id
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    var selected: Piano? {
        pianos.first { $0.id == selectedID }
    }

    private func load() {
        let summaries: [PianoStore.Summary]
        do {
            summaries = try store.list()
        } catch {
            errorMessage = String(localized: "Could not read the pianos.")
            return
        }
        var failed = 0
        for summary in summaries {
            if let piano = try? store.load(id: summary.id) {
                pianos.append(piano)
            } else {
                failed += 1
            }
        }
        if failed > 0 {
            errorMessage = String(localized: "\(failed) pianos could not be read.")
        }
    }

    // MARK: - Changes

    func newPiano() {
        add(Piano(name: String(localized: "New piano")))
    }

    func rename(_ id: String, to name: String) {
        change(id) { $0.name = name }
    }

    /// Changes the piano and saves it a moment later.
    func change(_ id: String, _ edit: (inout Piano) -> Void) {
        guard let i = pianos.firstIndex(where: { $0.id == id }) else { return }
        edit(&pianos[i])
        pianos[i].updatedAt = Piano.timestamp(Date())
        scheduleSave(id)
    }

    /// Asks the window to confirm deleting the open piano.
    func requestDelete() {
        pendingDeleteID = selectedID
    }

    func delete(_ id: String) {
        pendingDeleteID = nil
        do {
            try store.delete(id: id)
        } catch {
            errorMessage = String(localized: "Could not delete the piano.")
            return
        }
        unsaved.remove(id)
        guard let i = pianos.firstIndex(where: { $0.id == id }) else { return }
        pianos.remove(at: i)
        if selectedID == id {
            selectedID = pianos.indices.contains(i) ? pianos[i].id : pianos.last?.id
        }
    }

    private func add(_ piano: Piano) {
        pianos.insert(piano, at: 0)
        selectedID = piano.id
        scheduleSave(piano.id)
    }

    // MARK: - Import and export

    /// Adds the piano in the file as a new one (Piano.importing).
    func importFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let piano = try Piano.importing(
                data,
                existingIDs: Set(pianos.map(\.id)),
                untitled: String(localized: "Imported"),
                renamed: { String(localized: "\($0) (import)") }
            )
            add(piano)
        } catch {
            errorMessage = String(localized: "The file is not a piano from Piano Tunah.")
        }
    }

    /// Prepares the open piano's file and asks the window for the save panel.
    func beginExport() {
        guard let piano = selected else { return }
        do {
            exportFile = JSONFile(data: try piano.exportData())
        } catch {
            errorMessage = String(localized: "Could not export the piano.")
            return
        }
        // The panel adds the extension from the content type.
        let name = piano.exportFileName(fallback: String(localized: "piano"))
        exportName = String(name.dropLast(".json".count))
        isExporting = true
    }

    // MARK: - Saving

    private func scheduleSave(_ id: String) {
        unsaved.insert(id)
        scheduleSave(after: PianoLibrary.saveDelay)
    }

    private func scheduleSave(after delay: Duration) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves every piano changed since the last save.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        for id in unsaved {
            guard let piano = pianos.first(where: { $0.id == id }) else {
                unsaved.remove(id)
                continue
            }
            do {
                try store.save(piano)
                unsaved.remove(id)
            } catch {
                // Shown once, not on every retry; the piano stays unsaved.
                if !saveFailing {
                    errorMessage = String(localized: "Could not save “\(piano.name)”.")
                }
            }
        }
        saveFailing = !unsaved.isEmpty
        // Try again later; at quit this task never runs, but the files of
        // every piano that did save are complete.
        if saveFailing { scheduleSave(after: PianoLibrary.retryDelay) }
    }
}
