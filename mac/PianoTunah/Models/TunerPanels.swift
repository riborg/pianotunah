import PianoTunahCore

/// What the survey panel shows: the run and the key being measured (JS:
/// renderSurveyPanel). Made on the analysis queue while a survey runs.
struct SurveyState: Sendable, Equatable {
    /// What the survey asks of the user now.
    enum Step: Sendable, Equatable {
        /// Waiting for the key to be struck.
        case strike
        /// The note died away before the key was done.
        case lost
        /// Collecting readings.
        case listening
        /// Another key was heard: `heard`.
        case wrong(heard: Int)
        /// The pitch lies more than `Survey.offsetLimit` from the keys
        /// measured so far in the run.
        case offPitch
    }

    /// The B chip.
    enum BReadings: Sendable, Equatable {
        /// The key's B is measured already and not needed again.
        case known
        /// The overtones were too weak: B is given up for the key.
        case skipped
        /// Estimates so far, of `needed`.
        case reading(count: Int, needed: Int)
    }

    var scope: Survey.Scope
    /// The keys of the plan handled in the run (measured or skipped), and all
    /// of them.
    var done: Int
    var total: Int
    /// The key being measured.
    var key: Int
    var step: Step
    /// Pitch readings so far, of `pitchNeeded`.
    var pitch: Int
    var pitchNeeded: Int
    var b: BReadings

    /// The survey as it is now; nil when none runs. On the analysis queue.
    init?(_ engine: Engine) {
        guard let sk = engine.survey else { return nil }
        let plan = engine.planKeys()
        scope = engine.surveyPlan
        done = plan.filter { engine.run?.handled($0) ?? false }.count
        total = plan.count
        key = engine.key
        if sk.wrong > 0 {
            step = .wrong(heard: sk.wrong)
        } else if sk.wrong < 0 {
            step = .offPitch
        } else {
            step = sk.waitAttack ? .strike : sk.lost ? .lost : .listening
        }
        pitchNeeded = Survey.pitchReadings
        pitch = min(sk.pitch.count, pitchNeeded)
        if !engine.needsB(engine.key) {
            b = .known
        } else if sk.bGivenUp(engine.surveyPlan) {
            b = .skipped
        } else {
            b = .reading(count: min(sk.bs.count, Survey.bReadings), needed: Survey.bReadings)
        }
    }

    var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }
}

/// What the tuning order panel shows (JS: renderOrderPanel and
/// renderOrderState). Made on the analysis queue while the order is active,
/// rebuilt when an event or a command may have changed it.
struct OrderState: Sendable {
    /// A step in the step picker.
    struct StepItem: Sendable, Equatable, Hashable {
        var index: Int
        var step: TuningOrder.StepID
        /// The keys the title names (from, to), if any (Engine.stepRange).
        var from: Int?
        var to: Int?
    }

    var steps: [StepItem]
    /// The position: the step, and the task in it.
    var stepIndex: Int
    var taskIndex: Int
    /// Tasks in the step; 0 for a step that is only an instruction.
    var taskCount: Int
    /// The share of the order before the position, 0–1.
    var progress: Double
    var task: TuningOrder.Task?
    /// Strings per key of the task's key.
    var strings: Int
    /// The task key's deviation from its goal, for a recheck.
    var recheckCents: Double
    /// The intervals to check the task by, with their beat rates.
    var checks: [TuningOrder.CheckRow]
    /// A clean unison off target: how to move it, and the reading in cents.
    var advice: TuningOrder.UnisonAdvice?
    var adviceCents: Double
    /// A strike on the task's key ended in tune: one more firm strike.
    var confirmed: Bool
    var hasPrevious: Bool
    /// Double string unisons outside the felt strip.
    var dsu: Bool
    /// Where the piano is, for the first two steps.
    var pitch: Engine.PitchAdvice?
    /// The middle of the piano has before values, so the reference can be
    /// fitted to it.
    var canFitReference: Bool
    /// The overpull to suggest for the pitch raise (0: none), and the one set.
    var suggestedOverpull: Double
    var overpull: Double
    /// The index of the felt strip step, where the fine tuning starts.
    var stripIndex: Int

    var current: StepItem { steps[stepIndex] }

    /// The order as it is now; nil when it is off or a survey runs. On the
    /// analysis queue.
    init?(_ engine: Engine) {
        guard engine.orderActive else { return nil }
        let order = engine.order
        let pos = engine.orderPos
        let top = engine.top
        steps = order.steps.enumerated().map { i, s in
            let r = Engine.stepRange(s.id, top: top)
            return StepItem(index: i, step: s.id, from: r?.from, to: r?.to)
        }
        stepIndex = pos.step
        taskIndex = pos.index
        taskCount = order.steps[pos.step].tasks.count
        progress = order.progress(pos)
        let t = engine.orderTask
        task = t
        strings = t.map { engine.strings($0.key) } ?? 3
        recheckCents = t.map { engine.statusDev($0.key) } ?? .nan
        checks = t.map { TuningOrder.checkRows(engine.targets, $0, top: top, tuned: order.tunedBefore(pos)) } ?? []
        advice = t != nil ? engine.orderAdvice : nil
        adviceCents = engine.display
        let c = engine.orderConfirm
        confirmed = t != nil && c.current > c.since && c.ok == true
        hasPrevious = order.previous(before: pos) != nil
        dsu = engine.settings.unisons == "dsu"
        pitch = engine.pitchAdvice
        canFitReference = engine.midShift.isFinite
        suggestedOverpull = engine.suggestedOverpull
        overpull = engine.settings.overpull
        stripIndex = engine.orderStepIndex(.strip)
    }
}
