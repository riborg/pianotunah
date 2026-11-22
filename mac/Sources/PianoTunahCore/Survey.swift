// Port of web/js/survey.js. The JS names are given in each doc comment.

/// The survey: measuring the piano key by key before tuning, to learn its
/// inharmonicity (B) and current pitch. No tuning happens during a survey.
///
/// Per key, pitch readings (a median, so beating unisons do not interfere)
/// and estimates of B are collected. B is given up after a certain ringing
/// time and is then interpolated from the neighbours.
public enum Survey {
    /// Pitch readings per key before the key is done (`PITCH_READINGS`).
    public static let pitchReadings = 8

    /// Estimates of B per key before B is known (`B_READINGS`).
    public static let bReadings = 5

    /// The keys of the All A scope, A0–A7 (`QUICK_KEYS`).
    ///
    /// B at the As is enough for the shape of the curve; the keys in between
    /// are interpolated. The ends matter most: the lowest strings often
    /// deviate from the model, and stretch is largest at both ends.
    public static let allAKeys = [1, 13, 25, 37, 49, 61, 73, 85]

    /// Cents a reading may lie from where the keys measured so far in the run
    /// lay before it counts as a wrong key (`OFFSET_LIMIT`).
    public static let offsetLimit: Double = 70

    /// Which keys a survey asks for.
    public enum Scope: String, Sendable, Hashable, CaseIterable {
        /// All A: A0–A7 only. Stored as `"quick"`.
        case allA = "quick"
        /// All keys. Stored as `"full"`.
        case allKeys = "full"

        /// How long a key may ring before its B is given up, in milliseconds
        /// (`bTimeoutMs`). All A exists for B, so it waits longer for clear
        /// overtones.
        public var bTimeoutMs: Double {
            self == .allA ? 6000 : 3000
        }
    }

    /// The keys a survey of `scope` asks for on a piano whose top key is
    /// `top`, in ascending order (`planKeys`).
    public static func keys(_ scope: Scope, top: Int) -> [Int] {
        switch scope {
        case .allA: allAKeys.filter { $0 <= top }
        case .allKeys: top >= 1 ? Array(1...top) : []
        }
    }

    /// A run: one survey from start to finish, with the keys measured or
    /// skipped so far.
    public struct Run: Sendable, Equatable {
        /// Keys measured in this run.
        public var done: Set<Int>
        /// Keys skipped in this run.
        public var skipped: Set<Int>
        /// Cents from target for each key measured in this run, in the order
        /// measured.
        public var offsets: [Double]

        public init(done: Set<Int> = [], skipped: Set<Int> = [], offsets: [Double] = []) {
            self.done = done
            self.skipped = skipped
            self.offsets = offsets
        }

        /// A new run of `scope` (`newRun`). A run of All keys continues where
        /// the last one stopped: keys for which `isSurveyed` holds (the stored
        /// flag `mapped`) start out done. Once every key is surveyed it starts
        /// over. A run of All A always starts from nothing.
        public init(_ scope: Scope, top: Int, isSurveyed: (Int) -> Bool) {
            let keys = Survey.keys(scope, top: top)
            let done = scope == .allKeys ? keys.filter(isSurveyed) : []
            self.init(done: Set(done.count < keys.count ? done : []))
        }

        /// Whether key `k` is measured or skipped in this run (`handled`).
        public func handled(_ k: Int) -> Bool {
            done.contains(k) || skipped.contains(k)
        }

        /// The next key of `scope` after `k` not yet handled, wrapping around
        /// to the lowest; nil when every key is handled (`nextPending`).
        public func nextPending(_ scope: Scope, top: Int, after k: Int) -> Int? {
            let keys = Survey.keys(scope, top: top).filter { !handled($0) }
            return keys.first { $0 > k } ?? keys.first
        }
    }

    /// What key detection heard: the fields of `Analyzer.detectKey` that the
    /// survey uses.
    public struct Detection: Sendable, Equatable {
        /// The key heard, or 0 for none.
        public var key: Int
        /// How clearly the key's partials show.
        public var score: Double
        /// The key's lead over its semitone neighbours, in dB.
        public var margin: Double

        public init(key: Int, score: Double, margin: Double) {
            self.key = key
            self.score = score
            self.margin = margin
        }
    }

    /// The state of the key being measured in a survey (`newKeyState`).
    public struct KeyState: Sendable, Equatable {
        /// Waiting for the key to be struck.
        public var waitAttack = true
        /// Pitch readings so far.
        public var pitch: [Double] = []
        /// Estimates of B so far.
        public var bs: [Double] = []
        /// How long the key has rung, in milliseconds.
        public var ms: Double = 0
        /// The note died away before the key was done.
        public var lost = false
        /// What key detection heard last, if anything.
        public var heard: Detection?
        /// The wrong key reported (see ``Survey/wrongKey(_:key:raw:ref:done:)``),
        /// −1 for a reading off pitch, or 0.
        public var wrong = 0
        /// Frames in a row that heard a wrong key.
        public var wrongFrames = 0

        public init() {}

        /// Whether B is given up for this key: too few estimates after the
        /// ringing time `scope` allows (`bGivenUp`).
        public func bGivenUp(_ scope: Scope) -> Bool {
            bs.count < Survey.bReadings && ms >= scope.bTimeoutMs
        }

        /// Whether the key is done: enough pitch readings and, if `needsB`,
        /// enough estimates of B or B given up (`keyDone`).
        public func isDone(needsB: Bool, _ scope: Scope) -> Bool {
            pitch.count >= Survey.pitchReadings
                && (!needsB || bs.count >= Survey.bReadings || bGivenUp(scope))
        }
    }

    /// Whether a wrong key was struck while measuring key `k` (`wrongKey`).
    ///
    /// Returns the key heard, −1 if only the pitch gives it away, or 0.
    /// Either key detection (`heard`) clearly hears a key two or more
    /// semitones away, or the measured pitch (`raw`, cents from target) is
    /// more than ``offsetLimit`` from where the keys measured so far in the
    /// run lay (`ref`): a neighbour struck by mistake. Detection alone cannot
    /// tell a neighbour from a badly flat piano. A `ref` that is not finite
    /// (no keys measured yet) never gives a key away by pitch. Keys already
    /// measured in the run (`done`) are not reported: the previous key may
    /// still ring, and an octave below has all the partials of the key above.
    public static func wrongKey(_ heard: Detection?, key k: Int, raw: Double, ref: Double, done: Set<Int> = []) -> Int {
        // The key detection clearly hears, if any.
        let clear = heard.flatMap { d in
            d.key != k && d.score > 8 && d.margin >= 6 && !done.contains(d.key) ? d.key : nil
        }
        if let c = clear, abs(c - k) >= 2 { return c }
        if !ref.isFinite || abs(raw - ref) <= offsetLimit { return 0 }
        return clear ?? -1
    }
}
