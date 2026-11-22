/// Whether readings must be ignored because the reference tone can be in
/// the microphone: while it sounds and for 800 ms after, the length of the
/// analysis buffer and some (app.js: `refPlaying`, `state.refUntil`).
///
/// Pure; any thread. Times are in s of one steady clock, the one
/// `TonePlayer.audibleUntil` uses (`ProcessInfo.systemUptime`).
public enum ReferenceGate {
    /// How long after the tone the gate stays shut, in s.
    public static let margin = 0.8

    /// True while a tone audible until `audibleUntil` (∞ while the sine is
    /// on) may still be in the analysis buffer at `now`.
    public static func isShut(audibleUntil: Double, now: Double) -> Bool {
        now < audibleUntil + margin
    }
}
