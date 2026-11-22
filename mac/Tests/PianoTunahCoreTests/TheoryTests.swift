import Foundation
import Testing
@testable import PianoTunahCore

// Theory.swift against theory-targets.json, theory-temperaments.json and
// theory-misc.json from test/fixtures.mjs.

extension JSON {
    /// The fixture value as the core's JSONValue.
    var value: JSONValue {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .number(let x): .number(x)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(\.value))
        case .object(let o): .object(o.mapValues(\.value))
        }
    }

    var strings: [String]? { array?.compactMap(\.string) }
    var ints: [Int]? { array?.compactMap(\.int) }
    var bools: [Bool]? { array?.compactMap(\.bool) }

    /// A fixture object of key → B, as the core takes it.
    var measuredB: [Int: Double]? {
        guard let o = object else { return nil }
        var out: [Int: Double] = [:]
        for (k, v) in o {
            guard let key = Int(k), let b = v.double else { return nil }
            out[key] = b
        }
        return out
    }
}

/// Within 1e-12 relative, or 1e-12 absolute when `absolute` and the
/// expected value is below 1 in size (cents near 0). NaN and ±∞ must match.
private func close(_ got: Double, _ want: Double, absolute: Bool = true) -> Bool {
    if want.isNaN { return got.isNaN }
    if want.isInfinite { return got == want }
    let d = abs(got - want)
    return d <= 1e-12 * abs(want) || (absolute && abs(want) < 1 && d <= 1e-12)
}

/// The error `close` measures: relative, or absolute below 1 when `absolute`.
private func error(_ got: Double, _ want: Double, absolute: Bool = true) -> Double {
    if !want.isFinite { return got == want || (got.isNaN && want.isNaN) ? 0 : .infinity }
    let d = abs(got - want)
    return absolute && abs(want) < 1 ? min(d, d / abs(want)) : d / abs(want)
}

/// Checks every element and returns the largest error.
@discardableResult
private func expectClose(
    _ got: [Double], _ want: [Double]?, absolute: Bool = true, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Double {
    guard let want else {
        Issue.record("\(what): not in the fixture", sourceLocation: sourceLocation)
        return .infinity
    }
    #expect(got.count == want.count, "\(what): length", sourceLocation: sourceLocation)
    for (i, (g, w)) in zip(got, want).enumerated() where !close(g, w, absolute: absolute) {
        Issue.record("\(what)[\(i)] = \(g), JS gives \(w)", sourceLocation: sourceLocation)
    }
    return zip(got, want).map { error($0, $1, absolute: absolute) }.max() ?? 0
}

@Test func computeTargetsMatchesTheFixture() throws {
    let cases = try #require(try Fixtures.json("theory-targets.json")["cases"].array)
    #expect(cases.count == 67)
    var worst = 0.0
    for c in cases {
        let name = c["name"].string ?? "?"
        let settings = Settings(merging: try #require(c["settings"].value.object, "\(name): settings"))
        let measured = try #require(c["measuredB"].measuredB, "\(name): measuredB")
        let t = computeTargets(settings, measuredB: measured)
        worst = max(
            worst,
            expectClose(t.inharmonicity, c["B"].doubles, absolute: false, "\(name): B"),
            expectClose(t.stretch, c["stretch"].doubles, "\(name): stretch"),
            expectClose(t.temperament, c["temper"].doubles, "\(name): temper"),
            expectClose(t.cents, c["cents"].doubles, "\(name): cents"),
            expectClose(t.frequency, c["freq"].doubles, absolute: false, "\(name): freq")
        )
    }
    print("computeTargets: \(cases.count) cases, largest error \(worst)")
}

@Test func temperamentOffsetsMatchTheFixture() throws {
    let f = try Fixtures.json("theory-temperaments.json")
    let ids = try #require(f["ids"].strings)
    #expect(Array(ids.dropLast()) == temperaments.map(\.id), "the temperaments in JS order")
    var worst = 0.0
    for id in ids {
        let roots = try #require(f["offsets"][id].array, "\(id)")
        #expect(roots.count == 12)
        for (root, want) in roots.enumerated() {
            worst = max(worst, expectClose(temperamentOffsets(id, root: root), want.doubles, "\(id) root \(root)"))
        }
    }
    print("temperamentOffsets: \(ids.count) × 12 cases, largest error \(worst)")
}

@Test func migrateSettingsMatchesTheFixture() throws {
    let cases = try #require(try Fixtures.json("theory-misc.json")["migrateSettings"].array)
    #expect(cases.count == 11)
    for c in cases {
        let want = c["output"].value
        let got: [String: JSONValue] = if c["input"].isNull {
            migrateSettings()
        } else {
            migrateSettings(try #require(c["input"].value.object))
        }
        #expect(JSONValue.object(got) == want, "migrateSettings(\(c["input"].value))")
    }
}

@Test func bOutliersMatchTheFixture() throws {
    let cases = try #require(try Fixtures.json("theory-misc.json")["bOutliers"].array)
    #expect(cases.count == 11)
    for c in cases {
        let measured = try #require(c["measured"].measuredB)
        let want = try #require(c["outliers"].ints)
        #expect(bOutliers(measured).sorted() == want, "bOutliers(\(measured.sorted { $0.key < $1.key }))")
    }
}

@Test func keyHelpersMatchTheFixture() throws {
    let f = try Fixtures.json("theory-misc.json")
    let keys = Array(1...88)
    #expect(keys.map(noteName) == f["noteName"].strings)
    #expect(keys.map(pitchClass) == f["pitchClass"].ints)
    #expect(keys.map(octave) == f["octave"].ints)
    #expect(keys.map(isBlack) == f["isBlack"].bools)
    #expect(keys.map(defaultPartial) == f["defaultPartial"].ints)
    #expect(noteName(49) == "A4" && noteName(2) == "B♭0" && noteName(5) == "C♯1" && noteName(88) == "C8")
}

@Test func smallHelpersMatchTheFixture() throws {
    let f = try Fixtures.json("theory-misc.json")

    let sizes = try #require(f["sizeClass"].array)
    #expect(sizes.count == 9)
    for c in sizes {
        let kind = try #require(c["kind"].string)
        let cm = try #require(c["cm"].double)
        #expect(sizeClass(kind, cm).rawValue == c["cls"].string, "sizeClass(\(kind), \(cm))")
    }

    let overpulls = try #require(f["recommendedOverpull"].array)
    #expect(overpulls.count == 6)
    for c in overpulls {
        let cents = try #require(c["cents"].double)
        #expect(recommendedOverpull(cents) == c["percent"].double, "recommendedOverpull(\(cents))")
    }

    let stretches = try #require(f["octaveStretch"].array)
    #expect(stretches.count == 20)
    for c in stretches {
        let lo = try #require(c["Blow"].double)
        let up = try #require(c["Bup"].double)
        let type = try #require(c["type"].string)
        let want = try #require(c["cents"].double)
        let got = octaveStretch(lo, up, type)
        #expect(close(got, want), "octaveStretch(\(lo), \(up), \(type)) = \(got), JS gives \(want)")
    }

    let partials = try #require(f["partialFreq"].array)
    #expect(partials.count == 4)
    for c in partials {
        let f1 = try #require(c["f1"].double)
        let b = try #require(c["B"].double)
        let n = try #require(c["n"].int)
        let want = try #require(c["freq"].double)
        let got = partialFreq(f1, b, n)
        #expect(close(got, want, absolute: false), "partialFreq(\(f1), \(b), \(n)) = \(got), JS gives \(want)")
    }
}

@Test func intervalBeatMatchesTheFixture() throws {
    let cases = try #require(try Fixtures.json("theory-misc.json")["intervalBeat"].array)
    #expect(cases.count == 10)
    let t = computeTargets(.defaults)
    for c in cases {
        #expect(c["settings"].string == "defaults")
        let lo = try #require(c["lo"].int)
        let hi = try #require(c["hi"].int)
        let p = try #require(c["p"].ints)
        let pair = PartialPair(p[0], p[1])
        let want = try #require(c["beat"].double)
        let got = intervalBeat(t, lo, hi, pair)
        #expect(close(got, want), "intervalBeat(\(lo), \(hi), \(p)) = \(got), JS gives \(want)")
        // Where the fixture's partials are the interval's own, the default
        // must give them too.
        if coincident[hi - lo] == pair {
            #expect(intervalBeat(t, lo, hi) == got)
        }
    }
}

@Test func settingsDefaultsAreDefaultSettings() throws {
    let cases = try #require(try Fixtures.json("theory-targets.json")["cases"].array)
    let defaults = try #require(cases.first { $0["name"].string == "defaults" }?["settings"].value.object)
    #expect(defaults.count == 17)
    #expect(Settings(merging: defaults) == .defaults)
    #expect(Settings(merging: [:]) == .defaults)

    // Encoded, the defaults are DEFAULT_SETTINGS; decoded again, the same.
    let data = try JSONEncoder().encode(Settings.defaults)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(defaults))
    #expect(try JSONDecoder().decode(Settings.self, from: data) == .defaults)
    #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"refA4": 442}"#.utf8)).refA4 == 442)
}

@Test func settingsMergeLikeJavaScript() {
    let s = Settings(merging: [
        "refA4": "442", "sizeCm": 0, "extraTreble": "x", "root": "5", "keyCount": 85.5,
        "temperament": 3, "unisons": "dsu", "pianoType": "grand",
    ])
    #expect(s.refA4 == 442)
    #expect(s.sizeCm == 0) // computeTargets takes the kind's default for 0
    #expect(s.extraTreble.isNaN) // and 0 for NaN
    #expect(s.root == 5)
    #expect(s.keyCount == 0)
    #expect(s.temperament == "")
    #expect(s.unisons == "dsu")
    // Number(x) || default, as computeTargets reads the settings.
    #expect(computeTargets(s).cents == computeTargets(Settings(merging: ["refA4": 442, "root": 5])).cents)
}

@Test func tablesAreInJavaScriptOrder() {
    #expect(pianoKinds.map(\.id) == ["upright", "grand"])
    #expect(pianoKind("grand")?.defaultCm == 180)
    #expect(octaveTypes.map(\.id) == ["2:1", "4:2", "6:3", "8:4"])
    #expect(stretchPresets.map(\.id) == ["none", "light", "normal", "wide", "railsback", "custom"])
    #expect(stretchPreset("wide")?.extraTreble == 5)
    #expect(coincident.keys.sorted() == [3, 4, 5, 7, 9, 12, 16, 19, 24, 28])
    #expect(keyCount == 88 && a4 == 49)
    #expect(centsBetween(880, 440) == 1200)
}

@Test func jsNumberConvertsLikeNumber() {
    let cases: [(JSONValue, Double)] = [
        (nil, 0), (true, 1), (false, 0), (12.5, 12.5), ("", 0), ("  12 \n", 12), ("0x1A", 26), ("0b101", 5),
        ("0o17", 15), ("1e3", 1000), ("-1.5E-2", -0.015), ("1.", 1), (".5", 0.5), ("+3", 3), ("Infinity", .infinity),
        ("-Infinity", -.infinity), ([], 0), (["5"], 5), ([7], 7), ([nil], 0), ([[" 2 "]], 2),
    ]
    for (v, want) in cases {
        #expect(v.jsNumber == want, "Number(\(v))")
    }
    let nans: [JSONValue] = ["abc", "inf", "nan", "1e", "0x", "-0x10", "1_000", "0x1p3", ".", "1 2", [1, 2], [true], [:]]
    for v in nans {
        #expect(v.jsNumber.isNaN, "Number(\(v))")
    }
    #expect(!JSONValue.number(0).isTruthy && !JSONValue.string("").isTruthy && !JSONValue.null.isTruthy)
    #expect(JSONValue.string("0").isTruthy && JSONValue.array([]).isTruthy && JSONValue.number(-1).isTruthy)
}
