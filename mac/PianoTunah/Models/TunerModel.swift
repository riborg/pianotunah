import AppKit
import Foundation
import Observation
import os
import PianoTunahAudio
import PianoTunahCore

/// What the tuner shows of the open piano, copied from its engine after
/// every frame and every command. Immutable and Sendable: it is made on the
/// analysis queue and read on the main actor.
struct TunerSnapshot: Sendable {
    /// The piano the engine has open.
    var pianoID: String
    /// From the engine; false for the stand-in shown until its first
    /// snapshot arrives, whose targets are only defaults.
    var fromEngine = false
    var key = a4
    /// The highest key: A7 on older pianos, otherwise C8.
    var top = keyCount
    var mode = Engine.Mode.auto
    /// A note of the key is heard.
    var signal = false
    /// The reading in cents from the key's goal (overpull included); NaN
    /// without one (JS: engine.display).
    var cents = Double.nan
    var status = PitchStatus.noReading
    var tolerance = 1.0
    var refA4 = 440.0
    /// The key's target in cents from equal temperament.
    var targetCents = 0.0
    /// The key's target fundamental, Hz.
    var targetHz = 440.0
    /// The measured partial and its target, Hz.
    var partial = 1
    var partialTargetHz = 440.0
    /// The overpull goal in cents; 0 without overpull.
    var goal = 0.0
    /// The measured partial's frequency, Hz; NaN without a reading.
    var measuredHz = Double.nan
    /// The strobe rings, innermost first: the measured partial and the two
    /// octaves above it, each with its deviation (NaN while not heard).
    var strobe: [Engine.StrobeBand] = []
    /// The level of the latest frame, dB.
    var level = -100.0
    /// The note beats: the unison is out of tune.
    var beating = false
    /// A reference tone was audible in the latest frame, so nothing was saved.
    var reference = false
    /// Frames analysed with too few samples (Engine.Stats.undersized).
    var undersized = 0
    /// The pluck for the key: partial 1 including overpull, and its B.
    var toneF1 = 440.0
    var toneB = 0.0
    /// The sine for the key: the goal at the measured partial, Hz (JS:
    /// engine.sineFreq).
    var sineHz = 440.0
    /// Every key, for the keyboard, the curve and the table; shared between
    /// snapshots until the engine changes a key.
    var keys = TunerKeys()
    /// The latest key that is done, to flash.
    var flash: KeyFlash?
    /// The Beats and Partials folds (TunerModel+Folds.swift).
    var folds = FoldsSnapshot()
    /// The scope the next survey runs with, or the running one's.
    var surveyScope = Survey.Scope.allA
    /// The running survey; nil when none runs.
    var survey: SurveyState?
    /// The tuning order is on (it shows only outside a survey).
    var orderOn = false
    /// The tuning order while it is active; shared between snapshots until
    /// an event or a command may have changed it.
    var order: OrderState?

    init(pianoID: String) {
        self.pianoID = pianoID
    }

    /// The engine as it is now. On the analysis queue.
    init(_ engine: Engine, reference: Bool, keys: TunerKeys, flash: KeyFlash?, order: OrderState?) {
        let k = engine.key
        let t = engine.targets
        pianoID = engine.piano.id
        fromEngine = true
        key = k
        top = engine.top
        mode = engine.mode
        signal = engine.signal
        cents = engine.display
        status = engine.statusClass(engine.display)
        tolerance = engine.tolerance
        refA4 = engine.settings.refA4
        targetCents = t.cents[k]
        targetHz = t.frequency[k]
        partial = engine.partialOf(k)
        partialTargetHz = partialFreq(t.frequency[k], t.inharmonicity[k], partial)
        goal = engine.goal(k)
        measuredHz = engine.measuredHz
        strobe = engine.strobe
        level = engine.level
        beating = engine.beating
        self.reference = reference
        undersized = engine.stats.undersized
        toneF1 = engine.goalF1(k)
        toneB = t.inharmonicity[k]
        sineHz = engine.sineFreq(k)
        self.keys = keys
        self.flash = flash
        surveyScope = engine.surveyPlan
        survey = SurveyState(engine)
        orderOn = engine.orderOn
        self.order = order
    }
}

/// The parts of a piano the engine changes (see `Engine.piano`): copied
/// into the library, which saves them. The rest, such as the name, belongs
/// to the library and is left as it is there.
struct EngineChanges: Sendable {
    var pianoID: String
    var keys: [Int: Piano.Measurement]
    var inharmonicity: [Int: Double]
    var partials: [Int: Int]
    var settings: PianoTunahCore.Settings
    var order: TuningOrder.Position
    var history: [Piano.PassSummary]
    var passStartedAt: String

    init(_ p: Piano) {
        pianoID = p.id
        keys = p.keys
        inharmonicity = p.inharmonicity
        partials = p.partials
        settings = p.settings
        order = p.order
        history = p.history
        passStartedAt = p.passStartedAt
    }

    func apply(to p: inout Piano) {
        p.keys = keys
        p.inharmonicity = inharmonicity
        p.partials = partials
        p.settings = settings
        p.order = order
        p.history = history
        p.passStartedAt = passStartedAt
    }
}

/// Something to tell the user: from the engine, or about a command the
/// model sent it.
enum TunerMessage: Sendable {
    case engine(Engine.Message)
    /// The reference could not be fitted: nothing measured in the middle and
    /// no note sounding.
    case fitNeedsInput
    /// The reference was set to `refA4` from the piano's current pitch.
    case fitDone(refA4: Double)
    /// A new pass started.
    case newPass
}

/// The engine and what goes with it, confined to the analysis queue.
///
/// `Engine` is not Sendable: it owns large buffers every frame overwrites.
/// So every method here, and with them every use of the engine, runs on
/// `AudioSession.analysisQueue`: the frames come there, and `TunerModel`
/// sends its commands there with `queue.async`. What the main actor needs
/// leaves as an `Update` of Sendable values. That confinement is what the
/// `@unchecked Sendable` stands for.
final class TunerCore: @unchecked Sendable {
    /// What the main actor gets after each frame and command.
    struct Update: Sendable {
        /// Nil when no piano is open.
        var snapshot: TunerSnapshot?
        /// The piano changed and should be saved.
        var changes: EngineChanges?
        var messages: [TunerMessage]
    }

    private let deliver: @Sendable (Update) -> Void
    private let tones: TonePlayer
    private var engine: Engine?
    /// The start of the input the engine has its analyzer for.
    private var generation: Int?
    private var dirty = false
    private var messages: [TunerMessage] = []
    private var reference = false
    /// The keys as last built, and whether an event has changed them since.
    private var keys = TunerKeys()
    private var keysChanged = true
    /// The tuning order's state as last built, and whether something may
    /// have changed it since. The survey's state is small and changes with
    /// every frame of a survey (readings, the attack), so it is built anew
    /// each time instead.
    private var order: OrderState?
    private var orderChanged = true
    private var flash: KeyFlash?
    private var flashSerial = 0
    /// The folds under the dial (TunerModel+Folds.swift).
    let folds = FoldsCore()

    private static let log = Logger(subsystem: "io.github.riborg.pianotunah", category: "engine")

    init(tones: TonePlayer, deliver: @escaping @Sendable (Update) -> Void) {
        self.tones = tones
        self.deliver = deliver
    }

    /// Opens `piano` in a new engine, or none; the previous engine's
    /// unsaved changes go out first.
    func open(_ piano: Piano?) {
        if dirty, let engine { deliver(Update(snapshot: nil, changes: EngineChanges(engine.piano), messages: [])) }
        engine = nil
        dirty = false
        messages = []
        generation = nil
        reference = false
        keysChanged = true
        orderChanged = true
        flash = nil
        if let piano {
            let engine = Engine(piano: piano)
            engine.onEvent = { [unowned self] in self.handle($0) }
            self.engine = engine
        }
        publish()
    }

    /// A change of piano `id` from the app, run only while it is the open
    /// one; the piano is then saved (the web's markDirty). Returns what the
    /// command returned, nil if another piano is open.
    func edit<T>(_ id: String, _ command: (Engine) -> T) -> T? {
        guard let engine, engine.piano.id == id else { return nil }
        let result = command(engine)
        dirty = true
        keysChanged = true
        // setStrings builds the order again without an event (app.js calls
        // renderOrderPanel itself): the panel kept the old tasks.
        orderChanged = true
        publish()
        return result
    }

    /// One analysis frame from the microphone.
    func frame(_ f: AnalysisFrame) {
        guard let engine else { return }
        if generation != f.generation {
            // A new start of the input: its sample rate may have changed.
            engine.startAudio(sampleRate: f.sampleRate)
            generation = f.generation
            Self.log.info("audio started at \(f.sampleRate, privacy: .public) Hz")
        }
        reference = tones.gatesReadings()
        engine.frame(
            f.samples, time: f.time,
            now: ProcessInfo.processInfo.systemUptime * 1000,
            wall: Date().timeIntervalSince1970 * 1000,
            ref: reference
        )
        publish()
    }

    /// The microphone stopped.
    func stopAudio() {
        engine?.stopAudio()
        generation = nil
        reference = false
        publish()
    }

    /// A command from the app, and what to tell the user about it, if
    /// anything. `dirty`: the command changed the piano without an event
    /// that says so, such as a setting.
    func perform(dirty: Bool = false, _ command: (Engine) -> TunerMessage?) {
        guard let engine else { return }
        if let m = command(engine) { messages.append(m) }
        if dirty { self.dirty = true }
        // A command may change a key without an event, such as the partial.
        keysChanged = true
        orderChanged = true
        publish()
    }

    /// A command that changes the piano without an event of its own, such
    /// as the partial: the piano is saved too.
    func performSaving(_ command: (Engine) -> Void) {
        guard engine != nil else { return }
        perform(dirty: true) { engine in
            command(engine)
            return nil
        }
    }

    private func handle(_ event: Engine.Event) {
        switch event {
        case .dirty, .saved:
            dirty = true
            keysChanged = true
            orderChanged = true
        case .flash(let k):
            flashSerial += 1
            flash = KeyFlash(key: k, serial: flashSerial)
            keysChanged = true
        case .key, .mode, .targets, .order, .measureB:
            // Not .orderState: it judges a strike, and the order moves on
            // (the outline) only by goOrder, which sends .order.
            keysChanged = true
            orderChanged = true
        case .survey:
            keysChanged = true
        case .orderState:
            orderChanged = true
        case .message(let m):
            messages.append(.engine(m))
        case .log(let line):
            Self.log.debug("\(line, privacy: .public)")
        }
    }

    private func publish() {
        if keysChanged, let engine {
            keys = TunerKeys(engine, revision: keys.revision + 1)
            keysChanged = false
        }
        if orderChanged, let engine {
            order = OrderState(engine)
            orderChanged = false
        }
        var update = Update(
            snapshot: engine.map { TunerSnapshot($0, reference: reference, keys: keys, flash: flash, order: order) },
            changes: nil, messages: messages)
        if let engine { update.snapshot?.folds = folds.snapshot(engine) }
        if dirty, let engine { update.changes = EngineChanges(engine.piano) }
        dirty = false
        messages = []
        deliver(update)
    }
}

/// Hands updates from the analysis queue to the model, which does not exist
/// yet when the core and the audio session are made.
@MainActor
private final class Mailbox {
    weak var model: TunerModel?
}

/// The tuner of the open piano: listening, the engine on the analysis
/// queue, the reference tone, and the snapshot the views show.
///
/// Threads: the model is on the main actor. The engine lives in a
/// `TunerCore` used only on the analysis queue (see there); the model never
/// touches it, but sends commands with `queue.async` and gets a
/// `TunerSnapshot` back after every frame (≈ 11 a second) and command.
@MainActor @Observable
final class TunerModel {
    /// A message about the latest readings or a command.
    struct Notice: Equatable {
        enum Kind: Equatable {
            case ok
            case warn
        }

        var text: String
        var kind = Kind.warn
        /// Stays until closed, as the survey's result.
        var sticky = false
    }

    /// What the tuner shows; nil while no piano is open.
    private(set) var snapshot: TunerSnapshot?
    private(set) var notice: Notice?
    /// The microphone. Observable itself: its state and input.
    let session: AudioSession
    let tones: TonePlayer
    /// The sine tone sounds (`tones.isSineOn`, observed for the ▶ button;
    /// TunerModel+Tone.swift keeps it up to date).
    var sineOn = false

    private let library: PianoLibrary
    private let core: TunerCore
    private let queue: DispatchQueue
    @ObservationIgnored private var openID: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The sticky notice that a passing one covers; it shows again when
    /// that one is gone, so a survey's result is not lost to a warning.
    @ObservationIgnored private var coveredNotice: Notice?
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// What the web version keeps in localStorage: the survey's scope and
    /// whether the tuning order is on. Each piano opens with them.
    private static let scopeKey = "surveyScope"
    private static let orderKey = "tuningOrderOn"

    init(library: PianoLibrary) {
        self.library = library
        let mailbox = Mailbox()
        let tones = TonePlayer()
        let core = TunerCore(tones: tones) { update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { mailbox.model?.receive(update) }
            }
        }
        self.tones = tones
        self.core = core
        session = AudioSession(onFrame: { core.frame($0) })
        queue = session.analysisQueue
        mailbox.model = self
    }

    // MARK: - The piano

    /// Opens the piano in a new engine, closing the previous one, unless it
    /// is open already.
    ///
    /// The engine works on its own copy of the piano, and its changes are
    /// written back over the library's (`EngineChanges`: everything but the
    /// name). Anything else that edits the engine's fields of the open piano
    /// in the library, such as a settings form or a re-import of the same id,
    /// must also reach the engine (re-open it or send the change through it),
    /// or the engine's next change overwrites it.
    func open(_ piano: Piano?) {
        guard piano?.id != openID else { return }
        openID = piano?.id
        stopSine()
        snapshot = piano.map { TunerSnapshot(pianoID: $0.id) }
        clearNotice()
        let core = core
        let scope = savedScope
        let orderOn = defaults.bool(forKey: Self.orderKey)
        queue.async {
            core.open(piano)
            // As the web version starts: the saved scope, and the order if it
            // was on.
            core.perform { engine in
                engine.setSurveyPlan(scope)
                if orderOn { engine.setOrderOn(true) }
                return nil
            }
        }
    }

    /// Sends a change of piano `id` to its engine, as `open(_:)` asks (see
    /// TunerModel+Settings.swift). `done` gets the command's result, nil if
    /// the piano was no longer open, on the analysis queue.
    func edit<T>(_ id: String, _ command: @escaping @Sendable (Engine) -> T,
                 done: @escaping @Sendable (T?) -> Void = { _ in }) {
        let core = core
        queue.async { done(core.edit(id, command)) }
    }

    fileprivate func receive(_ update: TunerCore.Update) {
        if let changes = update.changes {
            library.change(changes.pianoID) { changes.apply(to: &$0) }
        }
        // Frames of a piano closed meanwhile are dropped.
        guard let s = update.snapshot, s.pianoID == openID else { return }
        snapshot = s
        followSine(s)
        for m in update.messages { show(m, decimal: DecimalSeparator(Locale.current)) }
    }

    // MARK: - Listening

    var isListening: Bool {
        session.state == .running || session.state == .starting
    }

    /// Starts the microphone, asking for the permission the first time.
    func startListening() {
        Task { await session.start() }
    }

    func stopListening() {
        session.stop()
        let core = core
        queue.async { core.stopAudio() }
    }

    func toggleListening() {
        if isListening { stopListening() } else { startListening() }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(MicPermission.settingsURL)
    }

    // MARK: - Commands

    /// The key `delta` steps up or down; leaves Auto.
    func step(_ delta: Int) {
        perform { $0.selectKey($0.key + delta) }
    }

    func setMode(_ mode: Engine.Mode) {
        perform { $0.setMode(mode) }
    }

    /// Selects key k (clamped to the keyboard); leaves Auto.
    func selectKey(_ k: Int) {
        perform { $0.selectKey(k) }
    }

    // MARK: - Survey

    /// The Survey button: starts a survey with the chosen scope (and the
    /// microphone), or ends the running one in Lock.
    func toggleSurvey() {
        if snapshot?.mode == .survey {
            setMode(.lock)
        } else {
            startSurvey()
        }
    }

    /// Starts an All A survey, and the microphone if it is off.
    func surveyAllA() {
        setSurveyScope(.allA)
        startSurvey()
    }

    private func startSurvey() {
        perform { engine in
            if engine.mode != .survey { engine.setMode(.survey) }
        }
        if !isListening { startListening() }
    }

    /// The scope of the next survey; a running one starts over with it.
    func setSurveyScope(_ scope: Survey.Scope) {
        defaults.set(scope.rawValue, forKey: Self.scopeKey)
        perform { $0.setSurveyPlan(scope) }
    }

    private var savedScope: Survey.Scope {
        defaults.string(forKey: Self.scopeKey).flatMap(Survey.Scope.init(rawValue:)) ?? .allA
    }

    /// Skips the survey's current key.
    func skipSurveyKey() {
        perform { $0.skipSurveyKey() }
    }

    /// Measures the survey's current key again from the start.
    func redoSurveyKey() {
        perform { $0.redoSurveyKey() }
    }

    /// Ends the survey where it is, in Lock.
    func finishSurvey() {
        setMode(.lock)
    }

    // MARK: - Tuning order

    func setOrderOn(_ on: Bool) {
        defaults.set(on, forKey: Self.orderKey)
        perform { $0.setOrderOn(on) }
    }

    func toggleOrder() {
        setOrderOn(!(snapshot?.orderOn ?? false))
    }

    /// The first task of step `index`.
    func goOrderStep(_ index: Int) {
        perform { $0.goOrder(TuningOrder.Position(step: index, index: 0)) }
    }

    func orderNext() {
        perform { $0.orderNext() }
    }

    func orderPrevious() {
        perform { $0.orderPrev() }
    }

    /// On to the next step.
    func orderSkip() {
        perform { $0.orderSkip() }
    }

    /// Back to the order's key from another one.
    func orderBack() {
        perform { $0.orderBack() }
    }

    /// Unisons outside the felt strip: double string unisons, or one string
    /// first.
    func setUnisons(dsu: Bool) {
        perform { $0.setUnisons(dsu ? "dsu" : "one") }
    }

    /// Sets the reference so the middle of the piano is on target (JS:
    /// fitRefToPiano).
    func fitReferenceToPiano() {
        send(dirty: true) { engine in
            let hz = engine.fitRefHz
            guard hz.isFinite else { return .fitNeedsInput }
            engine.piano.settings.refA4 = Engine.clampRef(hz)
            engine.recompute()
            return .fitDone(refA4: engine.settings.refA4)
        }
    }

    /// Uses `percent` overpull (JS: setSetting('overpull', p)).
    func setOverpull(_ percent: Double) {
        send(dirty: true) { engine in
            engine.piano.settings.overpull = percent
            engine.recompute()
            return nil
        }
    }

    /// Ends the pass: its summary goes to the history and the measurements
    /// are cleared (JS: newPass).
    func newPass() {
        let wall = Date().timeIntervalSince1970 * 1000
        send(dirty: true) { engine in
            engine.newPass(wall: wall)
            return .newPass
        }
    }

    /// After the pitch raise: a new pass without overpull for the fine
    /// tuning, from the felt strip.
    func startFinePass() {
        let wall = Date().timeIntervalSince1970 * 1000
        send(dirty: true) { engine in
            engine.newPass(wall: wall)
            engine.piano.settings.overpull = 0
            engine.recompute()
            engine.goOrder(TuningOrder.Position(step: engine.orderStepIndex(.strip), index: 0))
            return .newPass
        }
    }

    private func perform(_ command: @escaping @Sendable (Engine) -> Void) {
        send { engine in
            command(engine)
            return nil
        }
    }

    /// Sends a command to the engine on the analysis queue. `dirty`: it
    /// changes the piano without an event that says so.
    private func send(dirty: Bool = false, _ command: @escaping @Sendable (Engine) -> TunerMessage?) {
        let core = core
        queue.async { core.perform(dirty: dirty, command) }
    }

    /// Runs `command` with the core on the analysis queue.
    func send(_ command: @escaping @Sendable (TunerCore) -> Void) {
        let core = core
        queue.async { command(core) }
    }

    // MARK: - Messages

    /// Closes the notice shown (its ×); a sticky one it covered shows again.
    func closeNotice() {
        noticeTask?.cancel()
        notice = coveredNotice
        coveredNotice = nil
    }

    /// Removes every notice, as when another piano opens.
    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
        coveredNotice = nil
    }

    private func show(_ message: TunerMessage, decimal: DecimalSeparator) {
        switch message {
        case .engine(.jump(let key, let cents)):
            let text = String(localized: "\(noteName(key)) sounded \(fmtC(cents, 0, decimal: decimal)) cents from its last reading. Not saved; strike it again to save it.")
            post(Notice(text: text, kind: .warn), seconds: 5)
        case .engine(.surveyDone(let result)):
            post(Notice(text: Self.surveyDoneText(result), kind: .ok, sticky: true))
        case .engine(.orderDone):
            post(Notice(text: String(localized: "Tuning order done.", table: "Panels"), kind: .ok))
        case .engine(let m) where Self.inharmonicityText(m, decimal: decimal) != nil:
            // Measure B's result (TunerModel+Folds.swift).
            guard let text = Self.inharmonicityText(m, decimal: decimal) else { return }
            post(Notice(text: text, kind: .warn), seconds: 5)
        case .engine:
            // The others answer commands the app does not have yet.
            return
        case .fitNeedsInput:
            post(Notice(text: String(localized: "Play A4 (or survey a few keys in the middle) so the app can measure the piano’s pitch.", table: "Panels"), kind: .warn))
        case .fitDone(let refA4):
            let hz = fmtHz(refA4, 1, decimal: decimal)
            post(Notice(text: String(localized: "Reference set to \(hz) from the piano’s current pitch.", table: "Panels"), kind: .ok))
        case .newPass:
            post(Notice(text: String(localized: "New pass started. Inharmonicity and settings are kept.", table: "Panels"), kind: .ok))
        }
    }

    /// Shows `text` as a notice for `seconds` (TunerModel+Folds.swift).
    func showNotice(_ text: String, seconds: Int = 5) {
        post(Notice(text: text), seconds: Double(seconds))
    }

    /// Shows `notice`, for `seconds` unless it is sticky. A passing notice
    /// covers a sticky one only while it shows (the web replaces it).
    /// Internal for the tests.
    func post(_ notice: Notice, seconds: Double = 6) {
        noticeTask?.cancel()
        if notice.sticky {
            coveredNotice = nil
        } else if let shown = self.notice, shown.sticky {
            coveredNotice = shown
        }
        self.notice = notice
        guard !notice.sticky else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.notice = self.coveredNotice
            self.coveredNotice = nil
        }
    }

    /// What a finished survey measured (JS: surveyDoneText), as whole
    /// sentences.
    private static func surveyDoneText(_ r: Engine.SurveyResult) -> String {
        var sentences = [r.quick
            ? String(localized: "Survey of all A done: inharmonicity for \(r.measuredB) of \(r.keys) keys. The keys in between are interpolated. Click A4 = … Hz above the dial to see where the piano is.", table: "Panels")
            : String(localized: "Survey done: \(r.keys) keys measured, inharmonicity for \(r.measuredB). Click A4 = … Hz above the dial to see where the piano is.", table: "Panels")]
        if !r.skipped.isEmpty {
            if r.skipped.count <= 8 {
                let keys = r.skipped.map(noteName).joined(separator: ", ")
                sentences.append(String(localized: "Skipped: \(keys).", table: "Panels"))
            } else {
                sentences.append(String(localized: "\(r.skipped.count) keys skipped.", table: "Panels"))
            }
        }
        if !r.outliers.isEmpty {
            let keys = r.outliers.map(noteName).joined(separator: ", ")
            sentences.append(String(localized: "B for \(keys) differs from the neighbouring keys and is not used; measure it again with Measure inharmonicity (B) under Partials vs target.", table: "Panels"))
        }
        return sentences.joined(separator: " ")
    }
}
