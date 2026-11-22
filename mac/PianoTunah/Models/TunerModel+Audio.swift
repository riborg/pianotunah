import Foundation
import PianoTunahAudio

/// The input chosen in Settings (the web's `state.micId`).
extension TunerModel {
    /// The UserDefaults key (@AppStorage) of the chosen input's Core Audio
    /// UID; absent for the system default.
    static let inputStorageKey = "inputDeviceUID"

    /// Uses the input stored in Settings, from the next start: at launch.
    func restoreInput(from defaults: UserDefaults = .standard) {
        session.deviceUID = defaults.string(forKey: Self.inputStorageKey)
    }

    /// Switches to the input with `uid`, or the system default for nil: at
    /// once if listening, else from the next start. A missing device falls
    /// back to the default (`MicInput.Info.usedFallback`).
    func useInput(_ uid: String?) {
        guard session.deviceUID != uid else { return }
        session.deviceUID = uid
        session.restart()
    }
}
