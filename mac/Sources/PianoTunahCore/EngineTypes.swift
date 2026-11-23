import Foundation

// The values the engine hands out (Engine.swift), and the clamping rules for
// settings typed or stepped in the app. A port of the parts of
// web/js/engine.js that are data; the JS names are given in each doc comment.

extension Engine {
    /// How the key is chosen.
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        /// The key follows what is played.
        case auto
        /// The key stays where it was chosen.
        case lock
        /// The survey asks for each key in turn.
        case survey
    }

    /// What happened, in the order it happened (JS: emit(type, data)). The
    /// app shows these; none of them carries text for the user.
    public enum Event: Sendable, Equatable {
        /// Another key is selected; `manual` if chosen in the app.
        case key(Int, manual: Bool)
        /// The mode changed.
        case mode(Mode)
        /// The targets were computed again.
        case targets
        /// The piano changed and should be saved.
        case dirty
        /// A measurement of the key was saved (the piano is dirty too).
        case saved(Int)
        /// The key is done: surveyed, or a task of the order.
        case flash(Int)
        /// The survey's state for the key changed.
        case survey
        /// The order moved to another position.
        case order
        /// A strike on the order's key was judged.
        case orderState
        /// The manual B measurement started or ended.
        case measureB(on: Bool)
        /// Something to tell the user; the app writes the text.
        case message(Message)
        /// A line for the debug log, which is not translated.
        case log(String)
    }

    /// Something to tell the user (JS: the message event's id and numbers).
    public enum Message: Sendable, Equatable {
        /// A reading `cents` from the key's last one was not saved; the next
        /// attack must give it again.
        case jump(key: Int, cents: Double)
        /// B was measured and stored.
        case bMeasured(key: Int, b: Double)
        /// B was measured and stored, but lies far from its neighbours'.
        case bOutlier(key: Int, b: Double)
        /// Too few readings to measure B.
        case bFailed
        /// The survey is over.
        case surveyDone(SurveyResult)
        /// The tuning order is done.
        case orderDone

        /// The web version's id of the message.
        public var id: String {
            switch self {
            case .jump: "jump"
            case .bMeasured: "bMeasured"
            case .bOutlier: "bOutlier"
            case .bFailed: "bFailed"
            case .surveyDone: "surveyDone"
            case .orderDone: "orderDone"
            }
        }
    }

    /// What a finished survey measured (JS: the surveyDone message).
    public struct SurveyResult: Sendable, Equatable {
        /// The All A plan (JS: quick).
        public var quick: Bool
        /// Keys with a measured B: of the plan's keys, or of all keys in a
        /// full survey (JS: b).
        public var measuredB: Int
        /// The plan's keys, or the keys surveyed in a full survey (JS: n).
        public var keys: Int
        /// The keys skipped in this run, ascending.
        public var skipped: [Int]
        /// The keys whose measured B is left out (see `bOutliers`), ascending.
        public var outliers: [Int]
    }

    /// Why a frame gave no reading (JS: the string frame() returns).
    public enum Idle: Sendable, Equatable, CustomStringConvertible {
        /// The buffer is shorter than the analyzer's FFT, or the audio has
        /// not started. Not in the web version, where it cannot happen.
        case shortBuffer
        /// The survey waits for the key to be struck.
        case waitingForAttack
        /// Below the noise gate.
        case quiet
        /// Auto mode hears another key.
        case hears(Int)
        /// Auto mode hears the key, but not clearly.
        case unsure
        /// No partial near the target.
        case noPartial

        /// The web version's text, for the debug log.
        public var description: String {
            switch self {
            case .shortBuffer: "short buffer"
            case .waitingForAttack: "waiting for attack"
            case .quiet: "quiet"
            case .hears(let k): "hears \(noteName(k))"
            case .unsure: "unsure"
            case .noPartial: "no partial"
            }
        }
    }

    /// What a frame gave: why there was no reading (nil if there was one),
    /// and the events of the frame.
    public struct FrameResult: Sendable, Equatable {
        public var idle: Idle?
        public var events: [Event]
    }

    /// One reading of the current key: cents from its target (JS: c), and
    /// the measured partial's frequency.
    public struct Reading: Sendable, Equatable {
        public var cents: Double
        public var hz: Double
    }

    /// A column of the spectrogram: the zoomed spectrum around the target
    /// (dB, from +30 to −30 cents) and the reading shown (JS: { col, c }).
    public struct SpectrogramColumn: Sendable, Equatable {
        public var magnitudes: [Float]
        public var cents: Double
    }

    /// A band of the strobe: a partial and its deviation from its own goal
    /// (JS: { p, c }); NaN while not known.
    public struct StrobeBand: Sendable, Equatable {
        public var partial: Int
        public var cents: Double
    }

    /// A reading far from the key's last one, waiting for a new attack (JS:
    /// jump { k, hz, attack }).
    public struct PendingJump: Sendable, Equatable {
        public var key: Int
        public var hz: Double
        /// The attack it was heard after.
        public var attack: Int
    }

    /// A manual B measurement (JS: measureB { k, until }).
    public struct MeasureBRun: Sendable, Equatable {
        public var key: Int
        /// When it ends, in ms on the steady clock `frame` gets.
        public var until: Double
    }

    /// Counts for the debug log (JS: stats).
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        public var readings = 0
        /// Frames without a reading, by the reason's text.
        public var idle: [String: Int] = [:]
        /// Frames analysed with fewer than ``Engine/bufferSize`` samples:
        /// a ring buffer too small for the bass refinement and the zoom.
        /// It grows every frame while that lasts, so check for non-zero.
        public var undersized = 0
        /// The key and wall time of the latest save that was logged.
        public var savedKey = 0
        public var savedAt: Double = 0
    }

    /// Keys measured in the pass and in tolerance, for the Pass tab.
    public struct PassStats: Sendable, Equatable {
        public var measured: Int
        public var ok: Int
    }

    /// The advice under the reference (JS: refAdvice()).
    public enum RefAdvice: Sendable, Equatable {
        /// Fewer than three keys measured in the middle.
        case none
        /// The middle is within 3 cents; m is its median.
        case near(m: Double)
        /// The middle is off.
        case off(RefOffset)
    }

    /// The middle of the piano is m cents off: `hz` is the reference that
    /// would fit, `p` the overpull to use when raising. With an overpull,
    /// `o` is the overpulled shift, `ohz` its reference and `big` whether
    /// the piano is more than 25 cents flat; otherwise those are nil.
    public struct RefOffset: Sendable, Equatable {
        public var m: Double
        public var hz: Double
        public var p: Double
        public var o: Double?
        public var ohz: Double?
        public var big: Bool?
    }

    /// Where the piano is, for the order's first two steps (JS:
    /// pitchAdvice()): m cents, off when 10 or more.
    public struct PitchAdvice: Sendable, Equatable {
        public var m: Double
        public var off: Bool
    }

    // MARK: - Clamping rules

    /// The reference: 380–480 Hz, to 0.1 Hz (JS: clampRef).
    public static func clampRef(_ hz: Double) -> Double {
        jsRound(jsMathMax(380, jsMathMin(480, hz)) * 10) / 10
    }

    /// The size in cm within the piano kind's range; 0 or NaN gives the
    /// kind's default (JS: clampSize). An unknown kind counts as an upright.
    public static func clampSize(_ kind: String, _ cm: Double) -> Double {
        let k = pianoKind(kind) ?? pianoKinds[0]
        return jsRound(jsMathMax(k.minCm, jsMathMin(k.maxCm, cm == 0 || cm.isNaN ? k.defaultCm : cm)))
    }

    /// Strings per key: within the keyboard, one string never above two;
    /// 0 or NaN is 0 (JS: clampStrings).
    public static func clampStrings(top: Int, two: Double, one: Double) -> (two: Int, one: Int) {
        func clamp(_ v: Double) -> Int {
            Int(jsMathMax(0, jsMathMin(Double(top), jsRound(v.isNaN ? 0 : v))))
        }
        let t = clamp(two)
        return (t, Swift.min(clamp(one), t))
    }

    /// The measured partial: 1–8 (JS: clampPartial).
    public static func clampPartial(_ n: Int) -> Int { Swift.max(1, Swift.min(8, n)) }

    /// The keys a step of the tuning order names in its title and text,
    /// from and to (to is below from for the pull and the bass); nil for a
    /// step without (JS: stepRange).
    public static func stepRange(_ id: TuningOrder.StepID, top: Int) -> (from: Int, to: Int)? {
        let strip = TuningOrder.strip
        switch id {
        case .strip: return (strip.lowerBound, strip.upperBound)
        case .pull: return (strip.upperBound, strip.lowerBound)
        case .temperament: return (33, 44)
        case .upper: return (45, strip.upperBound - 1)
        case .treble: return (strip.upperBound + 1, top)
        case .bass: return (strip.lowerBound - 1, 1)
        default: return nil
        }
    }
}

// MARK: - JavaScript helpers

/// Math.min and Math.max: NaN if either is NaN (Swift's min and max are not).
@inline(__always) func jsMathMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }
@inline(__always) func jsMathMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }

/// Whether JS counts a number as true: not missing, 0 or NaN.
@inline(__always) func truthy(_ x: Double?) -> Bool {
    guard let x else { return false }
    return x != 0 && !x.isNaN
}

/// JS `Number(x) || fallback` for a number already converted.
@inline(__always) func orDefault(_ x: Double, _ fallback: Double) -> Double { x == 0 || x.isNaN ? fallback : x }

/// Cents with sign for the debug log, which is not translated (JS: logC).
func logCents(_ c: Double, _ d: Int = 1) -> String {
    if !c.isFinite { return "–" }
    let text = jsToFixed(Swift.abs(c), d)
    let zero = Double(text) == 0
    return (zero ? "±" : c > 0 ? "+" : "−") + text
}

/// JS `Number(x.toPrecision(4))`: x to four significant digits.
func toPrecision4(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    return Double(jsToExponential(x, 3)) ?? x
}
