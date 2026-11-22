import PianoTunahAudio
import PianoTunahCore
import SwiftUI

/// The tuner card of the open piano: the reference, the tone, the mode and
/// the microphone above the dial; the status and the key's target and
/// measurement below it, then the keyboard with the curve.
///
/// Shortcuts as in the web version: ← → the previous and next key, A Auto,
/// L Lock, and space (or T) the reference tone.
struct TunerView: View {
    @Environment(TunerModel.self) private var tuner
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        let palette = Palette.of(scheme)
        ScrollView {
            if let snapshot = tuner.snapshot {
                VStack(spacing: 14) {
                    TunerHeader(snapshot: snapshot, palette: palette)
                    DialView(snapshot: snapshot, listening: tuner.isListening) { tuner.step($0) }
                        .frame(maxWidth: 560)
                    TunerReadout(snapshot: snapshot, listening: tuner.isListening, palette: palette)
                    TunerWarnings(snapshot: snapshot, palette: palette)
                    KeyboardBlock(snapshot: snapshot)
                        .padding(.top, 10)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(palette.surface.color)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onKeyPress(.leftArrow) {
            tuner.step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            tuner.step(1)
            return .handled
        }
        .onKeyPress(.space, phases: .down) { _ in
            tuner.playTone()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "aAlLtT"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.characters.lowercased() {
            case "a": tuner.setMode(.auto)
            case "l": tuner.setMode(.lock)
            case "t": tuner.playTone()
            default: return .ignored
            }
            return .handled
        }
    }
}

/// The row above the dial.
private struct TunerHeader: View {
    let snapshot: TunerSnapshot
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "A4 = " + fmtHz(snapshot.refA4, 1, decimal: decimal))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.muted.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(palette.sunk.color))
                .padding(.top, 2)
            Button {
                tuner.playTone()
            } label: {
                Text(noteText("▶ " + noteName(snapshot.key), size: 13))
                    .monospacedDigit()
            }
            .help("Play target tone (Space)")
            Spacer(minLength: 8)
            Picker("Mode", selection: Binding(
                get: { snapshot.mode == .lock ? Engine.Mode.lock : .auto },
                set: { tuner.setMode($0) }
            )) {
                Text("Auto").tag(Engine.Mode.auto)
                    .help("Detect the key automatically (A)")
                Text("Lock").tag(Engine.Mode.lock)
                    .help("Lock on the selected key (L)")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            MicControl(level: snapshot.level, palette: palette)
        }
    }
}

/// Start and stop, the level, and the input in use.
private struct MicControl: View {
    let level: Double
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let listening = tuner.isListening
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if listening {
                    Button("Stop microphone") { tuner.stopListening() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start microphone") { tuner.startListening() }
                        .buttonStyle(.borderedProminent)
                }
            }
            // The level, as the web's bar under the button: −80 dB to −8.6 dB.
            let fraction = listening ? max(0, min(1, (level + 80) * 1.4 / 100)) : 0
            Capsule()
                .fill(palette.line.color)
                .frame(width: 96, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.accent.color)
                        .frame(width: 96 * fraction, height: 3)
                }
                .accessibilityHidden(true)
            if let input = tuner.session.input {
                Text(verbatim: input.deviceName.isEmpty ? kHz(input.sampleRate) : input.deviceName + " · " + kHz(input.sampleRate))
                    .font(.caption)
                    .foregroundStyle(palette.muted.color)
                    .lineLimit(1)
            }
        }
    }

    private func kHz(_ rate: Double) -> String {
        short(rate / 1000, decimal: DecimalSeparator(locale)) + " kHz"
    }
}

/// The status, the key's target and the measurement, under the dial.
private struct TunerReadout: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        let s = snapshot
        VStack(spacing: 8) {
            Text(statusText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.status(listening && s.signal ? s.status : nil).color)
            VStack(spacing: 3) {
                Text(String(localized: "Key \(s.key) · target \(fmtC(s.targetCents, decimal: decimal)) cents"))
                Text(targetLine(decimal))
                Text(measuredLine(decimal))
                    .foregroundStyle(listening && s.signal ? palette.ink.color : palette.muted.color)
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(palette.muted.color)
            .multilineTextAlignment(.center)
            if listening && s.beating {
                Text("The note beats, twice a second or faster. Mute all strings but one with a felt strip or wedge.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.warn.color)
                    .multilineTextAlignment(.center)
            }
            if let notice = tuner.notice {
                Text(verbatim: notice.text)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.warn.color)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 560)
    }

    private var statusText: String {
        let s = snapshot
        if !listening { return String(localized: "Start the microphone") }
        if !s.signal { return String(localized: "Listening …") }
        if s.reference { return String(localized: "Reference tone, not saved") }
        if s.status == .good { return String(localized: "In tune") }
        return s.cents > 0 ? String(localized: "Too high, lower") : String(localized: "Too low, raise")
    }

    private func targetLine(_ decimal: DecimalSeparator) -> String {
        let s = snapshot
        var parts = [String(localized: "Fundamental \(fmtHz(s.targetHz, decimal: decimal))")]
        if s.partial > 1 {
            parts.append(String(localized: "partial \(s.partial) \(fmtHz(s.partialTargetHz, decimal: decimal))"))
        }
        if s.goal != 0 {
            parts.append(String(localized: "overpull \(fmtC(s.goal, decimal: decimal)) cents"))
        }
        return parts.joined(separator: " · ")
    }

    private func measuredLine(_ decimal: DecimalSeparator) -> String {
        let s = snapshot
        let hz = listening && s.measuredHz.isFinite ? fmtHz(s.measuredHz, decimal: decimal) : "–"
        return s.partial > 1
            ? String(localized: "Measured partial \(s.partial): \(hz)")
            : String(localized: "Measured \(hz)")
    }
}

/// Why listening does not work, or works less well than it should.
private struct TunerWarnings: View {
    let snapshot: TunerSnapshot
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let session = tuner.session
        VStack(spacing: 8) {
            switch session.state {
            case .denied:
                warning(String(localized: "Piano Tunah may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then start the microphone again."))
                Button("Open System Settings") { tuner.openPrivacySettings() }
            case .failed(let reason):
                warning(String(localized: "Could not start the microphone: \(reason)"))
            default:
                EmptyView()
            }
            if let input = session.input {
                if input.usedFallback {
                    warning(String(localized: "The chosen microphone is not connected; using the system default."))
                }
                if input.sampleRate != 44100 && input.sampleRate != 48000 {
                    let rate = short(input.sampleRate / 1000, decimal: DecimalSeparator(locale))
                    warning(String(localized: "The input runs at \(rate) kHz. Piano Tunah measures best at 44.1 or 48 kHz."))
                }
            }
            if snapshot.undersized > 0 {
                warning(String(localized: "Some frames had too few samples, so the bass is measured less precisely."))
            }
        }
        .frame(maxWidth: 560)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(palette.warn.color)
        .fixedSize(horizontal: false, vertical: true)
    }
}
