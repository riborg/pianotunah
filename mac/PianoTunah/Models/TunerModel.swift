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
    /// Every key, for the keyboard, the curve and the table; shared between
    /// snapshots until the engine changes a key.
    var keys = TunerKeys()
    /// The latest key that is done, to flash.
    var flash: KeyFlash?

    init(pianoID: String) {
        self.pianoID = pianoID
    }

    /// The engine as it is now. On the analysis queue.
    init(_ engine: Engine, reference: Bool, keys: TunerKeys, flash: KeyFlash?) {
        let k = engine.key
        let t = engine.targets
        pianoID = engine.piano.id
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
        self.keys = keys
        self.flash = flash
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
        var messages: [Engine.Message]
    }

    private let deliver: @Sendable (Update) -> Void
    private let tones: TonePlayer
    private var engine: Engine?
    /// The start of the input the engine has its analyzer for.
    private var generation: Int?
    private var dirty = false
    private var messages: [Engine.Message] = []
    private var reference = false
    /// The keys as last built, and whether an event has changed them since.
    private var keys = TunerKeys()
    private var keysChanged = true
    private var flash: KeyFlash?
    private var flashSerial = 0

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
        flash = nil
        if let piano {
            let engine = Engine(piano: piano)
            engine.onEvent = { [unowned self] in self.handle($0) }
            self.engine = engine
        }
        publish()
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

    /// A command from the app.
    func perform(_ command: (Engine) -> Void) {
        guard let engine else { return }
        command(engine)
        // A command may change a key without an event, such as the partial.
        keysChanged = true
        publish()
    }

    private func handle(_ event: Engine.Event) {
        switch event {
        case .dirty, .saved:
            dirty = true
            keysChanged = true
        case .flash(let k):
            flashSerial += 1
            flash = KeyFlash(key: k, serial: flashSerial)
            keysChanged = true
        case .key, .mode, .targets, .survey, .order, .measureB:
            // Not .orderState: it judges a strike, and the order moves on
            // (the outline) only by goOrder, which sends .order.
            keysChanged = true
        case .message(let m):
            messages.append(m)
        case .log(let line):
            Self.log.debug("\(line, privacy: .public)")
        default:
            break
        }
    }

    private func publish() {
        if keysChanged, let engine {
            keys = TunerKeys(engine, revision: keys.revision + 1)
            keysChanged = false
        }
        var update = Update(
            snapshot: engine.map { TunerSnapshot($0, reference: reference, keys: keys, flash: flash) },
            changes: nil, messages: messages)
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
    /// A short message about the latest readings.
    struct Notice: Equatable {
        var text: String
    }

    /// What the tuner shows; nil while no piano is open.
    private(set) var snapshot: TunerSnapshot?
    private(set) var notice: Notice?
    /// The microphone. Observable itself: its state and input.
    let session: AudioSession
    let tones: TonePlayer

    private let library: PianoLibrary
    private let core: TunerCore
    private let queue: DispatchQueue
    @ObservationIgnored private var openID: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

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
        snapshot = piano.map { TunerSnapshot(pianoID: $0.id) }
        notice = nil
        let core = core
        queue.async { core.open(piano) }
    }

    fileprivate func receive(_ update: TunerCore.Update) {
        if let changes = update.changes {
            library.change(changes.pianoID) { changes.apply(to: &$0) }
        }
        // Frames of a piano closed meanwhile are dropped.
        guard let s = update.snapshot, s.pianoID == openID else { return }
        snapshot = s
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

    /// Starts an All A survey, and the microphone if it is off.
    func surveyAllA() {
        perform {
            $0.setSurveyPlan(.allA)
            $0.setMode(.survey)
        }
        if !isListening { startListening() }
    }

    /// Plucks the current key's target, overpull included.
    func playTone() {
        guard let s = snapshot, s.toneF1 > 0 else { return }
        tones.pluck(f1: s.toneF1, b: s.toneB)
    }

    private func perform(_ command: @escaping @Sendable (Engine) -> Void) {
        let core = core
        queue.async { core.perform(command) }
    }

    // MARK: - Messages

    private func show(_ message: Engine.Message, decimal: DecimalSeparator) {
        let text: String
        switch message {
        case .jump(let key, let cents):
            text = String(localized: "\(noteName(key)) sounded \(fmtC(cents, 0, decimal: decimal)) cents from its last reading. Not saved; strike it again to save it.")
        default:
            // The others answer commands the app does not have yet.
            return
        }
        notice = Notice(text: text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
