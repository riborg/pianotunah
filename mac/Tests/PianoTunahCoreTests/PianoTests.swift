import Foundation
import Testing
@testable import PianoTunahCore

// Piano.swift and PianoStore.swift against piano/{a,b,c}.input.json and
// .normalized.json from test/fixtures.mjs.

private let pianos = ["a", "b", "c"]

/// A fixed time, 2025-01-02T03:04:05.006Z.
private let fixedNow = Date(timeIntervalSince1970: 1_735_787_045.006)

private func input(_ which: String) throws -> [String: JSONValue] {
    try #require(try Fixtures.json("piano/\(which).input.json").value.object)
}

private func decoded(_ which: String) throws -> Piano {
    try JSONDecoder().decode(Piano.self, from: Fixtures.data("piano/\(which).input.json"))
}

/// Parses JSON text the way the fixtures are read, numbers by value.
private func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSON.self, from: data).value
}

/// Whether the text has a number written with a fraction of zero, such as
/// 440.0 or 1.795348434959e+12.
private func hasWholeNumberWithFraction(_ data: Data) throws -> Bool {
    let text = try #require(String(data: data, encoding: .utf8))
    return text.range(of: #"[0-9]\.0+([,}\]\s]|$)|[0-9]e\+"#, options: .regularExpression) != nil
}

// MARK: - normalize

@Test(arguments: pianos)
func decodingGivesWhatNormalizeGives(_ which: String) throws {
    let fixture = try Fixtures.json("piano/\(which).normalized.json")
    let piano = Piano(object: try input(which), now: fixedNow, makeID: { "unused" })
    #expect(piano.normalizedJSON == fixture["normalized"].value, "piano \(which)")
    #expect(try decoded(which) == piano)

    let settings = try #require(fixture["normalized"]["settings"].value.object)
    #expect(piano.settings == Settings(merging: settings))
    let raw = try input(which)["settings"]?.object ?? [:]
    #expect(JSONValue.object(migrateSettings(raw)) == fixture["migratedSettings"].value)
}

@Test func theFixturesHaveTheirFields() throws {
    let a = try decoded("a")
    #expect(a.rev == 3618)
    #expect(a.order == TuningOrder.Position(step: 9, index: 60))
    #expect(a.settings.unisons == "dsu" && a.settings.keyCount == 85)
    #expect(a.keys[1]?.n == 6 && a.keys[1]?.beforeN == 6 && a.keys[1]?.mapped == true)
    #expect(a.keys[1]?.at == 1_795_348_434_959)
    #expect(a.inharmonicity[85] == 0.009781 && a.inharmonicity[84] == nil)

    let b = try decoded("b")
    #expect(b.settings.unisons == "one")
    #expect(b.history.count == 1)
    #expect(b.history.first?.measured == 15 && b.history.first?.startedAt == "2026-10-19T18:03:36.934Z")

    let c = try decoded("c")
    #expect(c.settings.pianoKind == "grand" && c.settings.sizeCm == 274 && c.settings.refA4 == 442)
    #expect(c.unknownSettings.isEmpty)
    #expect(c.notes == "" && c.rev == 0 && c.order == .start && c.history.isEmpty && c.partials.isEmpty)
    #expect(c.keys[49] == Piano.Measurement(hz: 441.3, n: 1, at: 1_735_787_045_006))
    #expect(c.unknownFields["extra"] == ["kept": true, "list": [1, "two", nil]])
}

@Test func missingFieldsGetTheirDefaults() {
    var ids = 0
    let piano = Piano(object: [:], now: fixedNow, makeID: { ids += 1; return "new-id" })
    #expect(ids == 1)
    #expect(piano.id == "new-id")
    #expect(piano.createdAt == "2025-01-02T03:04:05.006Z")
    #expect(piano.updatedAt == piano.createdAt && piano.passStartedAt == piano.createdAt)
    #expect(piano.normalizedJSON == Piano(now: fixedNow, makeID: { "new-id" }).normalizedJSON)
    // What normalize made up is written; the defaults stay out, as they were.
    let written = piano.json
    #expect(written["id"] == "new-id" && written["createdAt"] == "2025-01-02T03:04:05.006Z")
    #expect(written["passStartedAt"] != nil && written["updatedAt"] != nil)
    #expect(written["notes"] == nil && written["rev"] == nil && written["settings"] == nil)
}

@Test func valuesOfTheWrongTypeAreReadLeniently() {
    let piano = Piano(object: [
        "id": "x", "name": 5, "rev": "7",
        "settings": ["refA4": "442", "root": 2.5, "pianoType": "spinet"],
        "keys": ["3": ["hz": "110.5", "n": 2, "mapped": 1], "x": ["hz": 1], "4": "nope"],
        "inharmonicity": ["2": 3e-4, "5": "junk"],
        "partials": ["7": 3, "8": 1.5],
        "order": ["step": "4", "i": nil],
        "history": [["measured": 3], 7],
    ], now: fixedNow)
    #expect(piano.name == "" && piano.rev == 0)
    #expect(piano.settings.refA4 == 442 && piano.settings.root == 0)
    #expect(piano.settings.pianoKind == "upright" && piano.settings.sizeCm == 100)
    #expect(piano.keys == [3: Piano.Measurement(hz: 110.5, n: 2, at: 0, mapped: true)])
    #expect(piano.inharmonicity == [2: 3e-4])
    #expect(piano.partials == [7: 3])
    #expect(piano.order == TuningOrder.Position(step: 4, index: 0))
    #expect(piano.history.count == 1 && piano.history[0].measured == 3)
    // Unchanged, they are written back as they were.
    #expect(piano.json["name"] == 5 && piano.json["keys"]?["4"] == "nope")
}

// MARK: - Round trip

@Test(arguments: pianos)
func decodingAndEncodingGivesTheInputBack(_ which: String) throws {
    let data = try Fixtures.data("piano/\(which).input.json")
    let want = try parse(data)
    let piano = try decoded(which)

    let encoded = try JSONEncoder().encode(piano)
    #expect(try parse(encoded) == want, "JSONEncoder, piano \(which)")
    #expect(try !hasWholeNumberWithFraction(encoded), "piano \(which)")

    let written = try piano.jsonData()
    #expect(try parse(written) == want, "jsonData, piano \(which)")
    #expect(try !hasWholeNumberWithFraction(written))
    #expect(try parse(piano.jsonData(pretty: true)) == want)

    // And again from what was written.
    #expect(try parse(Piano.decode(written).jsonData()) == want)
}

@Test func wholeNumbersAreWrittenWithoutAFraction() throws {
    var a = try decoded("a")
    let text = try #require(String(data: try a.jsonData(), encoding: .utf8))
    #expect(text.contains(#""rev":3618"#))
    #expect(text.contains(#""at":1795348434959"#))
    #expect(text.contains(#""refA4":440,"#))
    #expect(text.contains(#""keyCount":85,"#))
    #expect(text.contains(#""order":{"i":60,"step":9}"#))

    // Changed fields are written from the typed values; the same holds there.
    a.settings.refA4 = 441
    a.keys[1]?.at = 1_795_348_500_000
    a.rev += 1
    a.history.append(Piano.PassSummary(
        startedAt: a.passStartedAt, endedAt: a.updatedAt, refA4: 441, measured: 85, meanAbsBefore: 2, meanAbsAfter: 0.5))
    let data = try JSONEncoder().encode(a)
    let changed = try #require(String(data: data, encoding: .utf8))
    #expect(try !hasWholeNumberWithFraction(data))
    #expect(changed.contains(#""refA4":441"#))
    #expect(changed.contains(#""at":1795348500000"#))
    #expect(changed.contains(#""rev":3619"#))
    #expect(changed.contains(#""meanAbsAfter":0.5"#))
}

@Test func onlyChangedFieldsAreWrittenFromTheirValues() throws {
    var b = try decoded("b")
    // Written as it was: no unisons, which this piano was saved without.
    #expect(b.json["settings"]?["unisons"] == nil)
    b.settings.unisons = "dsu"
    #expect(b.json["settings"]?["unisons"] == "dsu")
    #expect(b.json["settings"]?["keyCount"] == 88)
    // Set back, the settings are written as they were read.
    b.settings.unisons = "one"
    #expect(b.json["settings"] == (try input("b"))["settings"])

    var c = try decoded("c")
    #expect(c.json["settings"]?["pianoType"] == "concert")
    c.settings.tolerance = 3
    let settings = try #require(c.json["settings"]?.object)
    #expect(settings["pianoType"] == nil && settings["pianoKind"] == "grand" && settings["tolerance"] == 3)
    #expect(c.json["notes"] == nil)
    c.notes = "Felts worn"
    #expect(c.json["notes"] == "Felts worn")
}

// MARK: - Unknown fields

@Test func unknownFieldsSurviveChanges() throws {
    var c = try decoded("c")
    c.name = "Renamed"
    c.settings.refA4 = 440
    c.keys[49]?.hz = 440.1
    #expect(c.json["extra"] == ["kept": true, "list": [1, "two", nil]])
    #expect(c.json["name"] == "Renamed")

    var piano = Piano(object: [
        "id": "u",
        "future": ["a": 1],
        "settings": ["refA4": 440, "glide": "slow"],
        "keys": ["40": ["hz": 220, "n": 1, "at": 1, "quality": 0.9]],
        "history": [["startedAt": "s", "endedAt": "e", "refA4": 440, "measured": 1, "meanAbsBefore": 1,
                     "meanAbsAfter": 1, "note": "first"]],
    ])
    #expect(piano.unknownSettings == ["glide": "slow"])
    #expect(piano.keys[40]?.unknownFields == ["quality": 0.9])
    piano.settings.refA4 = 442
    piano.keys[40]?.hz = 221
    piano.history.append(piano.history[0])
    piano.history[1].unknownFields = [:]
    let out = try parse(piano.jsonData())
    #expect(out["future"] == ["a": 1])
    #expect(out["settings"]?["glide"] == "slow" && out["settings"]?["refA4"] == 442)
    #expect(out["keys"]?["40"] == ["hz": 221, "n": 1, "at": 1, "quality": 0.9])
    #expect(out["history"] == [
        ["startedAt": "s", "endedAt": "e", "refA4": 440, "measured": 1, "meanAbsBefore": 1, "meanAbsAfter": 1, "note": "first"],
        ["startedAt": "s", "endedAt": "e", "refA4": 440, "measured": 1, "meanAbsBefore": 1, "meanAbsAfter": 1],
    ])
}

@Test func settingsJSONCoversEverySetting() throws {
    let encoded = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(Settings.defaults))
    #expect(Set(encoded.keys) == Piano.settingsFields)
    #expect(Settings(merging: settingsJSON(.defaults)) == .defaults)
}

// MARK: - New pianos, copies, export and import

@Test func timestampsAreThoseOfToISOString() {
    func at(_ ms: Double) -> String { Piano.timestamp(Date(timeIntervalSince1970: ms / 1000)) }
    #expect(at(0) == "1970-01-01T00:00:00.000Z")
    #expect(at(1_735_787_045_006) == "2025-01-02T03:04:05.006Z")
    #expect(at(1_795_348_434_959) == "2026-11-22T11:53:54.959Z")
    #expect(at(951_782_400_000) == "2000-02-29T00:00:00.000Z")
    #expect(at(-1) == "1969-12-31T23:59:59.999Z")
    #expect(at(253_402_300_799_999) == "9999-12-31T23:59:59.999Z")
    #expect(at(253_402_300_800_000) == "+010000-01-01T00:00:00.000Z")
}

@Test func aNewPianoIsWhatNewTuningGives() throws {
    let piano = Piano(name: "My piano", now: fixedNow, makeID: { "id-1" })
    #expect(piano.json == [
        "id": "id-1", "name": "My piano", "notes": "",
        "createdAt": "2025-01-02T03:04:05.006Z", "updatedAt": "2025-01-02T03:04:05.006Z",
        "passStartedAt": "2025-01-02T03:04:05.006Z",
        "settings": .object(settingsJSON(.defaults)),
        "inharmonicity": [:], "partials": [:], "keys": [:],
        "order": ["step": 0, "i": 0], "rev": 0, "history": [],
    ])
    #expect(Piano.newID().range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                                options: .regularExpression) != nil)
}

@Test func aCopyHasANewIdAndTimes() throws {
    let a = try decoded("a")
    let copy = a.duplicate(name: "Copy", now: fixedNow, makeID: { "copy-id" })
    #expect(copy.id == "copy-id" && copy.name == "Copy" && copy.rev == 0)
    #expect(copy.createdAt == "2025-01-02T03:04:05.006Z" && copy.updatedAt == copy.createdAt)
    #expect(copy.passStartedAt == a.passStartedAt && copy.keys == a.keys && copy.settings == a.settings)
}

@Test func exportAndImport() throws {
    let a = try decoded("a")
    let exported = try a.exportData()
    #expect(try parse(exported) == (try parse(Fixtures.data("piano/a.input.json"))))
    #expect(try !hasWholeNumberWithFraction(exported))
    #expect(String(decoding: exported, as: UTF8.self).contains("\n"))

    let fresh = try Piano.importing(exported, existingIDs: ["other"], now: fixedNow, makeID: { "imported-id" })
    #expect(fresh.id == "imported-id" && fresh.name == "Fixture piano A" && fresh.rev == 0)
    #expect(fresh.createdAt == "2025-01-02T03:04:05.006Z" && fresh.updatedAt == fresh.createdAt)
    #expect(fresh.keys == a.keys && fresh.settings == a.settings && fresh.order == a.order)
    #expect(fresh.inharmonicity == a.inharmonicity && fresh.passStartedAt == a.passStartedAt)
    var back = fresh
    (back.id, back.name, back.createdAt, back.updatedAt, back.rev) = (a.id, a.name, a.createdAt, a.updatedAt, a.rev)
    #expect(back.json == a.json)

    let again = try Piano.importing(exported, existingIDs: [a.id], now: fixedNow, makeID: { "second" })
    #expect(again.name == "Fixture piano A (import)")
    let sv = try Piano.importing(exported, existingIDs: [a.id], renamed: { "\($0) (import)".uppercased() }, makeID: { "x" })
    #expect(sv.name == "FIXTURE PIANO A (IMPORT)")

    let c = try Piano.importing(Fixtures.data("piano/c.input.json"), now: fixedNow, makeID: { "c2" })
    #expect(c.unknownFields["extra"] != nil && c.settings.pianoKind == "grand" && c.rev == 0)

    let unnamed = try Piano.importing(Data(#"{"settings":{"refA4":442}}"#.utf8), untitled: "Importerad", makeID: { "n" })
    #expect(unnamed.name == "Importerad" && unnamed.id == "n" && unnamed.settings.refA4 == 442)

    #expect(throws: PianoImportError.noSettings) { try Piano.importing(Data(#"{"name":"x"}"#.utf8)) }
    #expect(throws: PianoImportError.noSettings) { try Piano.importing(Data("[1, 2]".utf8)) }
    // Truthy as in JS: empty settings are settings, 0 is not.
    #expect(try Piano.importing(Data(#"{"settings":{}}"#.utf8), makeID: { "e" }).settings == .defaults)
    #expect(throws: PianoImportError.noSettings) { try Piano.importing(Data(#"{"settings":0}"#.utf8)) }
    #expect(throws: PianoImportError.notJSON) { try Piano.importing(Data("not json".utf8)) }
}

@Test func exportFileNames() {
    func name(_ s: String) -> String { Piano(name: s).exportFileName() }
    #expect(name("Fixture piano A") == "Fixture_piano_A.json")
    #expect(name("") == "piano.json")
    #expect(name("Bösendorfer 3/4, flygel") == "Bösendorfer_3_4_flygel.json")
    #expect(name("Hus ½ — C♯") == "Hus_½_C_.json")
    #expect(name("a_b-c") == "a_b-c.json")
}

// MARK: - Store

private func withStore(_ body: (PianoStore, URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PianoStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(PianoStore(directory: dir.appendingPathComponent("Piano Tunah")), dir)
}

@Test func storeSavesListsLoadsAndDeletes() throws {
    try withStore { store, _ in
        #expect(try store.list().isEmpty)
        for which in pianos { try store.save(try decoded(which)) }
        let ids = ["a", "b", "c"].map { "00000000-0000-4000-8000-00000000000\($0)" }
        #expect(try store.list() == [
            PianoStore.Summary(id: ids[0], name: "Fixture piano A", updatedAt: "2026-11-22T14:18:26.922Z"),
            PianoStore.Summary(id: ids[1], name: "Fixture piano B", updatedAt: "2026-10-26T19:00:04.444Z"),
            PianoStore.Summary(id: ids[2], name: "Fixture piano C", updatedAt: "2025-01-02T03:04:05.006Z"),
        ])
        // Only the files themselves, no temporary ones.
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(files == ids.map { $0 + ".json" })

        for (which, id) in zip(pianos, ids) {
            let loaded = try store.load(id: id)
            #expect(loaded == (try decoded(which)))
            let onDisk = try Data(contentsOf: store.directory.appendingPathComponent(id + ".json"))
            #expect(try parse(onDisk) == (try parse(Fixtures.data("piano/\(which).input.json"))))
            #expect(try !hasWholeNumberWithFraction(onDisk))
        }

        var b = try store.load(id: ids[1])
        b.name = "Saved again"
        try store.save(b)
        #expect(try store.load(id: ids[1]).name == "Saved again")

        try store.delete(id: ids[1])
        try store.delete(id: ids[1])
        #expect(try store.list().map(\.id) == [ids[0], ids[2]])
        #expect(throws: PianoStore.StoreError.notFound(ids[1])) { try store.load(id: ids[1]) }
    }
}

@Test func aCopiedFileIsThePianoOfItsName() throws {
    try withStore { store, _ in
        try store.save(try decoded("a"))
        let original = "00000000-0000-4000-8000-00000000000a"
        // Copied by hand to a new name, its id left as it was.
        try FileManager.default.copyItem(
            at: store.directory.appendingPathComponent(original + ".json"),
            to: store.directory.appendingPathComponent("copy.json"))
        var copy = try store.load(id: "copy")
        #expect(copy.id == "copy")
        copy.name = "The copy"
        try store.save(copy)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(files == ["\(original).json", "copy.json"].sorted())
        #expect(try store.load(id: original).name == "Fixture piano A")
        #expect(try store.load(id: "copy").name == "The copy")
        #expect(try parse(Data(contentsOf: store.directory.appendingPathComponent("copy.json")))["id"] == "copy")
        // Loaded and saved once more, unchanged: still its own piano.
        try store.save(try store.load(id: "copy"))
        #expect(try parse(Data(contentsOf: store.directory.appendingPathComponent("copy.json")))["id"] == "copy")
        #expect(try store.load(id: "copy") == (try store.load(id: "copy")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 2)
    }
}

@Test func storeGivesAFileWithoutAnIdItsName() throws {
    try withStore { store, _ in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let dir = store.directory
        try Data(#"{"name":"No id","settings":{}}"#.utf8).write(to: dir.appendingPathComponent("abc-1.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("bad id!.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        #expect(try store.list() == [PianoStore.Summary(id: "abc-1", name: "No id", updatedAt: "")])
        let piano = try store.load(id: "abc-1")
        #expect(piano.id == "abc-1")
        #expect(piano.json["id"] == "abc-1")
    }
}

@Test func storeRejectsBadIds() throws {
    try withStore { store, root in
        for id in ["", "../escape", "a/b", "a.b", "ä", String(repeating: "x", count: 65), "a b"] {
            #expect(!PianoStore.isValidID(id), "\(id)")
            #expect(throws: PianoStore.StoreError.invalidID(id)) { try store.load(id: id) }
            #expect(throws: PianoStore.StoreError.invalidID(id)) { try store.delete(id: id) }
            #expect(throws: PianoStore.StoreError.invalidID(id)) {
                try store.save(Piano(now: fixedNow, makeID: { id }))
            }
        }
        #expect(PianoStore.isValidID(String(repeating: "x", count: 64)))
        #expect(PianoStore.isValidID("00000000-0000-4000-8000-00000000000a"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.json").path))
        let left = try store.list()
        #expect(left.isEmpty)
    }
}
