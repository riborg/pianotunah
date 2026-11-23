import Foundation
import PianoTunahCore

/// The inspector's changes to the open piano's settings and pass.
///
/// The engine owns the open piano's settings, keys, order and history, and
/// its changes are written back over the library's (see `open(_:)`). So
/// every change here is an engine command on the analysis queue, the steps
/// app.js takes after the same control (setSetting, setRef, fitRefToPiano,
/// setStrings, setUnisons, newPass), and it reaches the library with the
/// engine's next `EngineChanges`. The name and the notes are the library's
/// own (`PianoLibrary.rename`, `setNotes`).
///
/// Each takes the piano's id: a command for a piano that is no longer open
/// is dropped.
extension TunerModel {
    /// Changes settings and computes the targets again (app.js: setSetting);
    /// a new key count also builds the order again.
    func setSettings(_ id: String, _ change: @escaping @Sendable (inout PianoTunahCore.Settings) -> Void) {
        edit(id) { $0.setSettings(change) }
    }

    /// The reference, clamped to 380–480 Hz and 0.1 Hz; NaN is ignored
    /// (app.js: setRef).
    func setRef(_ id: String, _ hz: Double) {
        guard hz.isFinite else { return }
        setSettings(id) { $0.refA4 = Engine.clampRef(hz) }
    }

    /// The reference moved by `delta` Hz from where the engine has it, so
    /// quick steps add up.
    func stepRef(_ id: String, by delta: Double) {
        setSettings(id) { $0.refA4 = Engine.clampRef($0.refA4 + delta) }
    }

    /// Another kind of piano starts at its default size: an upright's
    /// height is no sensible grand length.
    func setPianoKind(_ id: String, _ kind: String) {
        let cm = pianoKind(kind)?.defaultCm ?? Settings.defaults.sizeCm
        setSettings(id) {
            $0.sizeCm = cm
            $0.pianoKind = kind
        }
    }

    /// The size in cm, clamped to the kind's range.
    func setSize(_ id: String, _ cm: Double) {
        setSettings(id) { $0.sizeCm = Engine.clampSize($0.pianoKind, cm) }
    }

    /// Strings per key, clamped by the engine; the order is built again.
    func setStrings(_ id: String, two: Int, one: Int) {
        edit(id) { _ = $0.setStrings(two: Double(two), one: Double(one)) }
    }

    /// "one" or "dsu"; the order stays on its key.
    func setUnisons(_ id: String, _ unisons: String) {
        edit(id) { $0.setUnisons(unisons) }
    }

    /// Sets the reference to the piano's current pitch (app.js:
    /// fitRefToPiano). Returns the reference set, or nil when nothing has
    /// been measured to fit it to, or the piano is no longer open.
    func fitRef(_ id: String) async -> Double? {
        await withCheckedContinuation { c in
            edit(id, { $0.fitRef() }, done: { c.resume(returning: $0 ?? nil) })
        }
    }

    /// Saves the pass to the history and starts a new one.
    func newPass(_ id: String) {
        let wall = Date().timeIntervalSince1970 * 1000
        edit(id) { $0.newPass(wall: wall) }
    }
}

extension TunerSnapshot {
    /// Keys measured and keys within tolerance, of 1…top (Engine.passStats).
    var passStats: (measured: Int, ok: Int) {
        let measured = keys.states.filter { $0.deviation.isFinite }
        return (measured.count, measured.count(where: { $0.status == .good }))
    }

    /// Where the middle of the piano was when the pass started
    /// (Engine.midShift).
    var midShift: Double {
        Engine.midShift(Engine.middle.compactMap { keys[$0]?.before }.filter(\.isFinite))
    }

    /// What to say under the reference (Engine.refAdvice).
    var refAdvice: Engine.RefAdvice {
        Engine.refAdvice(midShift: midShift, refA4: refA4)
    }
}
