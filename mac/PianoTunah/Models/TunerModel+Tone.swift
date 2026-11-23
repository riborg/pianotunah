import Foundation
import PianoTunahAudio
import PianoTunahCore

/// Which reference tone ▶, T and space play (the web's tone menu).
enum ToneKind: String, CaseIterable, Identifiable, Sendable {
    /// A short piano-like tone of the key's target (tone.js pluck).
    case piano
    /// A pure, sustained sine at the target of the key's measured partial,
    /// until it is stopped.
    case sine

    var id: Self { self }

    /// The UserDefaults key (@AppStorage) of the choice (the web's
    /// pianotunah.toneMode).
    static let storageKey = "toneKind"
    /// The UserDefaults key (@AppStorage) of "Also play when a key is
    /// clicked" (the web's pianotunah.toneOnKey).
    static let onKeyStorageKey = "toneOnKey"
}

/// The reference tone (app.js: playPiano, startSine, stopSine, playCurrent
/// and the keyboard's click). The sine follows the key: every snapshot
/// brings the current key's ``TunerSnapshot/sineHz``, approached with
/// τ = 10 ms. Readings are gated by `TonePlayer.gatesReadings`, which the
/// core asks for every frame: while a tone sounds and for 800 ms after.
extension TunerModel {
    /// The tone chosen in the menu next to ▶.
    var toneKind: ToneKind {
        UserDefaults.standard.string(forKey: ToneKind.storageKey).flatMap(ToneKind.init(rawValue:)) ?? .piano
    }

    /// Whether clicking a key on the keyboard also plays the chosen tone.
    var playsToneOnKey: Bool {
        UserDefaults.standard.bool(forKey: ToneKind.onKeyStorageKey)
    }

    /// The ▶ button, T and space: a pluck, or the sine on or off (JS:
    /// playCurrent).
    func playTone() {
        switch toneKind {
        case .piano:
            guard let s = snapshot, s.fromEngine else { return }
            tones.pluck(f1: s.toneF1, b: s.toneB)
        case .sine:
            if tones.isSineOn {
                stopSine()
            } else if let s = snapshot, s.fromEngine {
                startSine(s.sineHz)
            }
        }
    }

    /// The menu's choice changed: a sine still sounding stops unless the
    /// choice is Sine (JS: setToneMode).
    func toneKindChanged(_ kind: ToneKind) {
        if kind != .sine { stopSine() }
    }

    func stopSine() {
        guard tones.isSineOn else { return }
        tones.stopSine()
        sineOn = tones.isSineOn
    }

    /// Selects key k from the keyboard and, if "Also play when a key is
    /// clicked" is on, plays the chosen tone for it. Clicking the key whose
    /// sine sounds stops it.
    func clickKey(_ k: Int) {
        guard playsToneOnKey else { return selectKey(k) }
        let kind = toneKind
        let model = self
        send { core in
            var clicked: ClickedTone?
            core.perform { engine in
                let previous = engine.key
                engine.selectKey(k)
                let key = engine.key
                clicked = ClickedTone(
                    f1: engine.goalF1(key), b: engine.targets.inharmonicity[key],
                    sineHz: engine.sineFreq(key), sameKey: key == previous)
                return nil
            }
            guard let clicked else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.play(clicked, kind) }
            }
        }
    }

    /// The new snapshot's sine, if the sine sounds.
    func followSine(_ s: TunerSnapshot) {
        // The player may have stopped it, as when the output fails.
        if sineOn != tones.isSineOn { sineOn = tones.isSineOn }
        guard tones.isSineOn else { return }
        tones.setSine(s.sineHz)
    }

    private func startSine(_ hz: Double) {
        if !tones.isSineOn, isListening {
            showNotice(String(localized: "Measurements are not saved while the sine tone is playing."), seconds: 4)
        }
        tones.startSine(hz)
        sineOn = tones.isSineOn
    }

    private func play(_ tone: ClickedTone, _ kind: ToneKind) {
        switch kind {
        case .piano:
            tones.pluck(f1: tone.f1, b: tone.b)
        case .sine:
            if tones.isSineOn, tone.sameKey {
                stopSine()
            } else {
                startSine(tone.sineHz)
            }
        }
    }
}

/// A clicked key's tones, from the engine on the analysis queue.
private struct ClickedTone: Sendable {
    var f1: Double
    var b: Double
    var sineHz: Double
    /// The key was already selected.
    var sameKey: Bool
}
