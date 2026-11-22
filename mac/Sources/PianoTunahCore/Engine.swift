import Foundation

// The tuner without the app: what each frame of sound means for the piano.
// Deviations and status, attacks and the noise gate, following the key,
// measuring, beats, the survey and the tuning order. No views, texts,
// storage, audio or timers: the frame's samples and times come in as
// arguments, and what the app must show goes out as events.
//
// A port of web/js/engine.js, operation by operation and with the same
// thresholds, so the scenarios in Fixtures/engine/ give the same decisions
// and the same numbers to within the ulps that V8's and the platform's libm
// give apart. The survey and the tuning order are in EngineSurveyOrder.swift,
// the types it hands out in EngineTypes.swift.

/// The tuner: one piano, the sound of each frame, and what follows from it.
///
/// A non-Sendable final class. It owns an ``Analyzer`` with large buffers
/// that every frame overwrites, so use one engine from one analysis queue
/// (or actor) only, and call every method, ``frame(_:time:now:wall:ref:)``
/// and the commands alike, from there. The app gets what changed from
/// ``onEvent`` (every event, also those of commands) or from the events a
/// frame returns, and copies what it shows into its own snapshot.
public final class Engine {
    /// The analysis interval in ms (JS: FRAME_MS).
    public static let frameMs: Double = 90
    /// The spectrogram's history, ≈ 9 s (JS: SPEC_COLS).
    public static let spectrogramColumns = 100
    /// Bins of a spectrogram column (JS: SPEC_BINS). Fixed, and at least 2:
    /// ``Analyzer/zoom(_:cents:bins:)`` divides by bins − 1.
    public static let spectrogramBins = 48
    /// A spectrogram column spans ± this many cents (JS: SPEC_CENTS).
    public static let spectrogramCents: Double = 30
    /// The samples each frame should hold: the ring buffer the audio input
    /// fills must be at least this long. The FFT reads the latest 16384,
    /// but the phase refinement needs 24576 below 150 Hz and the
    /// spectrogram's zoom 32768 below 600 Hz; with fewer they fall back to
    /// rougher numbers than the web version's.
    public static let bufferSize = 32768
    /// A reading more than this many cents from the key's last one is saved
    /// only when a new attack gives it again (JS: JUMP).
    static let jumpCents: Double = 50

    /// Called with every event as it happens, from the thread the engine is
    /// used on.
    public var onEvent: ((Event) -> Void)?
    /// The analysis interval in ms, which the survey counts ringing time in.
    public let frameMs: Double
    /// Events collected during ``frame(_:time:now:wall:ref:)``.
    private var events: [Event]?

    // MARK: - State (JS: the fields set in the constructor)

    /// The piano. The engine changes its measurements, inharmonicity,
    /// partials, settings and order; the app may change the rest, and must
    /// call ``recompute()`` after changing settings that move the targets.
    public var piano: Piano
    /// The targets from `computeTargets` (JS: T).
    public internal(set) var targets: Targets
    /// Keys whose measured B is left out, see `bOutliers`.
    public internal(set) var bBad: Set<Int> = []
    public internal(set) var key = a4
    public internal(set) var mode = Mode.auto
    public internal(set) var analyzer: Analyzer?
    /// The level of the latest frame and the one before, in dB.
    public internal(set) var level: Double = -100
    public internal(set) var prevLevel: Double = -100
    /// Levels of the latest four frames, for attack detection.
    public internal(set) var levels: [Double] = []
    /// The noise floor, in dB.
    public internal(set) var noise: Double = -70
    /// A note of the current key is heard.
    public internal(set) var signal = false
    /// The latest readings for the current key, at most ``steadyN``.
    public internal(set) var readings: [Reading] = []
    /// The deviation shown: from the (possibly overpulled) goal, in cents.
    public internal(set) var display = Double.nan
    /// The measured frequency of the partial, from the same readings as
    /// ``display`` (JS: measHz).
    public internal(set) var measuredHz = Double.nan
    /// The readings hold still, see ``steady(_:)``.
    public internal(set) var stable = false
    /// The spectrogram, oldest first; nil for a frame without a reading
    /// (JS: spec).
    public internal(set) var spectrogram: [SpectrogramColumn?] = []
    /// The column of the latest frame (JS: frameCol).
    public internal(set) var frameColumn: SpectrogramColumn?
    /// The beat rate against the goal, in Hz.
    public internal(set) var beatHz = Double.nan
    /// Cents of partials 1–8 from their targets; nil where not heard (JS:
    /// partialDevs).
    public internal(set) var partialDeviations: [Double?] = []
    /// The strobe: the measured partial and the two octaves above it.
    public internal(set) var strobe: [StrobeBand] = []
    /// Recent readings of the two upper strobe bands.
    public internal(set) var strobeReadings: [[Double]] = [[], []]
    /// Auto mode: the candidate key and how many frames in a row it won.
    public internal(set) var candidate = 0
    public internal(set) var candidateCount = 0
    /// Frames in a row the current key has been a clear winner.
    public internal(set) var autoFrames = 0
    /// Auto mode: cents from the target where the current key was heard.
    public internal(set) var shift: Double = 0
    /// Frames of a note skipped before the beat check listens.
    public internal(set) var unisonSkip = 0
    /// The note beats, as last decided.
    public internal(set) var beating = false
    /// The beat check has decided for the current note.
    public internal(set) var beatKnown = false
    /// The audio clock when the beat check last heard the note (s).
    public internal(set) var beatFedAt: Double = 0
    /// The beat check of the current note.
    public internal(set) var beatMeter = BeatMeter()
    /// The audio clock at the end of the latest frame (s).
    public internal(set) var frameTime: Double = 0
    /// The steady clock of the latest frame (ms).
    public internal(set) var now: Double = 0
    /// The wall clock of the latest frame (ms since 1970).
    public internal(set) var wall: Double = 0
    /// A reference tone is audible in the latest frame.
    public internal(set) var ref = false
    /// B readings of the manual measurement.
    public internal(set) var bReadings: [Double] = []
    /// Attacks heard, see ``PendingJump``.
    public internal(set) var attacks = 0
    public internal(set) var inAttack = false
    public internal(set) var jump: PendingJump?
    public internal(set) var stats = Stats()
    /// The manual B measurement, while it runs.
    public internal(set) var measureB: MeasureBRun?
    /// The current key in a survey.
    public internal(set) var survey: Survey.KeyState?
    /// The survey as a whole.
    public internal(set) var run: Survey.Run?
    public internal(set) var surveyPlan = Survey.Scope.allA
    /// The tuning order is shown and followed.
    public internal(set) var orderOn = false
    public internal(set) var order: TuningOrder
    public internal(set) var orderPos = TuningOrder.Position.start
    /// Strikes towards the current task.
    public internal(set) var orderConfirm = TuningOrder.Confirmation(attack: 0)
    /// Keys outside tolerance when the last step began.
    public internal(set) var orderRecheck: [Int]?
    /// The advice for the latest strike on a unison.
    public internal(set) var orderAdvice: TuningOrder.UnisonAdvice?
    /// The readings were taken while a reference tone was heard.
    public internal(set) var refTainted = false

    /// An engine on `piano`, opened (see ``open(_:)``); `onEvent` gets the
    /// events from then on, the first of them `targets`.
    public init(piano: Piano, frameMs: Double = Engine.frameMs, onEvent: ((Event) -> Void)? = nil) {
        self.piano = piano
        self.frameMs = frameMs
        self.onEvent = onEvent
        targets = computeTargets(piano.settings, measuredB: piano.inharmonicity)
        order = TuningOrder(TuningOrder.Layout(piano.settings))
        open(piano)
    }

    func emit(_ event: Event) {
        events?.append(event)
        onEvent?(event)
    }

    func log(_ line: String) {
        emit(.log(line))
    }

    // MARK: - Derived values

    public var settings: Settings { piano.settings }

    public var tolerance: Double { orDefault(settings.tolerance, 1) }

    /// A7 on older pianos, otherwise C8.
    public var top: Int { settings.keyCount == 85 ? 85 : keyCount }

    public func partialOf(_ k: Int) -> Int {
        if let p = piano.partials[k], p != 0 { return p }
        return defaultPartial(k)
    }

    public func strings(_ k: Int) -> Int {
        k <= settings.oneStringTo ? 1 : k <= settings.twoStringsTo ? 2 : 3
    }

    /// Measurements are stored as the frequency of the measured partial, so
    /// they stay valid when reference, temperament, stretch or B change.
    func devOf(_ k: Int, _ hz: Double?, _ n: Int?) -> Double {
        guard truthy(hz), let n, n != 0 else { return .nan }
        return centsBetween(hz!, partialFreq(targets.frequency[k], targets.inharmonicity[k], n))
    }

    /// Now: the key's latest measurement in cents from its target.
    public func curDev(_ k: Int) -> Double {
        let r = piano.keys[k]
        return devOf(k, r?.hz, r?.n)
    }

    /// Before: the key's first measurement in the pass.
    public func beforeDev(_ k: Int) -> Double {
        let r = piano.keys[k]
        return devOf(k, r?.beforeHz, r?.beforeN)
    }

    /// ``curDev(_:)`` of every key, indexed by key (0 unused).
    public func heardDevs() -> [Double] {
        (0...keyCount).map(curDev)
    }

    /// Overpull: tune past the target by a share of how far off the key
    /// started.
    public func goal(_ k: Int) -> Double {
        let b = beforeDev(k)
        let p = orDefault(settings.overpull, 0)
        return b.isFinite && p != 0 ? (-p / 100) * b : 0
    }

    public func statusDev(_ k: Int) -> Double {
        curDev(k) - goal(k)
    }

    /// good: within tolerance; warn: within 5 cents or twice the tolerance;
    /// bad; noReading: no value.
    public func statusClass(_ d: Double) -> PitchStatus {
        if !d.isFinite { return .noReading }
        let a = abs(d)
        if a <= tolerance { return .good }
        return a <= jsMathMax(5, tolerance * 2) ? .warn : .bad
    }

    /// Before values in the middle of the piano (C3–C6).
    public func midBefore() -> [Double] {
        (28...64).map(beforeDev).filter(\.isFinite)
    }

    /// Where the middle of the piano was before tuning: the median of
    /// ``midBefore()``, or NaN with fewer than three of them.
    public var midShift: Double {
        let mid = midBefore()
        return mid.count >= 3 ? median(mid) : .nan
    }

    /// The fundamental to play as a reference tone, including overpull.
    public func goalF1(_ k: Int) -> Double {
        targets.frequency[k] * pow(2, goal(k) / 1200)
    }

    /// The sine's frequency: the goal at the measured partial.
    public func sineFreq(_ k: Int? = nil) -> Double {
        let k = k ?? key
        return partialFreq(goalF1(k), targets.inharmonicity[k], partialOf(k))
    }

    public var passStats: PassStats {
        var measured = 0
        var ok = 0
        for k in 1...top {
            let d = statusDev(k)
            if !d.isFinite { continue }
            measured += 1
            if statusClass(d) == .good { ok += 1 }
        }
        return PassStats(measured: measured, ok: ok)
    }

    public var refAdvice: RefAdvice {
        let m = midShift
        if !m.isFinite { return .none }
        if abs(m) < 3 { return .near(m: m) }
        let ref = settings.refA4
        let p = recommendedOverpull(m)
        var a = RefOffset(m: m, hz: ref * pow(2, m / 1200), p: p)
        if p != 0 {
            let o = (-p / 100) * m
            a.o = o
            a.ohz = ref * pow(2, o / 1200)
            a.big = m < -25
        }
        return .off(a)
    }

    /// The overpull to suggest for the pitch raise: 0 when none or unknown.
    public var suggestedOverpull: Double {
        let m = midShift
        return m.isFinite ? recommendedOverpull(m) : 0
    }

    public var pitchAdvice: PitchAdvice? {
        let m = midShift
        return m.isFinite ? PitchAdvice(m: m, off: abs(m) >= 10) : nil
    }

    /// The reference that puts the middle of the piano on target: from the
    /// before values in the middle, otherwise the key sounding now. NaN when
    /// there is neither (before ``clampRef(_:)``).
    public var fitRefHz: Double {
        var shift = midShift
        if !shift.isFinite {
            if signal && display.isFinite { shift = display + goal(key) } else { return .nan }
        }
        return settings.refA4 * pow(2, shift / 1200)
    }

    // MARK: - The piano

    /// A piano becomes the current one, with its targets and tuning order.
    public func open(_ piano: Piano) {
        self.piano = piano
        orderRecheck = nil
        resetReadings()
        updateTargets()
        rebuildOrder()
        emit(.targets)
    }

    func updateTargets() {
        targets = computeTargets(settings, measuredB: piano.inharmonicity)
        bBad = bOutliers(piano.inharmonicity)
    }

    /// The settings or the measured B changed.
    public func recompute() {
        updateTargets()
        emit(.targets)
    }

    /// The microphone started with this sample rate.
    public func startAudio(sampleRate: Double) {
        analyzer = Analyzer(sampleRate: sampleRate)
        noise = -70
    }

    /// The microphone stopped.
    public func stopAudio() {
        signal = false
    }

    /// A step up or down of the measured partial of the current key.
    public func setPartial(_ delta: Int) {
        let k = key
        let n = Self.clampPartial(partialOf(k) + delta)
        if n == defaultPartial(k) { piano.partials[k] = nil } else { piano.partials[k] = n }
        resetReadings()
    }

    /// Strings per key, clamped; the order is built again. Returns what was
    /// set.
    @discardableResult
    public func setStrings(two: Double, one: Double) -> (two: Int, one: Int) {
        let c = Self.clampStrings(top: top, two: two, one: one)
        piano.settings.twoStringsTo = c.two
        piano.settings.oneStringTo = c.one
        rebuildOrder()
        return c
    }

    /// End the pass: save a summary to the history and clear the
    /// measurements. Inharmonicity and settings are kept. wall: ms since 1970.
    public func newPass(wall: Double) {
        let ks = Array(1...top)
        let after = ks.map(statusDev).filter(\.isFinite)
        let before = ks.map(beforeDev).filter(\.isFinite)
        func meanAbs(_ a: [Double]) -> Double {
            a.isEmpty ? 0 : a.reduce(0) { $0 + abs($1) } / Double(a.count)
        }
        // JS Date drops the fraction of a millisecond.
        let now = Piano.timestamp(Date(timeIntervalSince1970: wall.rounded(.towardZero) / 1000))
        if !after.isEmpty {
            let pass = Piano.PassSummary(
                startedAt: piano.passStartedAt, endedAt: now, refA4: settings.refA4, measured: after.count,
                meanAbsBefore: meanAbs(before), meanAbsAfter: meanAbs(after))
            piano.history = Array((piano.history + [pass]).suffix(Piano.historyLimit))
        }
        piano.keys = [:]
        piano.passStartedAt = now
        piano.order = .start
        orderRecheck = nil
        rebuildOrder()
        resetReadings()
        recompute()
    }

    // MARK: - Key and mode

    func resetReadings() {
        readings = []
        spectrogram = []
        beatHz = .nan
        display = .nan
        measuredHz = .nan
        stable = false
        partialDeviations = []
        strobe = []
        strobeReadings = [[], []]
        bReadings = []
        autoFrames = 0
        resetBeating()
    }

    /// Select key k, clamped to the keyboard. manual: chosen in the app,
    /// which leaves auto mode.
    public func selectKey(_ k: Int, manual: Bool = true) {
        let k = Swift.max(1, Swift.min(top, k))
        if manual && mode == .auto { setMode(.lock) }
        if k == key { return }
        log("key \(noteName(k)) (\(manual ? "chosen" : mode.rawValue))")
        key = k
        resetReadings()
        if survey != nil { survey = Survey.KeyState() }
        emit(.key(k, manual: manual))
    }

    public func setMode(_ m: Mode) {
        if m != mode { log("mode \(m.rawValue)") }
        mode = m
        survey = m == .survey ? Survey.KeyState() : nil
        run = m == .survey ? newRun() : nil
        bReadings = []
        if m == .survey, let k = nextPending(0) { selectKey(k, manual: false) }
        emit(.mode(m))
    }

    // MARK: - A frame of sound

    /// One frame of sound, every ``frameMs`` of audio.
    ///
    /// - buffer: the latest samples from the ring buffer, oldest first, at
    ///   least ``bufferSize`` (32768) of them; see ``bufferSize``. A buffer
    ///   shorter than the analyzer's FFT (16384), or one before
    ///   ``startAudio(sampleRate:)``, is skipped (``Idle/shortBuffer``):
    ///   only the clocks and ``stats`` move and the spectrogram scrolls by
    ///   one empty column; the signal and the survey key stay as they were, so a short first buffer after a device change
    ///   is harmless. A buffer between the FFT size and ``bufferSize`` is
    ///   analysed with coarser bass and zoom and counted in
    ///   ``Stats/undersized``.
    /// - time: the audio clock when the buffer ends, in s.
    /// - now: a steady clock in ms, for the B measurement.
    /// - wall: ms since 1970, for saved measurements.
    /// - ref: a reference tone is audible, so nothing is saved and the key
    ///   is not followed.
    ///
    /// Returns why no reading was taken (nil if one was) and the events of
    /// the frame, which ``onEvent`` has had too.
    @discardableResult
    public func frame(_ buffer: [Float], time: Double, now: Double = 0, wall: Double = 0, ref: Bool = false) -> FrameResult {
        events = []
        self.now = now
        self.wall = wall
        self.ref = ref
        stats.frames += 1
        frameColumn = nil
        let idle = analyseFrame(buffer, time: time)
        spectrogram.append(frameColumn)
        if spectrogram.count > Self.spectrogramColumns { spectrogram.removeFirst() }
        let out = events ?? []
        events = nil
        return FrameResult(idle: idle, events: out)
    }

    private func analyseFrame(_ buf: [Float], time: Double) -> Idle? {
        frameTime = time // when buf ends, for the beat check
        // Analyzer.load traps on fewer than its size. A short buffer (the
        // first after a device change) is skipped: it is counted, but the
        // signal, the survey key and everything else stay as they were, so
        // a glitch in the middle of a note does not drop the gate or lose
        // the key.
        guard let analyzer, buf.count >= analyzer.size else {
            stats.idle[Idle.shortBuffer.description, default: 0] += 1
            return .shortBuffer
        }
        // Shorter than bufferSize still works, but refine (below 150 Hz)
        // and zoom use shorter windows; count it so the app can notice.
        if buf.count < Self.bufferSize { stats.undersized += 1 }
        let lvl = rmsDb(buf)
        prevLevel = level
        level = lvl
        levels.append(lvl)
        if levels.count > 4 { levels.removeFirst() }
        let attack = lvl - minLevel() > 12
        if attack && !inAttack { attacks += 1 } // once per attack, though it shows for a few frames
        inAttack = attack
        // A new attack: the previous note's tail is not part of this one's reading.
        if attack {
            readings = []
            unisonSkip = 0
            beatKnown = false
            beatFedAt = frameTime
            beatMeter.reset()
        }
        // Noise floor: follows quickly down, slowly up, and hardly at all
        // while a note is heard, so a long decay is not mistaken for noise.
        let up = signal ? 0.02 : 0.15
        noise = lvl < noise ? lvl : noise + jsMathMin(up, (lvl - noise) * 0.01)
        // The survey waits for an attack so the previous key's decay is not measured.
        if survey?.waitAttack == true {
            if lvl - prevLevel <= 6 { return idle(.waitingForAttack) }
            survey?.waitAttack = false
        }
        // A note starts 10 dB above the noise and is followed down to 5 dB.
        if lvl < gate { return idle(.quiet) }

        analyzer.load(buf)
        if mode == .auto {
            // Keys measured in this pass are also looked for where they
            // were heard, so a key far from its target is not taken for its
            // neighbour.
            let d = analyzer.detectKey(targets, prevKey: key, top: top, heard: heardDevs())
            // The microphone hears the reference tone too; following it
            // would move the key, and the sine with it, to whatever the
            // speaker plays.
            if !ref { followDetectedKey(d) }
            // Only the current key's own sound gives a reading.
            if d.key != key || d.margin < 2 { return idle(d.key != key ? .hears(d.key) : .unsure) }
            shift = d.shift
        } else if survey != nil {
            survey?.heard = analyzer.detectKey(targets, prevKey: key, top: top).surveyDetection
        }
        return measureCurrent(analyzer, buf)
    }

    /// Math.min(...levels) and Math.max(...levels).
    private func minLevel() -> Double { levels.reduce(Double.infinity, jsMathMin) }
    private func maxLevel() -> Double { levels.reduce(-Double.infinity, jsMathMax) }

    /// The level a note must reach to be heard (dB).
    public var gate: Double { jsMathMax(noise + (signal ? 5 : 10), -72) }

    /// Switch key when the same candidate wins two frames in a row by at
    /// least 3 dB over its neighbours; right after an attack (6 dB up within
    /// four frames), one frame with a 10 dB lead is enough. Count how long
    /// the current key has been a clear winner; only then does auto mode save.
    private func followDetectedKey(_ d: Analyzer.KeyDetection) {
        autoFrames = d.score > 8 && d.margin >= 6 && d.key == key ? autoFrames + 1 : 0
        if d.score <= 8 { return }
        candidateCount = d.key == candidate ? candidateCount + 1 : 1
        candidate = d.key
        let attack = level - minLevel() > 6
        let frames = attack && d.margin >= 10 ? 1 : 2
        if candidateCount >= frames && d.margin >= 3 && d.key != key { selectKey(d.key, manual: false) }
    }

    func idle(_ why: Idle) -> Idle {
        stats.idle[why.description, default: 0] += 1
        signal = false
        if let s = survey, !s.waitAttack, !s.pitch.isEmpty { survey?.lost = true }
        return why
    }

    private func measureCurrent(_ A: Analyzer, _ buf: [Float]) -> Idle? {
        let k = key
        let T = targets
        let n = partialOf(k)
        let target = partialFreq(T.frequency[k], T.inharmonicity[k], n)
        // Auto: around where detection heard the key. Locked key: wide
        // window so that even a badly flat piano is found.
        let auto = mode == .auto
        guard let m = A.measure(target * pow(2, (auto ? shift : 0) / 1200), cents: auto ? 50 : 150, minProm: 8) else {
            // A key far away has no partial near the target, but detection still hears it.
            if let sk = survey, let run, !ref {
                trackWrongKey(Survey.wrongKey(sk.heard, key: k, raw: .nan, ref: .nan, done: run.done))
            }
            return idle(.noPartial)
        }

        let raw = centsBetween(m.frequency, target)
        let ref = self.ref
        if !ref && refTainted { readings = [] } // drop readings of the reference tone
        refTainted = ref
        readings.append(Reading(cents: raw, hz: m.frequency))
        if !ref { trackBeating(buf, A.sampleRate, m.frequency, m.prom) }
        if readings.count > steadyN { readings.removeFirst() }
        let last = Array(readings.suffix(5))
        let cs = last.map(\.cents)
        let sure = !auto || autoFrames >= 3
        stable = !ref && sure && steady(readings.map(\.cents))
        signal = true
        stats.readings += 1

        let g = goal(k)
        display = median(cs) - g
        measuredHz = median(last.map(\.hz))
        let center = target * pow(2, g / 1200) // the beat view is centred on the target including overpull
        beatHz = center * (pow(2, display / 1200) - 1)
        frameColumn = SpectrogramColumn(
            magnitudes: A.zoom(center, cents: Self.spectrogramCents, bins: Self.spectrogramBins), cents: display)
        partialDeviations = (0..<8).map { i -> Double? in
            let fi = partialFreq(T.frequency[k], T.inharmonicity[k], i + 1)
            if fi > A.sampleRate * 0.45 || fi < 40 { return nil }
            let mi = i + 1 == n ? m : A.measure(fi, cents: 50, minProm: 8)
            return mi.map { centsBetween($0.frequency, fi) }
        }

        // Strobe: the measured partial and the two octaves above it, each
        // against its own target. The upper ones are searched where the
        // measured partial says they should be and smoothed like the main
        // reading.
        strobe = [StrobeBand(partial: n, cents: display)]
        for (i, p) in [2 * n, 4 * n].enumerated() {
            let fp = partialFreq(T.frequency[k], T.inharmonicity[k], p)
            let sk = fp < A.sampleRate * 0.45 ? A.measure(fp * pow(2, raw / 1200), cents: 30, minProm: 8) : nil
            strobeReadings[i].append(sk.map { centsBetween($0.frequency, fp) - g } ?? .nan)
            if strobeReadings[i].count > 5 { strobeReadings[i].removeFirst() }
            let ok = strobeReadings[i].filter(\.isFinite)
            strobe.append(StrobeBand(partial: p, cents: ok.count >= 3 ? median(ok) : .nan))
        }

        if stable && orderActive { trackOrder(k) }

        // Save the value that is shown. During a survey, collectSurvey saves
        // instead. (trackOrder may have moved on and cleared `stable`.)
        if stable && survey == nil {
            let hz = median(last.map(\.hz))
            if jumpConfirmed(k, n, hz) { recordKey(k, n, hz) }
        }

        let f1 = T.frequency[k] * pow(2, raw / 1200)
        if !ref, let mb = measureB, mb.key == k, let r = A.inharmonicity(f1: f1, bGuess: T.inharmonicity[k]) {
            bReadings.append(r.b)
        }
        if survey != nil && !ref { collectSurvey(A, k, m.frequency, f1, raw) }
        if let mb = measureB, now > mb.until { finishMeasureB() }
        return nil
    }

    // MARK: - Beats

    /// A unison out of tune beats: the measured partial pulses
    /// (``BeatMeter``). Its level is followed from 0.5 s after the attack,
    /// while the note is clearly heard and not being damped. The hint stays
    /// until a later note on the key is clean. A note that fades before the
    /// check has 1.5 s of it cannot be judged; ``beatUnheard`` tells the
    /// order so, if the check heard at least 0.5 s of it and found no beat
    /// starting.
    private func trackBeating(_ buf: [Float], _ sampleRate: Double, _ f: Double, _ prom: Double) {
        if prom < 25 || level < maxLevel() - 12 { return }
        beatFedAt = frameTime
        if unisonSkip < 6 {
            unisonSkip += 1
            return
        }
        // One pulse and one verdict per add: the verdict counts hits and
        // misses in a row, so a second one would count this add twice.
        beatMeter.add(buf, sampleRate: sampleRate, frequency: f, time: frameTime)
        let pulse = beatMeter.pulse()
        if let b = beatMeter.beats(given: pulse) {
            beating = b
            beatKnown = true
        }
    }

    public var beatUnheard: Bool {
        !beatKnown && beatMeter.quiet && frameTime - beatFedAt > 0.3
    }

    private func resetBeating() {
        beatMeter.reset()
        unisonSkip = 0
        beating = false
        beatKnown = false
        beatFedAt = frameTime
    }

    // MARK: - Saving measurements

    /// A reading more than ``jumpCents`` from the key's last one is saved
    /// only when a new attack gives it again (within 10 cents). Another note
    /// still ringing or a neighbour struck by mistake was saved as A4 at −94
    /// cents. Tuning moves the reading in smaller steps between strikes, so
    /// it is not held up.
    private func jumpConfirmed(_ k: Int, _ n: Int, _ hz: Double) -> Bool {
        guard let rec = piano.keys[k], truthy(rec.hz), rec.n == n, !(abs(centsBetween(hz, rec.hz)) <= Self.jumpCents) else {
            jump = nil
            return true
        }
        let same = jump.map { $0.key == k && abs(centsBetween(hz, $0.hz)) < 10 } ?? false
        if same, let j = jump, attacks > j.attack {
            jump = nil
            return true
        }
        if !same {
            jump = PendingJump(key: k, hz: hz, attack: attacks)
            let c = centsBetween(hz, rec.hz)
            log("not saved: \(noteName(k)) \(logCents(c, 0)) cents from its last reading, waiting for a new attack")
            emit(.message(.jump(key: k, cents: c)))
        }
        return false
    }

    private func recordKey(_ k: Int, _ n: Int, _ hz: Double) {
        var rec = piano.keys[k] ?? Piano.Measurement(hz: hz, n: n, at: wall)
        if !truthy(rec.beforeHz) { // first measurement in the pass
            rec.beforeHz = hz
            rec.beforeN = n
        }
        rec.hz = hz
        rec.n = n
        rec.at = wall
        piano.keys[k] = rec
        if k != stats.savedKey || wall - stats.savedAt > 2000 {
            let c = centsBetween(hz, partialFreq(targets.frequency[k], targets.inharmonicity[k], n))
            log("saved \(noteName(k)) \(logCents(c)) cents")
            stats.savedKey = k
            stats.savedAt = wall
        }
        emit(.saved(k))
    }

    func storeB(_ k: Int, _ b: Double) {
        log("B \(noteName(k)) = \(jsToExponential(b, 2))")
        piano.inharmonicity[k] = toPrecision4(b)
        emit(.dirty)
        recompute()
    }

    /// Measure B of the current key from the readings of the next 4 s. now:
    /// ms on the clock `frame` gets. Returns the run, for a timeout that
    /// calls ``finishMeasureB()`` if the note dies away first.
    @discardableResult
    public func startMeasureB(now: Double) -> MeasureBRun {
        bReadings = []
        let mb = MeasureBRun(key: key, until: now + 4000)
        measureB = mb
        emit(.measureB(on: true))
        return mb
    }

    /// End the B measurement: B is stored if there were three readings.
    /// Nothing happens if none runs.
    public func finishMeasureB() {
        guard let mb = measureB else { return }
        let k = mb.key
        measureB = nil
        emit(.measureB(on: false))
        if bReadings.count >= 3 {
            let b = median(bReadings)
            storeB(k, b)
            emit(.message(bBad.contains(k) ? .bOutlier(key: k, b: b) : .bMeasured(key: k, b: b)))
        } else {
            emit(.message(.bFailed))
        }
        bReadings = []
    }
}
