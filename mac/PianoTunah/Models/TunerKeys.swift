import PianoTunahCore

/// What the keyboard, the curve and the key table show of one key.
struct KeyState: Sendable {
    let key: Int
    /// Now: the latest measurement in cents from the target; NaN unmeasured
    /// (Engine.curDev).
    var now: Double
    /// Before: the pass's first measurement in cents; NaN without one
    /// (Engine.beforeDev).
    var before: Double
    /// Now less the overpull goal, which the status judges (Engine.statusDev).
    var deviation: Double
    var status: PitchStatus
    /// The target in cents from equal temperament, and in Hz.
    var targetCents: Double
    var targetHz: Double
    /// Inharmonicity B in use: measured, interpolated or from the model.
    var b: Double
    /// B was measured on this key.
    var measuredB: Bool
    /// The measured B lies far from its neighbours' and is not used.
    var bOutlier: Bool
    /// The measured partial.
    var partial: Int
    /// Now in Hz, of the measured partial; NaN unmeasured.
    var measuredHz: Double
    /// The key is one the running All A survey or the tuning order asks for.
    var planned: Bool
}

/// The keys of the open piano, 1 to `top`: rebuilt on the analysis queue
/// when the engine reports something that changes them (a save, the
/// targets, the key, the mode, the survey or the order), not every frame.
///
/// Equal when the revision is: the views compare that instead of 88 keys,
/// whose NaNs would never compare equal anyway.
struct TunerKeys: Sendable, Equatable {
    /// Grows with every rebuild.
    var revision = 0
    /// Index k − 1 holds key k.
    var states: [KeyState] = []
    /// Some key of the piano has a measured B (also beyond `top`).
    var anyMeasuredB = false

    var top: Int { states.count }

    subscript(k: Int) -> KeyState? {
        states.indices.contains(k - 1) ? states[k - 1] : nil
    }

    init() {}

    /// The engine's keys as they are now. On the analysis queue.
    init(_ engine: Engine, revision: Int) {
        self.revision = revision
        let t = engine.targets
        let piano = engine.piano
        let quick = engine.survey != nil && engine.isQuick
        let orderKey = engine.orderActive ? engine.orderTask?.key : nil
        states = (1...engine.top).map { k in
            let d = engine.statusDev(k)
            return KeyState(
                key: k,
                now: engine.curDev(k),
                before: engine.beforeDev(k),
                deviation: d,
                status: engine.statusClass(d),
                targetCents: t.cents[k],
                targetHz: t.frequency[k],
                b: t.inharmonicity[k],
                measuredB: piano.inharmonicity[k].map(Self.truthy) ?? false,
                bOutlier: engine.bBad.contains(k),
                partial: engine.partialOf(k),
                measuredHz: piano.keys[k]?.hz ?? .nan,
                planned: (quick && Survey.allAKeys.contains(k)) || k == orderKey
            )
        }
        anyMeasuredB = piano.inharmonicity.values.contains(where: Self.truthy)
    }

    /// Whether JS counts the number as true, as the web's `!!B[k]`.
    private static func truthy(_ x: Double) -> Bool { x != 0 && !x.isNaN }

    static func == (a: TunerKeys, b: TunerKeys) -> Bool {
        a.revision == b.revision
    }
}

/// A key that is done (Engine.Event.flash): the keyboard flashes it once per
/// serial.
struct KeyFlash: Sendable, Equatable {
    var key: Int
    var serial: Int
}
