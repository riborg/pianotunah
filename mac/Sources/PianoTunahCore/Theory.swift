import Foundation

// Tuning theory: key numbering, temperaments, inharmonicity and stretch.
// A port of web/js/theory.js; the numbers follow it operation by operation,
// so the fixtures from test/fixtures.mjs agree to the last bits.
//
// Key k = 1...88, where 1 = A0, 49 = A4 and 88 = C8. All deviations are in
// cents relative to theoretical equal temperament from the reference for A4.

/// Keys on a full keyboard, A0–C8 (JS: KEY_COUNT).
public let keyCount = 88
/// The key number of A4, which the reference applies to (JS: A4).
public let a4 = 49

/// Pythagorean comma ≈ 23.46 cents.
private let pc = 1200 * log2(531441.0 / 524288)
/// Syntonic comma ≈ 21.51 cents.
private let sc = 1200 * log2(81.0 / 80)
/// Schisma ≈ 1.95 cents.
private let schisma = pc - sc
/// A pure fifth ≈ 701.96 cents.
private let pureFifth = 1200 * log2(3.0 / 2)

private let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

/// The pitch class of key `k`: 0 = C … 9 = A … 11 = B.
public func pitchClass(_ k: Int) -> Int { (k + 8) % 12 }

/// The octave number of key `k` in scientific pitch notation (A4 is in 4).
public func octave(_ k: Int) -> Int { Int((Double(k + 8) / 12).rounded(.down)) }

/// Whether key `k` is a black key.
public func isBlack(_ k: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitchClass(k)) }

/// The name of pitch class `pc` (0 = C), with ♯ and ♭: C, C♯, D, E♭ …
/// Outside 0...11 it is "undefined", as in the web version.
public func pcName(_ pc: Int) -> String { names.indices.contains(pc) ? names[pc] : "undefined" }

/// The note name of key `k`, such as A4 or B♭1.
public func noteName(_ k: Int) -> String { pcName(pitchClass(k)) + String(octave(k)) }

// MARK: - Temperaments

/// A temperament, as how much each of the twelve fifths in the circle of
/// fifths deviates from a pure fifth (cents). Index i goes from the note
/// 7·i mod 12 to the next: C–G, G–D, D–A, A–E, E–B, B–F♯, F♯–C♯, C♯–G♯,
/// G♯–E♭, E♭–B♭, B♭–F, F–C. The sum must be −(Pythagorean comma) for the
/// circle to close; a nil entry (the wolf fifth) gets what is left over.
public struct Temperament: Sendable, Equatable, Identifiable {
    /// The id stored in the settings, such as "et" or "werckmeister3".
    public let id: String
    public let fifths: [Double?]
}

private func fifths(_ map: [Int: Double?] = [:], fill: Double = 0) -> [Double?] {
    var a = [Double?](repeating: fill, count: 12)
    for (i, v) in map { a[i] = v }
    return a
}

/// The temperaments, in the order the settings list them (JS: TEMPERAMENTS).
public let temperaments: [Temperament] = [
    Temperament(id: "et", fifths: fifths(fill: -pc / 12)),
    Temperament(id: "werckmeister3", fifths: fifths([0: -pc / 4, 1: -pc / 4, 2: -pc / 4, 5: -pc / 4])),
    Temperament(id: "kirnberger3", fifths: fifths([0: -sc / 4, 1: -sc / 4, 2: -sc / 4, 3: -sc / 4, 6: -schisma])),
    Temperament(id: "vallotti", fifths: fifths([11: -pc / 6, 0: -pc / 6, 1: -pc / 6, 2: -pc / 6, 3: -pc / 6, 4: -pc / 6])),
    Temperament(id: "young2", fifths: fifths([0: -pc / 6, 1: -pc / 6, 2: -pc / 6, 3: -pc / 6, 4: -pc / 6, 5: -pc / 6])),
    Temperament(id: "meantone4", fifths: fifths([8: nil], fill: -sc / 4)),
    Temperament(id: "meantone6", fifths: fifths([8: nil], fill: -sc / 6)),
]

/// The temperament with this id, or nil if there is none.
public func temperament(_ id: String) -> Temperament? { temperaments.first { $0.id == id } }

private func closeCircle(_ f: [Double?]) -> [Double] {
    let known = f.compactMap { $0 }.reduce(0, +)
    return f.map { $0 ?? -pc - known }
}

/// Deviation from equal temperament per pitch class (0 = C … 11 = B), in
/// cents, normalised so A is always 0 and the reference applies to A4.
/// `root` transposes the temperament to start from another note than C.
/// An unknown id gives equal temperament.
public func temperamentOffsets(_ id: String, root: Int = 0) -> [Double] {
    let f = closeCircle((temperament(id) ?? temperaments[0]).fifths)
    var pos = [Double](repeating: 0, count: 12)
    var cents = 0.0
    var p = 0
    for i in 0..<11 {
        cents += pureFifth + f[i]
        p = (p + 7) % 12
        pos[p] = cents
    }
    let off = pos.enumerated().map { p, c in
        var d = ((c - Double(p * 100)).truncatingRemainder(dividingBy: 1200) + 1200).truncatingRemainder(dividingBy: 1200)
        if d > 600 { d -= 1200 }
        return d
    }
    // A root above 12 points before the table: undefined in JS, so NaN.
    let rotated = (0..<12).map { p in
        let i = (p - root + 12) % 12
        return off.indices.contains(i) ? off[i] : .nan
    }
    let a = rotated[9]
    return rotated.map { $0 - a }
}

// MARK: - Inharmonicity
//
// A stiff string has partials f_n = n·f0·√(1 + B·n²). B depends on the
// string's diameter, length, tension and stiffness. The model below is a
// rough average curve: B grows exponentially towards the treble (short
// strings, thick for their length) and slightly towards the bass (short wound
// strings). Measured values replace the model where they exist.

/// A kind of piano and the sizes it comes in, in cm: an upright's height or
/// a grand's length.
public struct PianoKind: Sendable, Equatable, Identifiable {
    /// The id stored in the settings: "upright" or "grand".
    public let id: String
    public let minCm: Double
    public let maxCm: Double
    /// The size a new piano of this kind starts with.
    public let defaultCm: Double
}

/// The kinds of piano, in the order the settings list them (JS: PIANO_KINDS).
public let pianoKinds: [PianoKind] = [
    PianoKind(id: "upright", minCm: 90, maxCm: 150, defaultCm: 120),
    PianoKind(id: "grand", minCm: 140, maxCm: 310, defaultCm: 180),
]

/// The kind of piano with this id, or nil if there is none.
public func pianoKind(_ id: String) -> PianoKind? { pianoKinds.first { $0.id == id } }

/// Treble and bass factors on the model's B, relative to a 180 cm reference
/// grand: [cm, treble factor, bass factor], linear between the points. Short
/// strings give higher B, most of all in the bass.
private let sizeFactorTable: [String: [(cm: Double, treble: Double, bass: Double)]] = [
    "upright": [(100, 1.6, 3), (120, 1.3, 2), (140, 1.1, 1.4)],
    "grand": [(150, 1.15, 1.4), (180, 1, 1), (275, 0.8, 0.6)],
]

private func sizeFactors(_ kind: String, _ cm: Double) -> (treble: Double, bass: Double) {
    let pts = sizeFactorTable[kind] ?? sizeFactorTable["upright"]!
    if cm <= pts[0].cm { return (pts[0].treble, pts[0].bass) }
    for i in 1..<pts.count where cm <= pts[i].cm {
        let (c0, t0, b0) = pts[i - 1]
        let (c1, t1, b1) = pts[i]
        let f = (cm - c0) / (c1 - c0)
        return (t0 + (t1 - t0) * f, b0 + (b1 - b0) * f)
    }
    let last = pts[pts.count - 1]
    return (last.treble, last.bass)
}

/// A rough size class for display; the raw value is a key into the
/// language files.
public enum SizeClass: String, Sendable, CaseIterable {
    case smallUpright, midUpright, tallUpright
    case babyGrand, parlourGrand, concertGrand
}

/// The size class of a piano of this kind and size in cm. Any kind but
/// "grand" counts as an upright.
public func sizeClass(_ kind: String, _ cm: Double) -> SizeClass {
    if kind == "grand" { return cm < 170 ? .babyGrand : cm < 220 ? .parlourGrand : .concertGrand }
    return cm < 110 ? .smallUpright : cm < 125 ? .midUpright : .tallUpright
}

private struct Instrument {
    let kind: String
    let cm: Double
}

private func instrumentOf(_ s: Settings) -> Instrument {
    let known = pianoKind(s.pianoKind)
    return Instrument(
        kind: known != nil ? s.pianoKind : "upright",
        cm: or(s.sizeCm, known?.defaultCm ?? 120)
    )
}

/// JS `Number(x) || fallback` for a number already converted: 0 and NaN
/// give the fallback.
private func or(_ x: Double, _ fallback: Double) -> Double { x == 0 || x.isNaN ? fallback : x }

private func modelB(_ k: Int, _ inst: Instrument) -> Double {
    let (t, b) = sizeFactors(inst.kind, inst.cm)
    let treble = 0.00035 * pow(10, (Double(k - a4) * 0.46) / 12)
    let bass = 0.00008 * pow(10, Double(25 - k) * 0.025)
    return t * treble + b * bass
}

/// What older saved settings had in place of kind, size and key count: a
/// fixed instrument choice, pianoType.
private let legacyTypes: [String: (kind: String, cm: Double, keys: Double)] = [
    "concert": ("grand", 274, 88),
    "grand": ("grand", 180, 88),
    "upright": ("upright", 120, 88),
    "spinet": ("upright", 100, 88),
    "old85": ("upright", 120, 85),
]

/// Saved settings from before the piano had a kind and size: a pianoType is
/// replaced by pianoKind, sizeCm and keyCount (an unknown pianoType by an
/// upright). Settings that already have a pianoKind, or no pianoType, come
/// back as they are. The input is loosely typed, as stored.
public func migrateSettings(_ s: [String: JSONValue] = [:]) -> [String: JSONValue] {
    guard let type = s["pianoType"], type.isTruthy, !(s["pianoKind"]?.isTruthy ?? false) else { return s }
    let legacy = type.string.flatMap { legacyTypes[$0] } ?? legacyTypes["upright"]!
    var rest = s
    rest["pianoType"] = nil
    rest["pianoKind"] = .string(legacy.kind)
    rest["sizeCm"] = .number(legacy.cm)
    rest["keyCount"] = .number(legacy.keys)
    return rest
}

/// The measured keys whose B is taken as a misreading: more than twice, or
/// less than half, the measured keys on both sides (up to two each, within
/// three keys). B♭1 on a 120 cm upright once came out eight times its
/// neighbours. At a break B jumps on one side only, so that is kept. Sparse
/// measurements (All A) are not judged. Zero and NaN count as not measured.
public func bOutliers(_ measured: [Int: Double] = [:]) -> Set<Int> {
    func at(_ k: Int) -> Double { or(measured[k] ?? .nan, 0) }
    func side(_ k: Int, _ dir: Int) -> Double {
        var v: [Double] = []
        var i = 1
        while i <= 3 && v.count < 2 {
            if at(k + dir * i) > 0 { v.append(at(k + dir * i)) }
            i += 1
        }
        return v.isEmpty ? 0 : v.dropFirst().reduce(v[0], +) / Double(v.count)
    }
    var out = Set<Int>()
    for k in measured.keys {
        let lo = side(k, -1)
        let hi = side(k, 1)
        if at(k) == 0 || lo == 0 || hi == 0 { continue }
        let r1 = at(k) / lo
        let r2 = at(k) / hi
        if (r1 > 2 && r2 > 2) || (r1 < 0.5 && r2 < 0.5) { out.insert(k) }
    }
    return out
}

/// B for every key (index 0 unused). Measured values act as correction
/// factors on the model, interpolated logarithmically between the measured
/// keys. Outliers, keys off the keyboard and values that are not positive
/// are left out.
private func bCurve(_ inst: Instrument, _ measured: [Int: Double]) -> [Double] {
    let bad = bOutliers(measured)
    let pts = measured
        .map { k, b in (k: k, r: log(b / modelB(k, inst))) }
        .filter { $0.k >= 1 && $0.k <= keyCount && $0.r.isFinite && !bad.contains($0.k) }
        .sorted { $0.k < $1.k }
    var out = [Double](repeating: 0, count: keyCount + 1)
    for k in 1...keyCount {
        var r = 0.0
        if let first = pts.first, let last = pts.last {
            if k <= first.k {
                r = first.r
            } else if k >= last.k {
                r = last.r
            } else {
                for i in 1..<pts.count where k <= pts[i].k {
                    let (k0, r0) = pts[i - 1]
                    let (k1, r1) = pts[i]
                    r = r0 + ((r1 - r0) * Double(k - k0)) / Double(k1 - k0)
                    break
                }
            }
        }
        out[k] = modelB(k, inst) * exp(r)
    }
    return out
}

/// The partial factor: partial `n` of a string with inharmonicity `b` lies
/// at partialFactor(b, n)·n times the fundamental (partial 1).
public func partialFactor(_ b: Double, _ n: Int) -> Double {
    let n = Double(n)
    return ((1 + b * n * n) / (1 + b)).squareRoot()
}

/// The frequency of partial `n` of a string whose partial 1 is at `f1` Hz.
public func partialFreq(_ f1: Double, _ b: Double, _ n: Int) -> Double {
    Double(n) * f1 * partialFactor(b, n)
}

// MARK: - Stretch

/// Two partials that are made to coincide: `lower` of the lower note and
/// `upper` of the upper note.
public struct PartialPair: Sendable, Equatable, Hashable {
    public let lower: Int
    public let upper: Int

    public init(_ lower: Int, _ upper: Int) {
        self.lower = lower
        self.upper = upper
    }
}

/// An octave type "p:q": partial p of the lower note and partial q of the
/// upper note are made beatless. 2:1 gives the narrowest octave, 4:2, 6:3 and
/// 8:4 progressively wider.
public struct OctaveType: Sendable, Equatable, Identifiable {
    /// The id stored in the settings, such as "4:2".
    public let id: String
    public let partials: PartialPair
}

/// The octave types, in the order the settings list them (JS: OCTAVE_TYPES).
public let octaveTypes: [OctaveType] = [
    OctaveType(id: "2:1", partials: PartialPair(2, 1)),
    OctaveType(id: "4:2", partials: PartialPair(4, 2)),
    OctaveType(id: "6:3", partials: PartialPair(6, 3)),
    OctaveType(id: "8:4", partials: PartialPair(8, 4)),
]

/// The octave type with this id, or nil if there is none.
public func octaveType(_ id: String) -> OctaveType? { octaveTypes.first { $0.id == id } }

/// How many cents wider than 1200 an octave becomes with octave type `type`,
/// for a lower note with inharmonicity `bLow` and an upper with `bUp`. An
/// unknown type counts as 4:2.
public func octaveStretch(_ bLow: Double, _ bUp: Double, _ type: String) -> Double {
    let p = (octaveType(type) ?? octaveTypes[1]).partials
    return 1200 * log2(partialFactor(bLow, p.lower) / partialFactor(bUp, p.upper))
}

/// A stretch preset: the octave type for the middle, treble and bass, and
/// extra cents at the top of the treble. "none", "railsback" and "custom"
/// have no octave types of their own (JS: `{}`).
public struct StretchPreset: Sendable, Equatable, Identifiable {
    /// The id stored in the settings, such as "normal".
    public let id: String
    public let mid: String?
    public let treble: String?
    public let bass: String?
    public let extraTreble: Double

    public init(id: String, mid: String? = nil, treble: String? = nil, bass: String? = nil, extraTreble: Double = 0) {
        self.id = id
        self.mid = mid
        self.treble = treble
        self.bass = bass
        self.extraTreble = extraTreble
    }
}

/// The stretch presets, in the order the settings list them (JS: STRETCH_PRESETS).
public let stretchPresets: [StretchPreset] = [
    StretchPreset(id: "none"),
    StretchPreset(id: "light", mid: "2:1", treble: "2:1", bass: "4:2"),
    StretchPreset(id: "normal", mid: "4:2", treble: "4:2", bass: "6:3"),
    StretchPreset(id: "wide", mid: "4:2", treble: "4:2", bass: "8:4", extraTreble: 5),
    StretchPreset(id: "railsback"),
    StretchPreset(id: "custom"),
]

/// The stretch preset with this id, or nil if there is none.
public func stretchPreset(_ id: String) -> StretchPreset? { stretchPresets.first { $0.id == id } }

/// Overpull for a pitch raise, in percent of how flat the piano is. Tuned
/// strings drop as the load on the plate and soundboard grows while the rest
/// are pulled up. 25% is the usual rule of thumb; below 10 cents the drop is
/// within what a fine tuning absorbs.
public func recommendedOverpull(_ cents: Double) -> Double {
    cents <= -10 ? 25 : 0
}

// MARK: - Settings

/// A piano's settings (JS: the settings object, with DEFAULT_SETTINGS as
/// `Settings.defaults`). The ids are kept as strings, as stored: an id no
/// table knows falls back where it is used, as in the web version.
public struct Settings: Codable, Sendable, Equatable {
    /// The reference: the frequency of A4 in Hz.
    public var refA4: Double = 440
    /// The temperament's id, see `temperaments`.
    public var temperament = "et"
    /// The pitch class the temperament starts from (0 = C).
    public var root = 0
    /// The stretch preset's id, see `stretchPresets`.
    public var stretch = "normal"
    /// Octave types for the custom stretch, see `octaveTypes`.
    public var midOctave = "4:2"
    public var trebleOctave = "4:2"
    public var bassOctave = "6:3"
    /// Extra cents at the top of the treble and the bottom of the bass.
    public var extraTreble: Double = 0
    public var extraBass: Double = 0
    /// The kind of piano's id, see `pianoKinds`.
    public var pianoKind = "upright"
    /// The upright's height or the grand's length in cm.
    public var sizeCm: Double = 120
    /// 88 (A0–C8) or 85 (A0–A7, older pianos).
    public var keyCount = 88
    /// Overpull in percent; 0 is off.
    public var overpull: Double = 0
    /// The tolerance in cents.
    public var tolerance: Double = 1
    /// Strings per key, counted from A0: keys up to twoStringsTo have two, up
    /// to oneStringTo one (0 = none), the rest three. Used by the tuning order.
    public var twoStringsTo = 32
    public var oneStringTo = 0
    /// Unisons outside the felt strip: "one" string first with a wedge in the
    /// key, or "dsu", double string unison with a wedge between two keys.
    public var unisons = "one"

    public init() {}

    /// The settings a new piano starts with (JS: DEFAULT_SETTINGS).
    public static let defaults = Settings()

    /// The defaults with the fields of `loose` laid over them, as JS's
    /// `{ ...DEFAULT_SETTINGS, ...loose }`. Unknown fields are ignored.
    /// A number field takes `Number(x)`, so it can be NaN; a whole-number
    /// field (root, keyCount, twoStringsTo, oneStringTo) whose `Number(x)` is
    /// not a whole number becomes 0. A string field that is given something
    /// other than a string becomes "", which no table knows, as in the web.
    public init(merging loose: [String: JSONValue]) {
        func number(_ v: JSONValue) -> Double { v.jsNumber }
        func whole(_ v: JSONValue) -> Int {
            let x = v.jsNumber
            return x.isFinite && x.rounded() == x && abs(x) < 0x1p53 ? Int(x) : 0
        }
        func text(_ v: JSONValue) -> String { v.string ?? "" }
        for (key, v) in loose {
            switch key {
            case "refA4": refA4 = number(v)
            case "temperament": temperament = text(v)
            case "root": root = whole(v)
            case "stretch": stretch = text(v)
            case "midOctave": midOctave = text(v)
            case "trebleOctave": trebleOctave = text(v)
            case "bassOctave": bassOctave = text(v)
            case "extraTreble": extraTreble = number(v)
            case "extraBass": extraBass = number(v)
            case "pianoKind": pianoKind = text(v)
            case "sizeCm": sizeCm = number(v)
            case "keyCount": keyCount = whole(v)
            case "overpull": overpull = number(v)
            case "tolerance": tolerance = number(v)
            case "twoStringsTo": twoStringsTo = whole(v)
            case "oneStringTo": oneStringTo = whole(v)
            case "unisons": unisons = text(v)
            default: break
            }
        }
    }

    /// Decodes any JSON object, missing fields taking their defaults; see
    /// `init(merging:)`.
    public init(from decoder: Decoder) throws {
        self.init(merging: try [String: JSONValue](from: decoder))
    }
}

// MARK: - Targets

/// The temperament octave A3–A4 (keys 37–49) is tuned first. From there the
/// octaves are built up and down, one at a time, with the chosen octave type.
private let tLow = a4 - 12

/// Above C6 the higher partials of the upper note are weak and die quickly,
/// and with the treble's large B a wide octave type adds up fast (a 4:2
/// octave A6–A7 was 35 cents wide on a 120 cm upright). The octaves move to
/// 2:1 over C6–C8, blended rather than switched so the curve has no step.
private let topFrom = 64 // C6
private func share(_ x: Double) -> Double { min(1, max(0, x)) }
private func topShare(_ k: Int) -> Double { share(Double(k - topFrom) / 24) }

/// B jumps at the breaks and varies by some ten percent between neighbours.
/// With every octave matched exactly that carries down the chain as steps
/// between neighbouring keys. A triangular average over ±3 keys spreads it
/// out. The temperament octave is kept as laid.
private let smooth = 3
private func smoothCurve(_ s: [Double]) -> [Double] {
    var out = s
    for k in 1...keyCount {
        if k >= tLow && k <= a4 { continue }
        let r = min(smooth, k - 1, keyCount - k)
        var sum = 0.0
        var n = 0.0
        for j in -r...r {
            let w = Double(smooth + 1 - abs(j))
            sum += w * s[k + j]
            n += w
        }
        out[k] = sum / n
    }
    return out
}

/// Where every key should be tuned. Arrays indexed by key have 89 elements;
/// index 0 is unused (0). JS names in brackets.
public struct Targets: Sendable, Equatable {
    /// Inharmonicity B per key, measured or from the model (B).
    public var inharmonicity: [Double]
    /// The stretch per key, in cents from equal temperament (stretch).
    public var stretch: [Double]
    /// The temperament's offset per pitch class (0 = C), in cents (temper).
    public var temperament: [Double]
    /// The target per key, in cents from equal temperament (cents).
    public var cents: [Double]
    /// The target per key, in Hz (freq).
    public var frequency: [Double]
}

/// The targets for a piano with these settings and the inharmonicity
/// measured so far (key → B).
public func computeTargets(_ s: Settings = .defaults, measuredB: [Int: Double] = [:]) -> Targets {
    let b = bCurve(instrumentOf(s), measuredB)
    var st = [Double](repeating: 0, count: keyCount + 1)
    var extraTreble = or(s.extraTreble, 0)
    let extraBass = or(s.extraBass, 0)

    if s.stretch == "railsback" {
        for k in 1...keyCount {
            if k > a4 {
                st[k] = 30 * pow(Double(k - a4) / Double(keyCount - a4), 3)
            } else if k < a4 {
                st[k] = -25 * pow(Double(a4 - k) / Double(a4 - 1), 2.5)
            }
        }
    } else if s.stretch != "none" {
        let p = s.stretch == "custom"
            ? StretchPreset(id: "custom", mid: s.midOctave, treble: s.trebleOctave, bass: s.bassOctave)
            : stretchPreset(s.stretch) ?? stretchPreset("normal")!
        extraTreble += p.extraTreble
        // A missing octave type counts as 4:2, like an unknown one.
        let mid = p.mid ?? ""
        let treble = p.treble ?? ""
        let bass = p.bass ?? ""
        st[tLow] = -octaveStretch(b[tLow], b[a4], mid)
        for k in (tLow + 1)..<a4 { st[k] = (st[tLow] * Double(a4 - k)) / 12 }
        // Octave lo–hi with the types mixed by weight.
        func width(_ lo: Int, _ hi: Int, _ types: [(String, Double)]) -> Double {
            types.reduce(0.0) { sum, t in
                let (type, w) = t
                return w != 0 && !w.isNaN ? sum + w * octaveStretch(b[lo], b[hi], type) : sum
            }
        }
        for k in (a4 + 1)...keyCount {
            let u = share(Double(k - a4) / 12)
            let w = topShare(k)
            st[k] = st[k - 12] + width(k - 12, k, [(mid, (1 - u) * (1 - w)), (treble, u * (1 - w)), ("2:1", w)])
        }
        for k in stride(from: tLow - 1, through: 1, by: -1) {
            let v = share(Double(tLow - k) / 12)
            st[k] = st[k + 12] - width(k, k + 12, [(mid, 1 - v), (bass, v)])
        }
        st = smoothCurve(st)
    }
    for k in 1...keyCount {
        if k > a4 { st[k] += extraTreble * pow(Double(k - a4) / Double(keyCount - a4), 2) }
        if k < a4 { st[k] -= extraBass * pow(Double(a4 - k) / Double(a4 - 1), 2) }
    }

    let temper = temperamentOffsets(s.temperament, root: s.root)
    var cents = [Double](repeating: 0, count: keyCount + 1)
    var freq = [Double](repeating: 0, count: keyCount + 1)
    for k in 1...keyCount {
        cents[k] = st[k] + temper[pitchClass(k)]
        freq[k] = s.refA4 * pow(2, Double(k - a4) / 12 + cents[k] / 1200)
    }
    return Targets(inharmonicity: b, stretch: st, temperament: temper, cents: cents, frequency: freq)
}

/// Which partial is measured by default. In the bass the fundamental is weak
/// (and laptop microphones hear little below ~100 Hz), so a higher partial is
/// measured there.
public func defaultPartial(_ k: Int) -> Int {
    if k <= 14 { return 6 }
    if k <= 26 { return 4 }
    if k <= 38 { return 2 }
    return 1
}

/// How many cents `f` lies above `ref`.
public func centsBetween(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

// MARK: - Beats

/// The lowest coincident partials of each interval, in semitones, at which a
/// check is heard: a major third lo–hi beats where partial 5 of lo meets
/// partial 4 of hi (JS: COINCIDENT).
public let coincident: [Int: PartialPair] = [
    3: PartialPair(6, 5), 4: PartialPair(5, 4), 5: PartialPair(4, 3), 7: PartialPair(3, 2), 9: PartialPair(5, 3),
    12: PartialPair(2, 1), 16: PartialPair(5, 2), 19: PartialPair(3, 1), 24: PartialPair(4, 1), 28: PartialPair(5, 1),
]

/// Beats per second between keys `lo` and `hi` with both at their targets,
/// heard at `partials`, by default the interval's coincident partials.
/// Positive: the interval is wide (the upper partial is higher). Without
/// `partials`, the interval must be one of `coincident`.
public func intervalBeat(_ t: Targets, _ lo: Int, _ hi: Int, _ partials: PartialPair? = nil) -> Double {
    guard let p = partials ?? coincident[hi - lo] else {
        preconditionFailure("intervalBeat: no coincident partials for \(hi - lo) semitones")
    }
    return partialFreq(t.frequency[hi], t.inharmonicity[hi], p.upper)
        - partialFreq(t.frequency[lo], t.inharmonicity[lo], p.lower)
}
