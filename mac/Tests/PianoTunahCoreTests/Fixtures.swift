import Foundation

/// A JSON value as web/test/fixtures.mjs writes it. Numbers JSON cannot hold are
/// strings there: "NaN", "Infinity", "-Infinity" and "-0"; `double` reads
/// those back.
enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var isNull: Bool { self == .null }

    var double: Double? {
        switch self {
        case .number(let x): x
        case .string("NaN"): .nan
        case .string("Infinity"): .infinity
        case .string("-Infinity"): -.infinity
        case .string("-0"): -0.0
        default: nil
        }
    }

    var int: Int? { double.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The elements as numbers; nil if any is not one.
    var doubles: [Double]? {
        guard let a = array else { return nil }
        let xs = a.compactMap(\.double)
        return xs.count == a.count ? xs : nil
    }
}

extension JSON: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let x = try? c.decode(Double.self) {
            self = .number(x)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }
}

enum FixtureError: Error {
    case missing(String)
    case badLength(String, Int)
}

/// The files in Fixtures/, written by web/test/fixtures.mjs.
enum Fixtures {
    static var directory: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
                throw FixtureError.missing("Fixtures")
            }
            return url
        }
    }

    static func url(_ path: String) throws -> URL {
        try directory.appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    /// A JSON fixture, such as "theory-targets.json".
    static func json(_ path: String) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data(path))
    }

    /// Sound stored as little-endian Float32, such as "dsp/tone-48000-k49.f32".
    static func f32(_ path: String) throws -> [Float] {
        let d = try data(path)
        guard d.count % 4 == 0 else { throw FixtureError.badLength(path, d.count) }
        return d.withUnsafeBytes { raw in
            (0..<d.count / 4).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
    }

    /// Every file, as paths relative to Fixtures/, sorted.
    static func allFiles() throws -> [String] {
        let root = try directory.standardizedFileURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw FixtureError.missing(root.path)
        }
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            out.append(String(path.dropFirst(root.path.count + 1)))
        }
        return out.sorted()
    }
}
