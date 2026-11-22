import Foundation

// The survey and the tuning order as the engine runs them: a port of the
// Survey and Tuning order sections of web/js/engine.js. See Engine.swift.

// MARK: - Survey

extension Engine {
    public func isSurveyed(_ k: Int) -> Bool {
        piano.keys[k]?.mapped == true
    }

    /// The All A plan (JS: isQuick).
    public var isQuick: Bool { surveyPlan == .allA }

    /// The quick survey always remeasures B.
    public func needsB(_ k: Int) -> Bool {
        isQuick || !truthy(piano.inharmonicity[k])
    }

    public func planKeys() -> [Int] {
        Survey.keys(surveyPlan, top: top)
    }

    func newRun() -> Survey.Run {
        Survey.Run(surveyPlan, top: top, isSurveyed: isSurveyed)
    }

    func nextPending(_ k: Int) -> Int? {
        run?.nextPending(surveyPlan, top: top, after: k)
    }

    /// Choose the plan; a running survey starts over with it.
    public func setSurveyPlan(_ p: Survey.Scope) {
        surveyPlan = p
        if survey == nil { return }
        survey = Survey.KeyState()
        run = newRun()
        if let k = nextPending(0) { selectKey(k, manual: false) }
    }

    /// Nothing from another key is kept; the hint shows after a few frames
    /// in a row.
    @discardableResult
    func trackWrongKey(_ other: Int) -> Int {
        guard var sk = survey else { return other }
        sk.wrongFrames = other != 0 ? sk.wrongFrames + 1 : 0
        sk.wrong = sk.wrongFrames >= 3 ? other : 0
        // Drop what was collected: the start of a wrong note can look right.
        if other != 0 {
            sk.pitch = []
            sk.bs = []
            sk.ms = 0
        }
        survey = sk
        return other
    }

    func collectSurvey(_ A: Analyzer, _ k: Int, _ partialHz: Double, _ f1: Double, _ raw: Double) {
        guard let current = survey, let run else { return }
        if trackWrongKey(Survey.wrongKey(current.heard, key: k, raw: raw, ref: median(run.offsets), done: run.done)) != 0 {
            return emit(.survey)
        }
        survey?.pitch.append(partialHz)
        survey?.ms += frameMs
        survey?.lost = false
        if needsB(k), let bs = survey?.bs, bs.count < Survey.bReadings,
           let r = A.inharmonicity(f1: f1, bGuess: targets.inharmonicity[k]) {
            survey?.bs.append(r.b)
        }
        guard let sk = survey, sk.isDone(needsB: needsB(k), surveyPlan) else { return emit(.survey) }

        let hz = median(sk.pitch)
        let n = partialOf(k)
        self.run?.offsets.append(centsBetween(hz, partialFreq(targets.frequency[k], targets.inharmonicity[k], n)))
        // Before stays the first measurement in the pass, as in recordKey.
        var rec = piano.keys[k] ?? Piano.Measurement(hz: hz, n: n, at: wall)
        if rec.beforeHz == nil { rec.beforeHz = hz }
        if rec.beforeN == nil { rec.beforeN = n }
        rec.hz = hz
        rec.n = n
        rec.at = wall
        rec.mapped = true
        piano.keys[k] = rec
        if sk.bs.count >= 3 {
            storeB(k, median(sk.bs))
        } else {
            emit(.dirty)
            recompute()
        }
        emit(.flash(k))
        self.run?.done.insert(k)
        advanceSurvey(k)
    }

    /// Skip the current key of the survey.
    public func skipSurveyKey() {
        guard run != nil else { return }
        run?.skipped.insert(key)
        advanceSurvey(key)
    }

    /// Measure the current key again from the start.
    public func redoSurveyKey() {
        survey = Survey.KeyState()
    }

    func advanceSurvey(_ k: Int) {
        if let next = nextPending(k) { selectKey(next, manual: false) } else { finishSurvey() }
    }

    /// The survey is over: back to Lock at A4, where tuning starts. The
    /// message has what was measured.
    func finishSurvey() {
        let withB = { (ks: [Int]) in ks.filter { truthy(self.piano.inharmonicity[$0]) }.count }
        let all = Array(1...top)
        let quick = isQuick
        let done = SurveyResult(
            quick: quick,
            measuredB: withB(quick ? planKeys() : all),
            keys: quick ? planKeys().count : all.filter(isSurveyed).count,
            skipped: (run?.skipped ?? []).sorted(),
            outliers: bBad.sorted())
        setMode(.lock)
        selectKey(a4, manual: false) // tuning starts in the temperament octave
        emit(.message(.surveyDone(done)))
    }
}

// MARK: - Tuning order

// Optional: any other key or mode can be used meanwhile, and the order waits
// for its key.

extension Engine {
    public var orderActive: Bool {
        orderOn && mode != .survey
    }

    public var orderTask: TuningOrder.Task? {
        order.task(at: orderPos)
    }

    /// The index of a step, or −1 if the order has none.
    public func orderStepIndex(_ id: TuningOrder.StepID) -> Int {
        order.steps.firstIndex { $0.id == id } ?? -1
    }

    /// Keys measured and outside tolerance, for the last step.
    public func recheckKeys() -> [Int] {
        (1...top).filter { curDev($0).isFinite && statusClass(statusDev($0)) != .good }
    }

    /// Build the order again for the strings per key and DSU.
    public func rebuildOrder() {
        let s = settings
        let build = {
            self.order = TuningOrder(
                TuningOrder.Layout(top: self.top, twoStringsTo: s.twoStringsTo, oneStringTo: s.oneStringTo, dsu: s.unisons == "dsu"),
                recheck: self.orderRecheck ?? [])
            self.orderPos = self.order.clamp(self.piano.order)
        }
        build()
        if order.steps[orderPos.step].id == .finish && orderRecheck == nil {
            orderRecheck = recheckKeys() // opened on the last step
            build()
        }
        orderConfirm = TuningOrder.Confirmation(attack: attacks)
        orderAdvice = nil
    }

    /// Select the key the order is on.
    public func followOrder() {
        if let t = orderTask, orderActive { selectKey(t.key, manual: false) }
        emit(.order)
    }

    public func setOrderOn(_ on: Bool) {
        orderOn = on
        log("tuning order \(on ? "on" : "off")")
        if on && mode == .auto { setMode(.lock) }
        followOrder()
    }

    /// Move to a position and select its key. The last step lists the keys
    /// outside tolerance as it begins.
    public func goOrder(_ pos: TuningOrder.Position) {
        let finish = orderStepIndex(.finish)
        if pos.step == finish && orderPos.step != finish {
            orderRecheck = recheckKeys()
        } else if pos.step != finish {
            orderRecheck = nil
        }
        piano.order = pos
        rebuildOrder()
        emit(.dirty)
        followOrder()
    }

    func orderDone() {
        log("tuning order done")
        emit(.message(.orderDone))
    }

    public func orderNext() {
        if let next = order.next(after: orderPos) { goOrder(next) } else { orderDone() }
    }

    public func orderPrev() {
        goOrder(order.previous(before: orderPos) ?? orderPos)
    }

    /// On to the next step.
    public func orderSkip() {
        let step = orderPos.step + 1
        if step < order.steps.count { goOrder(TuningOrder.Position(step: step, index: 0)) } else { orderDone() }
    }

    /// Back to the order's key from another one.
    public func orderBack() {
        if mode == .auto { setMode(.lock) }
        if let t = orderTask { selectKey(t.key, manual: false) }
    }

    /// The treble and the bass get other tasks: the order stays on the key
    /// it was on. v: "one" or "dsu".
    public func setUnisons(_ v: String) {
        let k = orderTask?.key
        let step = orderPos.step
        piano.settings.unisons = v
        rebuildOrder()
        let i = order.steps[step].tasks.firstIndex { $0.key == k } ?? -1
        goOrder(TuningOrder.Position(step: step, index: Swift.max(0, i)))
    }

    /// A steady reading on the order's key: in tune counts, and two strikes
    /// in a row move on. Unisons also need the beat check to have seen the
    /// note clean.
    func trackOrder(_ k: Int) {
        guard let t = orderTask, t.key == k, !ref else { return }
        let s = statusClass(display)
        // Tasks with more than one string sounding must also be clean, not only on pitch.
        let unison = TuningOrder.unisonTasks.contains(t.action)
        // A note too short for the beat check counts on pitch alone.
        let clean = !beating && (beatKnown || beatUnheard)
        let loose = order.steps[orderPos.step].loose
        let ok = loose ? s != .bad : s == .good && !(unison && !clean)
        // A clean unison off target gets a hint on moving it as a whole.
        orderAdvice = loose ? nil : TuningOrder.unisonAdvice(t, strings: strings, clean: clean, status: s)
        let done = orderConfirm.reading(attack: attacks, ok: ok)
        emit(.orderState)
        if !done { return }
        log("order: \(t.action.rawValue) \(noteName(k)) done")
        emit(.flash(k))
        if let next = order.next(after: orderPos) { goOrder(next) } else { orderDone() }
    }
}
