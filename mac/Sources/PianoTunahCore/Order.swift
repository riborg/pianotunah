import Foundation

// The tuning order: the steps of a tuning in the order a tuner works by ear,
// from the pitch check to the last unison. Each step has tasks: a key and
// what to do with it. The targets give the pitch; checks are intervals to
// play by ear, with the beat rate the targets give.
//
// A port of web/static/js/order.js. The JS names are given in each doc comment.

/// The tuning order for one piano: its steps in the order they are worked
/// through (JS: the array `buildOrder` returns). A position in it is a step
/// and a task in that step; a step without tasks is one position of its own.
public struct TuningOrder: Sendable, Equatable {
    /// The steps, from the pitch check to the last unison. Never empty.
    public let steps: [Step]

    // MARK: - Steps and tasks

    /// Which step of the tuning order this is. The raw value is the id the
    /// web version uses (and its language files are keyed by).
    public enum StepID: String, Sendable, Hashable, CaseIterable {
        /// Check the pitch of the middle against the target; only an instruction.
        case pitch
        /// The pitch raise: every key, all strings, within a few cents.
        case raise
        /// Put the felt strip in; only an instruction.
        case strip
        /// A4, then A3 as an octave below it.
        case middle
        /// The temperament F3–E4 by fourths and fifths from A3.
        case temperament
        /// F4–G♯4, octaves up from the temperament, strip still in.
        case upper
        /// The treble above the felt strip.
        case treble
        /// Pull the felt strip key by key and tune each unison.
        case pull
        /// The bass below the felt strip.
        case bass
        /// Go over the keys that are not yet within tolerance.
        case finish
    }

    /// One part of the tuning order, such as the temperament or the bass.
    public struct Step: Sendable, Equatable {
        public let id: StepID
        /// A loose step (the pitch raise) is within a few cents rather than
        /// tolerance, and its tasks set no key's pitch for `tunedBefore`.
        public let loose: Bool
        /// The tasks in order; empty for a step that is only an instruction.
        public let tasks: [Task]

        public init(id: StepID, loose: Bool = false, tasks: [Task] = []) {
            self.id = id
            self.loose = loose
            self.tasks = tasks
        }
    }

    /// One key and what to do with it in a step. (Nested, so it does not
    /// stand in for Swift's `Task` outside `TuningOrder`.)
    public struct Task: Sendable, Equatable, Hashable {
        /// The key (JS: k).
        public let key: Int
        /// The key it is tuned from, as an interval, if any.
        public let from: Int?
        /// What to do with the key (JS: what).
        public let action: Action
        /// The intervals to check it by besides the one from `from`. Nil and
        /// empty differ only in where they come from in the web version.
        public let checks: [Check]?

        public init(key: Int, from: Int? = nil, action: Action, checks: [Check]? = nil) {
            self.key = key
            self.from = from
            self.action = action
            self.checks = checks
        }
    }

    /// What a task does with its key. The raw value is the web version's.
    public enum Action: String, Sendable, Hashable, CaseIterable {
        /// Pitch raise: bring all strings within a few cents.
        case raise
        /// Tune the free string inside the felt strip.
        case middle
        /// One string first: a wedge leaves one string, tuned from its octave.
        case one
        /// Double string unison: tune the two free strings pure and on pitch
        /// together.
        case pair
        /// Double string unison: the wedge is out, tune the third string to
        /// the pair.
        case third
        /// Tune the other strings to the one tuned first.
        case unison
        /// Pull the felt strip from the key and tune its unison.
        case pull
        /// Go over the key again in the last step.
        case recheck
    }

    /// An interval to play by ear: keys `lo` < `hi`, heard where `partials`
    /// coincide, by default the interval's coincident partials (see
    /// `coincident`).
    public struct Check: Sendable, Equatable, Hashable {
        public let lo: Int
        public let hi: Int
        public let partials: PartialPair?

        public init(_ lo: Int, _ hi: Int, _ partials: PartialPair? = nil) {
            self.lo = lo
            self.hi = hi
            self.partials = partials
        }
    }

    /// The keys and strings per key an order is built for (JS: the first
    /// argument of `buildOrder`).
    public struct Layout: Sendable, Equatable, Hashable {
        /// The top key: 88 (C8), or 85 (A7) on older pianos.
        public var top: Int
        /// Keys up to this one have two strings (0 = none).
        public var twoStringsTo: Int
        /// Keys up to this one have one string (0 = none).
        public var oneStringTo: Int
        /// Tune the unisons outside the felt strip as double string unisons.
        public var dsu: Bool

        public init(top: Int, twoStringsTo: Int = 0, oneStringTo: Int = 0, dsu: Bool = false) {
            self.top = top
            self.twoStringsTo = twoStringsTo
            self.oneStringTo = oneStringTo
            self.dsu = dsu
        }

        /// The layout of a piano with these settings, as app.js builds it:
        /// 85 keys if keyCount is 85, otherwise 88; DSU if unisons is "dsu".
        public init(_ s: Settings) {
            self.init(top: s.keyCount == 85 ? 85 : keyCount, twoStringsTo: s.twoStringsTo,
                      oneStringTo: s.oneStringTo, dsu: s.unisons == "dsu")
        }

        /// The strings per key of key `k`: 1, 2 or 3.
        public func strings(_ k: Int) -> Int {
            k <= oneStringTo ? 1 : k <= twoStringsTo ? 2 : 3
        }
    }

    // MARK: - Building

    /// The felt strip mutes the outer strings of F3–A4, so one string per key
    /// sounds while the temperament and the octaves above it are laid (JS:
    /// STRIP, as [33, 49]).
    public static let strip: ClosedRange<Int> = 33...49

    /// The tuning order for `layout` (`buildOrder`). `recheck`: keys to go
    /// over again in the last step.
    public init(_ layout: Layout, recheck: [Int] = []) {
        let top = layout.top
        let bass = Self.outside(from: Self.strip.lowerBound - 1, to: 1, layout) { k in
            (k + 12, Self.down(k))
        }
        // The treble keeps one key at a time with one string first: a wedge
        // in the key, then its unison.
        let treble: [Task] = layout.dsu
            ? Self.outside(from: Self.strip.upperBound + 1, to: top, layout) { k in (k - 12, Self.up(k)) }
            : range(Self.strip.upperBound + 1, top).flatMap { k in
                [Task(key: k, from: k - 12, action: .one, checks: Self.up(k)), Task(key: k, action: .unison)]
            }
        steps = [
            Step(id: .pitch),
            // From the middle up, then down: all strings, within a few cents.
            Step(id: .raise, loose: true, tasks: (range(37, top) + range(36, 1)).map { Task(key: $0, action: .raise) }),
            Step(id: .strip),
            Step(id: .middle, tasks: [
                Task(key: 49, action: .middle),
                Task(key: 37, from: 49, action: .middle,
                     checks: [Check(37, 49, PartialPair(4, 2)), Check(33, 37), Check(33, 49)]),
            ]),
            Step(id: .temperament, tasks: Self.temperament.map {
                Task(key: $0.key, from: $0.from, action: .middle, checks: $0.checks)
            }),
            Step(id: .upper, tasks: range(45, Self.strip.upperBound - 1).map {
                Task(key: $0, from: $0 - 12, action: .middle, checks: Self.up($0))
            }),
            Step(id: .treble, tasks: treble),
            Step(id: .pull, tasks: range(Self.strip.upperBound, Self.strip.lowerBound).map { Task(key: $0, action: .pull) }),
            Step(id: .bass, tasks: bass),
            Step(id: .finish, tasks: recheck.map { Task(key: $0, action: .recheck) }),
        ]
    }

    /// The temperament F3–E4 by fourths and fifths from A3: key, tuned from,
    /// checks. The checks compare like with like as soon as both exist:
    /// thirds beat faster the higher they lie, and so do fourths and fifths.
    private static let temperament: [(key: Int, from: Int, checks: [Check])] = [
        (42, 37, []), // D4 from A3
        (35, 42, []), // G3 from D4
        (40, 35, []), // C4 from G3
        (33, 40, [Check(33, 37)]), // F3 from C4; F3–A3 ≈ 7/s
        (38, 33, [Check(33, 37), Check(38, 42)]), // B♭3; B♭3–D4 faster than F3–A3
        (43, 38, [Check(37, 42)]), // E♭4; A3–D4 slower than B♭3–E♭4
        (36, 43, [Check(36, 40)]), // A♭3; A♭3–C4
        (41, 36, [Check(37, 41)]), // C♯4; A3–C♯4
        (34, 41, [Check(33, 40), Check(33, 37), Check(34, 38)]), // F♯3; F3–C4 slower, F♯3–B♭3 faster than F3–A3
        (39, 34, [Check(35, 39), Check(38, 42), Check(39, 43)]), // B3; G3–B3, B3–E♭4 faster than B♭3–D4
        // E4 closes the circle: C4–E4 faster than B3–E♭4, the fifth A3–E4 and
        // fourth E4–A4, and every third from C4–E4 down to F3–A3 evenly slower.
        (44, 39, [Check(39, 43), Check(40, 44), Check(37, 44), Check(44, 49)] + range(40, 33).map { Check($0, $0 + 4) }),
    ]

    /// An octave tuned upwards from k − 12: the octave as 2:1 and 4:2, the
    /// third below with the tenth (M3–M10), fourth with fifth, and the double
    /// octave.
    private static func up(_ k: Int) -> [Check] {
        [Check(k - 12, k, PartialPair(2, 1)), Check(k - 12, k, PartialPair(4, 2)), Check(k - 16, k - 12),
         Check(k - 16, k), Check(k - 12, k - 7), Check(k - 7, k), Check(k - 24, k)]
    }

    /// An octave tuned downwards from k + 12: in the bass also the twelfth
    /// and the seventeenth.
    private static func down(_ k: Int) -> [Check] {
        [Check(k, k + 12, PartialPair(2, 1)), Check(k, k + 12, PartialPair(4, 2)), Check(k, k + 12, PartialPair(6, 3)),
         Check(k + 12, k + 16), Check(k, k + 16), Check(k, k + 19), Check(k, k + 24), Check(k, k + 28)]
    }

    /// Outside the felt strip, two keys at a time from `first` towards
    /// `last`. One string first: a wedge leaves one string of each key, tuned
    /// from its octave, then the unisons. Double string unison: one wedge
    /// between the two keys mutes one string of each; the two free strings of
    /// each key are tuned pure and on pitch together (`pair`), then the wedge
    /// comes out and the third string is tuned to them (`third`). A key with
    /// two strings needs no wedge: its pair is its unison. A single string is
    /// tuned as in `one`.
    private static func outside(
        from first: Int, to last: Int, _ layout: Layout, octave: (Int) -> (from: Int, checks: [Check])
    ) -> [Task] {
        var tasks: [Task] = []
        // The JS never stops when first == last; here that is one key.
        let dir = last >= first ? 1 : -1
        let strings = layout.strings
        // With DSU two keys share a wedge only if they have as many strings:
        // a wedge beside a key with two strings would leave it one.
        func together(_ k: Int) -> Bool {
            dir * (last - k) >= 1 && (!layout.dsu || strings(k) == strings(k + dir))
        }
        var k = first
        while dir * (last - k) >= 0 {
            let keys = together(k) ? [k, k + dir] : [k]
            k += keys.count * dir
            tasks += keys.map { x in
                let o = octave(x)
                return Task(key: x, from: o.from, action: layout.dsu && strings(x) > 1 ? .pair : .one, checks: o.checks)
            }
            if layout.dsu {
                tasks += keys.filter { strings($0) > 2 }.map { Task(key: $0, action: .third) }
            } else {
                tasks += keys.filter { strings($0) > 1 }.map { Task(key: $0, action: .unison) }
            }
        }
        return tasks
    }

    // MARK: - Positions

    /// A position in the tuning order: a step and a task in it (JS: { step,
    /// i }). Stored in the piano's pass as `order`, with the same keys.
    public struct Position: Sendable, Equatable, Hashable, Codable {
        /// The index of the step.
        public var step: Int
        /// The index of the task in the step; 0 for a step without tasks.
        public var index: Int

        public init(step: Int, index: Int) {
            self.step = step
            self.index = index
        }

        /// The first position: the pitch check.
        public static let start = Position(step: 0, index: 0)

        private enum CodingKeys: String, CodingKey {
            case step
            case index = "i"
        }

        /// Decodes leniently, as `clampPos` reads a saved position: each field
        /// through JS `Number(x) || 0`, so a missing field, NaN or anything
        /// that is not a number is 0, and a value that is not an object is
        /// the start. Unlike the web version a fraction is rounded down,
        /// since a position holds whole numbers. Use `TuningOrder.clamp` on
        /// the result before using it.
        public init(from decoder: Decoder) throws {
            let v = try decoder.singleValueContainer().decode(JSONValue.self)
            func field(_ key: CodingKeys) -> Int {
                let x = v[key.rawValue]?.jsNumber ?? 0
                if x.isNaN { return 0 }
                // Within ±2^53 so the conversion cannot trap; clamping
                // brings it into the order anyway.
                return Int(min(max(x, -9_007_199_254_740_992), 9_007_199_254_740_992).rounded(.down))
            }
            self.init(step: field(.step), index: field(.index))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(step, forKey: .step)
            try c.encode(index, forKey: .index)
        }
    }

    /// Positions in a step: a step without tasks is one of its own.
    private func count(_ step: Int) -> Int { max(1, steps[step].tasks.count) }

    /// `pos` brought into the order (`clampPos`): the step within the steps,
    /// the task within that step. Nil gives the start.
    public func clamp(_ pos: Position?) -> Position {
        let step = max(0, min(steps.count - 1, pos?.step ?? 0))
        return Position(step: step, index: max(0, min(count(step) - 1, pos?.index ?? 0)))
    }

    /// The position after `pos`, or nil at the end (`nextPos`). `pos` must be
    /// in the order.
    public func next(after pos: Position) -> Position? {
        if pos.index + 1 < count(pos.step) { return Position(step: pos.step, index: pos.index + 1) }
        return pos.step + 1 < steps.count ? Position(step: pos.step + 1, index: 0) : nil
    }

    /// The position before `pos`, or nil at the start (`prevPos`). `pos` must
    /// be in the order.
    public func previous(before pos: Position) -> Position? {
        if pos.index > 0 { return Position(step: pos.step, index: pos.index - 1) }
        return pos.step > 0 ? Position(step: pos.step - 1, index: count(pos.step - 1) - 1) : nil
    }

    /// The task at `pos`, or nil in a step without tasks (`taskAt`).
    public func task(at pos: Position) -> Task? {
        guard steps.indices.contains(pos.step) else { return nil }
        let tasks = steps[pos.step].tasks
        return tasks.indices.contains(pos.index) ? tasks[pos.index] : nil
    }

    /// Tasks that set a key's pitch; the others tune its other strings to it.
    private static let pitched: Set<Action> = [.middle, .one, .pair]

    /// The keys whose pitch was set before `pos` (`tunedBefore`). The pitch
    /// raise is loose and does not count.
    public func tunedBefore(_ pos: Position) -> Set<Int> {
        var keys = Set<Int>()
        for (si, s) in steps.enumerated() where !s.loose && si <= pos.step {
            for (ti, t) in s.tasks.enumerated() where (si < pos.step || ti < pos.index) && Self.pitched.contains(t.action) {
                keys.insert(t.key)
            }
        }
        return keys
    }

    /// The share of the order before `pos`, 0–1 (`progress`).
    public func progress(_ pos: Position) -> Double {
        let total = steps.indices.reduce(0) { $0 + count($1) }
        let before = (0..<pos.step).reduce(0) { $0 + count($1) }
        return Double(before + pos.index) / Double(total)
    }

    // MARK: - Confirming a task

    /// Strikes towards the current task (JS: the object `newConfirm` makes).
    ///
    /// A task is done after two strikes in a row that end in tune: the note
    /// as tuned, and a firm test blow that shows the pin holds. A strike
    /// counts by its last steady reading, since the pin is often turned
    /// while it rings. Strikes up to the one the task started at do not
    /// count.
    public struct Confirmation: Sendable, Equatable, Hashable {
        /// The attack the task started at; strikes up to it do not count.
        public var since: Int
        /// The attack of the strike being heard (JS: cur).
        public var current: Int
        /// Whether the strike's last reading was in tune; nil before any.
        public var ok: Bool?
        /// Strikes in a row before the current one that ended in tune.
        public var streak: Int

        public init(since: Int, current: Int, ok: Bool?, streak: Int) {
            self.since = since
            self.current = current
            self.ok = ok
            self.streak = streak
        }

        /// Confirmation of a task started at attack `attack` (`newConfirm`).
        public init(attack: Int) {
            self.init(since: attack, current: attack, ok: nil, streak: 0)
        }

        /// Takes a reading of strike `attack` that is in tune or not
        /// (`confirmReading`); true once the task is done: this strike is in
        /// tune and so was the one before it.
        public mutating func reading(attack: Int, ok: Bool) -> Bool {
            if attack <= since { return false }
            if attack != current {
                if let last = self.ok { streak = last ? streak + 1 : 0 }
                current = attack
            }
            self.ok = ok
            return ok && streak >= 1
        }
    }

    // MARK: - Unison advice

    /// Tasks with more than one string sounding, judged clean as well as on
    /// pitch (`UNISON_TASKS`).
    public static let unisonTasks: Set<Action> = [.unison, .pull, .pair, .third]

    /// What to say when a unison is clean but off target. Adding strings can
    /// move a unison's pitch by a cent or two either way, and retuning one
    /// string makes it beat. The raw value is the web version's.
    public enum UnisonAdvice: String, Sendable, Hashable, CaseIterable {
        /// Two strings: move one string, then make the pair clean with the other.
        case shift2
        /// Three strings: mute one string, move the pair that way, then bring
        /// the third to them.
        case shift3
    }

    /// The advice for a unison task whose strings are `clean` together, with
    /// `status` the status of the reading; nil when there is nothing to say
    /// (`unisonAdvice`). `strings(k)` is the strings per key of key `k`.
    public static func unisonAdvice(
        _ task: Task?, strings: (Int) -> Int, clean: Bool, status: PitchStatus
    ) -> UnisonAdvice? {
        guard let task, unisonTasks.contains(task.action), clean, status != .good, status != .noReading else { return nil }
        let sounding = task.action == .pair ? 2 : strings(task.key)
        return sounding >= 3 ? .shift3 : sounding == 2 ? .shift2 : nil
    }

    // MARK: - Checks

    /// One check as shown, with its beat rate at the targets (JS: a row of
    /// `checkRows`). A third or sixth with the task's key can have a window:
    /// the nearest tuned intervals of the same size below and above it.
    public struct CheckRow: Sendable, Equatable, Hashable {
        public let lo: Int
        public let hi: Int
        /// hi − lo.
        public let semis: Int
        public let partials: PartialPair
        /// Beats per second at the targets; positive when wide.
        public let beat: Double
        /// The slower side of the window, if any.
        public let below: Neighbour?
        /// The faster side of the window, if any.
        public let above: Neighbour?

        public init(lo: Int, hi: Int, semis: Int, partials: PartialPair, beat: Double,
                    below: Neighbour? = nil, above: Neighbour? = nil) {
            self.lo = lo
            self.hi = hi
            self.semis = semis
            self.partials = partials
            self.beat = beat
            self.below = below
            self.above = above
        }
    }

    /// A neighbour in a window: an interval of the same size whose keys are
    /// both tuned, with its beat rate at the targets.
    public struct Neighbour: Sendable, Equatable, Hashable {
        public let lo: Int
        public let hi: Int
        public let partials: PartialPair
        public let beat: Double

        public init(lo: Int, hi: Int, partials: PartialPair, beat: Double) {
            self.lo = lo
            self.hi = hi
            self.partials = partials
            self.beat = beat
        }
    }

    /// Thirds and sixths beat fast enough for the ear to place one between
    /// two neighbours a few per cent apart. Fourths and fifths beat too slowly.
    private static let windowed: Set<Int> = [3, 4, 9]

    /// The checks of `task` with their beat rates at `targets` (`checkRows`):
    /// the interval it is tuned by first, then the others, each once. Left
    /// out: keys off the keyboard (above `top`), intervals without
    /// coincident partials, and coincident partials too low or too high to
    /// hear (40 Hz–5 kHz).
    ///
    /// With `tuned` (the keys tuned before the task, see `tunedBefore`), a
    /// third or sixth with the task's key also gets its window: the tuned
    /// neighbours below and above. A check that is a neighbour in a window is
    /// then left out as a row. The key being tuned is not in `tuned`, so a
    /// neighbour never moves with it.
    public static func checkRows(_ targets: Targets, _ task: Task, top: Int, tuned: Set<Int>? = nil) -> [CheckRow] {
        struct ID: Hashable {
            let lo: Int, hi: Int, partials: PartialPair
        }
        var list: [Check] = []
        if let from = task.from { list.append(Check(min(task.key, from), max(task.key, from))) }
        list += task.checks ?? []
        var seen = Set<ID>()
        var rows: [CheckRow] = []
        for c in list {
            guard c.lo >= 1, c.hi <= top, c.hi < targets.frequency.count,
                  let p = c.partials ?? coincident[c.hi - c.lo] else { continue }
            guard seen.insert(ID(lo: c.lo, hi: c.hi, partials: p)).inserted else { continue }
            let f = partialFreq(targets.frequency[c.lo], targets.inharmonicity[c.lo], p.lower)
            if f < 40 || f > 5000 { continue }
            let semis = c.hi - c.lo
            var below: Neighbour?
            var above: Neighbour?
            if let tuned, windowed.contains(semis), c.lo == task.key || c.hi == task.key {
                func find(_ dir: Int) -> Neighbour? {
                    var lo = c.lo + dir
                    while lo >= 1 && lo + semis <= top {
                        let hi = lo + semis
                        if tuned.contains(lo) && tuned.contains(hi) {
                            return Neighbour(lo: lo, hi: hi, partials: p, beat: intervalBeat(targets, lo, hi, p))
                        }
                        lo += dir
                    }
                    return nil
                }
                below = find(-1)
                above = find(1)
            }
            rows.append(CheckRow(lo: c.lo, hi: c.hi, semis: semis, partials: p,
                                 beat: intervalBeat(targets, c.lo, c.hi, p), below: below, above: above))
        }
        // A check shown as a neighbour in a window needs no row of its own.
        let shown = Set(rows.flatMap { [$0.below, $0.above] }.compactMap { $0 }.map {
            ID(lo: $0.lo, hi: $0.hi, partials: $0.partials)
        })
        return rows.enumerated().filter { i, r in
            (i == 0 && task.from != nil) || !shown.contains(ID(lo: r.lo, hi: r.hi, partials: r.partials))
        }.map(\.element)
    }
}

/// How a key's deviation from its goal stands against the tolerance (JS:
/// statusClass in app.js). The raw value is the web version's.
public enum PitchStatus: String, Sendable, Hashable, CaseIterable {
    /// Within tolerance.
    case good
    /// Outside tolerance but within max(5, 2 × tolerance) cents.
    case warn
    /// Further off than that.
    case bad
    /// No deviation to judge: nothing measured. Stored as "none".
    case noReading = "none"
}

/// a, a ± 1, … b, counting down when b < a (JS: range in order.js).
private func range(_ a: Int, _ b: Int) -> [Int] {
    a <= b ? Array(a...b) : Array((b...a).reversed())
}
