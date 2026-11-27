import Foundation

// The saved piano document, in exactly the JSON format the web version and
// the Go server store (docs/adr/0002-mac-app-stores-web-json-locally.md).
//
// A port of web/static/js/store.js: `newTuning`, `normalize` and `duplicateTuning`,
// plus `exportTuning` and `importTuning` from app.js. The JS names are given
// in each doc comment.
//
// Decoding is lenient, as `normalize` is: every field may be missing, and
// missing fields get their defaults. Writing keeps what the file had: a field
// that has not changed since it was read is written back exactly as it was
// read, a field that was missing stays missing, and fields the app does not
// know are written back too. So a file that is read and written again comes
// back as the same JSON value, whichever version wrote it.

/// One piano as the app keeps it: its name, settings, measurements, current
/// pass and history (JS: the tuning object). The JSON field names are the
/// property names.
///
/// Make one with `init(name:now:makeID:)` (JS: `newTuning`), from a decoded
/// JSON object with `init(object:now:makeID:)` (JS: `normalize`), or with a
/// `JSONDecoder`. Write it with `jsonData()` or a `JSONEncoder`: numbers that
/// are whole are written without a fraction, as JavaScript writes them.
public struct Piano: Codable, Sendable, Equatable {
    /// The piano's id, also its file name; letters, digits and "-" (JS:
    /// `crypto.randomUUID()`).
    public var id: String
    /// The name the tuner gave the piano.
    public var name: String
    /// Free text notes about the piano.
    public var notes: String
    /// When the piano was created, as an ISO 8601 string (JS:
    /// `toISOString()`, "2026-10-19T14:57:52.939Z").
    public var createdAt: String
    /// When the piano was last saved, as an ISO 8601 string.
    public var updatedAt: String
    /// When the current pass started, as an ISO 8601 string.
    public var passStartedAt: String
    /// The server's revision, raised on every save there. The Mac app keeps
    /// it as it is, so syncing with the server stays possible.
    public var rev: Int
    /// The piano's settings, migrated from older files and laid over the
    /// defaults (JS: `{ ...DEFAULT_SETTINGS, ...migrateSettings(settings) }`).
    public var settings: Settings
    /// Fields in the settings that `Settings` does not know, written back
    /// with them.
    public var unknownSettings: [String: JSONValue]
    /// The measurement of each key in the current pass, by key (1 = A0).
    public var keys: [Int: Measurement]
    /// The measured inharmonicity B, by key.
    public var inharmonicity: [Int: Double]
    /// The partial chosen for a key, where it is not the default one.
    public var partials: [Int: Int]
    /// Where the tuning order is in the current pass.
    public var order: TuningOrder.Position
    /// Summaries of the finished passes, oldest first; at most
    /// `historyLimit`, which the engine keeps to.
    public var history: [PassSummary]
    /// Top-level fields the app does not know, written back as they were.
    public var unknownFields: [String: JSONValue]

    /// What the file had for the known fields, and what they decoded to.
    private var origin: Origin?

    /// The most passes the history keeps (JS: `.slice(-30)` in `newPass`).
    public static let historyLimit = 30

    /// A new, empty piano (JS: `newTuning`). `now` is the time for all three
    /// timestamps; `makeID` gives the id.
    public init(name: String = "", now: Date = Date(), makeID: () -> String = Piano.newID) {
        let stamp = Piano.timestamp(now)
        id = makeID()
        self.name = name
        notes = ""
        createdAt = stamp
        updatedAt = stamp
        passStartedAt = stamp
        rev = 0
        settings = .defaults
        unknownSettings = [:]
        keys = [:]
        inharmonicity = [:]
        partials = [:]
        order = .start
        history = []
        unknownFields = [:]
        origin = nil
    }

    /// A random id, as the web makes one (JS: `crypto.randomUUID()`).
    public static func newID() -> String { UUID().uuidString.lowercased() }
}

// MARK: - Measurements and passes

extension Piano {
    /// The measurement saved for a key in the current pass: Now, the latest
    /// one, and Before, the first one in the pass (JS: the entry in `keys`).
    public struct Measurement: Codable, Sendable, Equatable {
        /// Now: the key's frequency in Hz (hz) ...
        public var hz: Double
        /// ... measured on this partial (n).
        public var n: Int
        /// Before: the first measurement in the pass, in Hz (bhz), if any ...
        public var beforeHz: Double?
        /// ... measured on this partial (bn).
        public var beforeN: Int?
        /// When Now was measured, in milliseconds since 1970 (at).
        public var at: Double
        /// Whether the key was measured in a survey (mapped); nil when the
        /// file does not say.
        public var mapped: Bool?
        /// Fields in the entry that the app does not know.
        public var unknownFields: [String: JSONValue]

        public init(
            hz: Double, n: Int, beforeHz: Double? = nil, beforeN: Int? = nil, at: Double, mapped: Bool? = nil,
            unknownFields: [String: JSONValue] = [:]
        ) {
            self.hz = hz
            self.n = n
            self.beforeHz = beforeHz
            self.beforeN = beforeN
            self.at = at
            self.mapped = mapped
            self.unknownFields = unknownFields
        }

        private static let known: Set<String> = ["hz", "n", "bhz", "bn", "at", "mapped"]

        /// Decodes an entry leniently: a number field through JS `Number(x)`
        /// (missing is 0, and partial 1), mapped through JS `!!x`. Before and
        /// mapped stay nil when the entry does not have them.
        public init(object o: [String: JSONValue]) {
            hz = o["hz"].map(\.jsNumber) ?? 0
            n = o["n"].flatMap(wholeNumber) ?? 1
            beforeHz = o["bhz"].map(\.jsNumber)
            beforeN = o["bn"].flatMap(wholeNumber)
            at = o["at"].map(\.jsNumber) ?? 0
            mapped = o["mapped"].map(\.isTruthy)
            unknownFields = o.filter { !Self.known.contains($0.key) }
        }

        /// The entry as JSON; Before and mapped only when they are set.
        public var json: JSONValue {
            var o = unknownFields
            o["hz"] = number(hz)
            o["n"] = .number(Double(n))
            if let beforeHz { o["bhz"] = number(beforeHz) }
            if let beforeN { o["bn"] = .number(Double(beforeN)) }
            o["at"] = number(at)
            if let mapped { o["mapped"] = .bool(mapped) }
            return .object(o)
        }

        public init(from decoder: Decoder) throws {
            self.init(object: try [String: JSONValue](from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            try WireJSON(json).encode(to: encoder)
        }
    }

    /// The summary of a finished pass, saved to the history when a new pass
    /// starts (JS: an entry in `history`).
    public struct PassSummary: Codable, Sendable, Equatable {
        /// When the pass started and ended, as ISO 8601 strings.
        public var startedAt: String
        public var endedAt: String
        /// The reference, the frequency of A4, in the pass.
        public var refA4: Double
        /// How many keys had a measurement at the end.
        public var measured: Int
        /// The mean deviation from the target, in cents, without its sign:
        /// of the Before measurements and of the Now measurements.
        public var meanAbsBefore: Double
        public var meanAbsAfter: Double
        /// Fields in the entry that the app does not know.
        public var unknownFields: [String: JSONValue]

        public init(
            startedAt: String, endedAt: String, refA4: Double, measured: Int, meanAbsBefore: Double,
            meanAbsAfter: Double, unknownFields: [String: JSONValue] = [:]
        ) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.refA4 = refA4
            self.measured = measured
            self.meanAbsBefore = meanAbsBefore
            self.meanAbsAfter = meanAbsAfter
            self.unknownFields = unknownFields
        }

        private static let known: Set<String> = [
            "startedAt", "endedAt", "refA4", "measured", "meanAbsBefore", "meanAbsAfter",
        ]

        /// Decodes an entry leniently: a missing or non-string time is "", a
        /// number through JS `Number(x)`, missing is 0.
        public init(object o: [String: JSONValue]) {
            startedAt = o["startedAt"]?.string ?? ""
            endedAt = o["endedAt"]?.string ?? ""
            refA4 = o["refA4"].map(\.jsNumber) ?? 0
            measured = o["measured"].flatMap(wholeNumber) ?? 0
            meanAbsBefore = o["meanAbsBefore"].map(\.jsNumber) ?? 0
            meanAbsAfter = o["meanAbsAfter"].map(\.jsNumber) ?? 0
            unknownFields = o.filter { !Self.known.contains($0.key) }
        }

        /// The entry as JSON.
        public var json: JSONValue {
            var o = unknownFields
            o["startedAt"] = .string(startedAt)
            o["endedAt"] = .string(endedAt)
            o["refA4"] = number(refA4)
            o["measured"] = .number(Double(measured))
            o["meanAbsBefore"] = number(meanAbsBefore)
            o["meanAbsAfter"] = number(meanAbsAfter)
            return .object(o)
        }

        public init(from decoder: Decoder) throws {
            self.init(object: try [String: JSONValue](from: decoder))
        }

        public func encode(to encoder: Encoder) throws {
            try WireJSON(json).encode(to: encoder)
        }
    }
}

// MARK: - Reading

extension Piano {
    /// The fields of the document the app knows; every other field is kept
    /// in `unknownFields`.
    static let knownFields: [String] = [
        "id", "name", "notes", "createdAt", "updatedAt", "settings", "inharmonicity", "partials", "keys",
        "passStartedAt", "order", "rev", "history",
    ]

    /// The fields of the settings that `Settings` holds.
    static let settingsFields = Set(settingsJSON(.defaults).keys)

    /// Fields that `normalize` makes up when they are missing.
    private static let generated: Set<String> = ["id", "createdAt", "updatedAt", "passStartedAt"]

    /// A piano from a saved document, leniently (JS: `normalize`). Missing
    /// fields get their defaults: a new id from `makeID` and `now` for the
    /// timestamps, as `newTuning` gives them. The settings go through
    /// `migrateSettings` and over the defaults. Where JS would keep a value
    /// of the wrong type as it is, the typed field takes its default (or, for
    /// numbers, JS `Number(x)`); the value itself is still written back as
    /// long as the field is not changed. Two exceptions:
    /// - an id or a timestamp (createdAt, updatedAt, passStartedAt) that is
    ///   not a string counts as missing, so a new one is made and written;
    /// - in `keys`, `inharmonicity` and `partials`, an entry that cannot be
    ///   read (a key that is not a whole number, an entry of the wrong kind)
    ///   is written back only while that whole field is unchanged, and keys
    ///   such as "05" and "5" are the same key, the last one read winning.
    ///   The web keeps such entries; neither the web nor the app writes them.
    public init(object: [String: JSONValue], now: Date = Date(), makeID: () -> String = Piano.newID) {
        var made: Set<String> = []
        func text(_ key: String) -> String? { object[key]?.string }
        func stamp(_ key: String) -> String {
            if let s = text(key) { return s }
            made.insert(key)
            return Piano.timestamp(now)
        }

        if let s = text("id") {
            id = s
        } else {
            id = makeID()
            made.insert("id")
        }
        name = text("name") ?? ""
        notes = text("notes") ?? ""
        createdAt = stamp("createdAt")
        updatedAt = stamp("updatedAt")
        passStartedAt = stamp("passStartedAt")
        // As the server reads it: a number, truncated; anything else is 0.
        rev = object["rev"]?.number.flatMap { $0.isFinite && abs($0) < 0x1p53 ? Int($0) : nil } ?? 0

        let loose = migrateSettings(object["settings"]?.object ?? [:])
        settings = Settings(merging: loose)
        unknownSettings = loose.filter { !Piano.settingsFields.contains($0.key) }

        func byKey<V>(_ field: String, _ value: (JSONValue) -> V?) -> [Int: V] {
            var out: [Int: V] = [:]
            for (k, v) in object[field]?.object ?? [:] {
                if let key = Int(k), let x = value(v) { out[key] = x }
            }
            return out
        }
        keys = byKey("keys") { $0.object.map(Measurement.init(object:)) }
        inharmonicity = byKey("inharmonicity") { v in
            let b = v.jsNumber
            return b.isNaN ? nil : b
        }
        partials = byKey("partials", wholeNumber)
        order = position(object["order"])
        if case .array(let a)? = object["history"] {
            history = a.compactMap { $0.object.map(PassSummary.init(object:)) }
        } else {
            history = []
        }

        let known = Set(Piano.knownFields)
        unknownFields = object.filter { !known.contains($0.key) }
        origin = nil
        let fields = knownJSON()
        origin = Origin(
            raw: object.filter { known.contains($0.key) },
            baseline: fields.filter { !made.contains($0.key) }
        )
    }

    /// Decodes a document leniently; see `init(object:now:makeID:)`. Throws
    /// if the data is not a JSON object.
    public static func decode(_ data: Data, now: Date = Date(), makeID: () -> String = Piano.newID) throws -> Piano {
        Piano(object: try JSONDecoder().decode([String: JSONValue].self, from: data), now: now, makeID: makeID)
    }

    /// Decodes any JSON object, leniently, with a new id and the current time
    /// where they are missing; see `init(object:now:makeID:)`.
    public init(from decoder: Decoder) throws {
        self.init(object: try [String: JSONValue](from: decoder))
    }
}

// MARK: - Writing

extension Piano {
    /// The document as it is written: each known field as it was read if it
    /// has not changed since, and left out if it was missing then; otherwise
    /// its current value. Unknown fields are written as they were read.
    public var json: JSONValue {
        var out = unknownFields
        for (key, value) in knownJSON() {
            if let origin, let before = origin.baseline[key], before == value {
                out[key] = origin.raw[key]
            } else {
                out[key] = value
            }
        }
        return .object(out)
    }

    /// The document with every field filled in from the current values, as
    /// the web holds a piano after `normalize`. Unknown fields are included.
    public var normalizedJSON: JSONValue {
        .object(unknownFields.merging(knownJSON()) { _, known in known })
    }

    /// The document as JSON text (`json`), keys sorted, whole numbers
    /// without a fraction. Compact, as the server writes files, or indented.
    public func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireJSON(json))
    }

    public func encode(to encoder: Encoder) throws {
        try WireJSON(json).encode(to: encoder)
    }

    /// The known fields as JSON, from the current values.
    private func knownJSON() -> [String: JSONValue] {
        func map<V>(_ d: [Int: V], _ f: (V) -> JSONValue) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: d.map { (String($0.key), f($0.value)) }))
        }
        return [
            "id": .string(id),
            "name": .string(name),
            "notes": .string(notes),
            "createdAt": .string(createdAt),
            "updatedAt": .string(updatedAt),
            "settings": .object(unknownSettings.merging(settingsJSON(settings)) { _, known in known }),
            "inharmonicity": map(inharmonicity, number),
            "partials": map(partials) { .number(Double($0)) },
            "keys": map(keys, \.json),
            "passStartedAt": .string(passStartedAt),
            "order": .object(["step": .number(Double(order.step)), "i": .number(Double(order.index))]),
            "rev": .number(Double(rev)),
            "history": .array(history.map(\.json)),
        ]
    }

    /// What the file had for the known fields (raw), and their JSON as
    /// decoded (baseline), without the fields that were made up. A field
    /// whose JSON is still its baseline is written as raw.
    private struct Origin: Sendable, Equatable {
        var raw: [String: JSONValue]
        var baseline: [String: JSONValue]
    }
}

// MARK: - Copies, export and import

/// Why a file could not be imported.
public enum PianoImportError: Error, Equatable {
    /// The file is not JSON.
    case notJSON
    /// The file has no settings, so it is not a piano (JS: msg.importNoSettings).
    case noSettings
}

extension Piano {
    /// A copy of the piano with a new id, the name given, created and
    /// updated now, at revision 0 (JS: `duplicateTuning`). The rest, the
    /// current pass included, is kept.
    public func duplicate(name: String, now: Date = Date(), makeID: () -> String = Piano.newID) -> Piano {
        var copy = self
        let stamp = Piano.timestamp(now)
        copy.id = makeID()
        copy.name = name
        copy.createdAt = stamp
        copy.updatedAt = stamp
        copy.rev = 0
        return copy
    }

    /// The file to export: the document, indented (JS: `exportTuning`).
    public func exportData() throws -> Data {
        try jsonData(pretty: true)
    }

    /// The export's file name: the name, or `fallback` without one, with
    /// each run of characters other than letters, digits, "_" and "-" made
    /// "_", plus ".json" (JS: `exportTuning`; the fallback is name.file).
    public func exportFileName(fallback: String = "piano") -> String {
        var out = ""
        var inRun = false
        for c in (name.isEmpty ? fallback : name).unicodeScalars {
            let keep: Bool = switch c.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: c == "_" || c == "-"
            }
            if keep {
                out.unicodeScalars.append(c)
                inRun = false
            } else if !inRun {
                out += "_"
                inRun = true
            }
        }
        return out + ".json"
    }

    /// A piano from an exported file, as a new piano (JS: `importTuning`):
    /// decoded leniently, then given a new id, created and updated now, at
    /// revision 0. It keeps its name, or gets `untitled` (name.imported)
    /// without one; if a piano with its id is among `existingIDs`, the name
    /// goes through `renamed` (name.import), so the two can be told apart.
    public static func importing(
        _ data: Data,
        existingIDs: Set<String> = [],
        untitled: String = "Imported",
        renamed: (String) -> String = { "\($0) (import)" },
        now: Date = Date(),
        makeID: () -> String = Piano.newID
    ) throws -> Piano {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw PianoImportError.notJSON }
        guard let object = value.object, object["settings"]?.isTruthy == true else {
            throw PianoImportError.noSettings
        }
        let exists = object["id"]?.string.map(existingIDs.contains) ?? false
        let name = object["name"].flatMap { $0.isTruthy ? $0.string : nil } ?? untitled
        // The id is replaced, so none is made for a file without one.
        return Piano(object: object, now: now, makeID: { "" })
            .duplicate(name: exists ? renamed(name) : name, now: now, makeID: makeID)
    }
}

// MARK: - Timestamps

extension Piano {
    /// `date` as JS `toISOString()` gives it: UTC, to the millisecond,
    /// "2026-10-19T14:57:52.939Z".
    public static func timestamp(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (dayCount, msOfDay) = ms.quotientAndRemainder(dividingBy: 86_400_000)
        let (days, time) = msOfDay < 0 ? (dayCount - 1, msOfDay + 86_400_000) : (dayCount, msOfDay)
        // Days since 1970 to a Gregorian date (Howard Hinnant's civil_from_days).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)

        func pad(_ x: Int64, _ width: Int) -> String {
            let s = String(x)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let y = (0...9999).contains(year) ? pad(year, 4) : (year < 0 ? "-" : "+") + pad(abs(year), 6)
        return "\(y)-\(pad(month, 2))-\(pad(day, 2))T\(pad(time / 3_600_000, 2)):\(pad(time / 60000 % 60, 2))"
            + ":\(pad(time / 1000 % 60, 2)).\(pad(time % 1000, 3))Z"
    }
}

// MARK: - JSON helpers

/// A number as JSON; NaN and ±∞, which JSON cannot hold, are null, as JS
/// `JSON.stringify` writes them.
private func number(_ x: Double) -> JSONValue { x.isFinite ? .number(x) : .null }

/// JS `Number(x)` if it is a whole number that fits in an Int, else nil.
private func wholeNumber(_ v: JSONValue) -> Int? {
    let x = v.jsNumber
    return x.isFinite && x.rounded() == x && abs(x) < 0x1p53 ? Int(x) : nil
}

/// A saved tuning-order position, read as `TuningOrder.Position` decodes one:
/// each field through JS `Number(x) || 0`, rounded down; not an object is the
/// start.
private func position(_ v: JSONValue?) -> TuningOrder.Position {
    guard let o = v?.object else { return .start }
    func field(_ key: String) -> Int {
        let x = o[key]?.jsNumber ?? 0
        if x.isNaN { return 0 }
        return Int(min(max(x, -0x1p53), 0x1p53).rounded(.down))
    }
    return TuningOrder.Position(step: field("step"), index: field("i"))
}

/// Settings as their JSON object, every field (JS: the settings object).
func settingsJSON(_ s: Settings) -> [String: JSONValue] {
    [
        "refA4": number(s.refA4),
        "temperament": .string(s.temperament),
        "root": .number(Double(s.root)),
        "stretch": .string(s.stretch),
        "midOctave": .string(s.midOctave),
        "trebleOctave": .string(s.trebleOctave),
        "bassOctave": .string(s.bassOctave),
        "extraTreble": number(s.extraTreble),
        "extraBass": number(s.extraBass),
        "pianoKind": .string(s.pianoKind),
        "sizeCm": number(s.sizeCm),
        "keyCount": .number(Double(s.keyCount)),
        "overpull": number(s.overpull),
        "tolerance": number(s.tolerance),
        "twoStringsTo": .number(Double(s.twoStringsTo)),
        "oneStringTo": .number(Double(s.oneStringTo)),
        "unisons": .string(s.unisons),
    ]
}

/// A JSON value encoded the way JavaScript writes it: a whole number without
/// a fraction (440, not 440.0, and a millisecond time in full), whatever the
/// encoder does with a Double, and NaN and ±∞ as null.
struct WireJSON: Encodable {
    let value: JSONValue

    init(_ value: JSONValue) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let x):
            if !x.isFinite {
                try c.encodeNil()
            } else if x.rounded() == x && abs(x) <= 0x1p53 {
                try c.encode(Int64(x))
            } else {
                try c.encode(x)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a.map(WireJSON.init))
        case .object(let o): try c.encode(o.mapValues(WireJSON.init))
        }
    }
}
