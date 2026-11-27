import Foundation

/// The saved pianos: one JSON file per piano, `<id>.json`, in one folder, as
/// the Go server keeps them in DATA_DIR (web/main.go). The app passes
/// ~/Library/Application Support/Piano Tunah/. A save writes a temporary
/// file and renames it over the old one, so a file is never half written.
/// The store does not save on its own or set `updatedAt`; the app does that.
public struct PianoStore: Sendable {
    /// The folder the files are in. It is created on the first save.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A saved piano in the list (JS: an entry of `listTunings`).
    public struct Summary: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var updatedAt: String

        public init(id: String, name: String, updatedAt: String) {
            self.id = id
            self.name = name
            self.updatedAt = updatedAt
        }
    }

    public enum StoreError: Error, Equatable {
        /// The id is not 1–64 letters, digits and "-".
        case invalidID(String)
        /// No piano is saved with this id.
        case notFound(String)
    }

    /// Whether `id` can name a file: 1 to 64 ASCII letters, digits and "-"
    /// (web/main.go: idPattern, `^[A-Za-z0-9-]{1,64}$`).
    public static func isValidID(_ id: String) -> Bool {
        let u = id.utf8
        return (1...64).contains(u.count) && u.allSatisfy { c in
            (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
                || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-")
        }
    }

    /// The saved pianos, the latest updated first. The id is the file's
    /// name; files with another name, or that are not a JSON object, are
    /// left out. A folder that does not exist yet has none.
    public func list() throws -> [Summary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var out: [Summary] = []
        for file in names {
            guard file.hasSuffix(".json") else { continue }
            let id = String(file.dropLast(5))
            guard Self.isValidID(id),
                  let data = try? Data(contentsOf: url(id)),
                  let doc = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            else { continue }
            out.append(Summary(id: id, name: doc["name"]?.string ?? "", updatedAt: doc["updatedAt"]?.string ?? ""))
        }
        return out.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }

    /// The piano saved as `id`, decoded leniently. Its id is always the
    /// file's name, as in `list()` and on the server (web/main.go refuses a
    /// document whose id is not its URL's): a file copied to a new name
    /// without its id edited is that new piano, and saving it updates that
    /// file instead of making another one.
    public func load(id: String) throws -> Piano {
        guard Self.isValidID(id) else { throw StoreError.invalidID(id) }
        guard FileManager.default.fileExists(atPath: url(id).path) else { throw StoreError.notFound(id) }
        var piano = try Piano.decode(Data(contentsOf: url(id)), makeID: { id })
        piano.id = id
        return piano
    }

    /// Saves the piano as `<id>.json`, replacing the file in one step. The
    /// revision is kept as it is (only the server raises it).
    public func save(_ piano: Piano) throws {
        guard Self.isValidID(piano.id) else { throw StoreError.invalidID(piano.id) }
        let data = try piano.jsonData()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        // Flushed (fsync) before the rename, so a crash or power cut is far
        // less likely to leave the piano's file empty. fsync does not empty
        // the drive's own cache (that needs F_FULLFSYNC) and the folder is
        // not synced, which is enough for one small file per piano.
        let handle = try FileHandle(forUpdating: tmp)
        try handle.synchronize()
        try handle.close()
        guard rename(tmp.path, url(piano.id).path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Deletes the piano saved as `id`; nothing happens if there is none.
    public func delete(id: String) throws {
        guard Self.isValidID(id) else { throw StoreError.invalidID(id) }
        guard FileManager.default.fileExists(atPath: url(id).path) else { return }
        try FileManager.default.removeItem(at: url(id))
    }

    private func url(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }
}
