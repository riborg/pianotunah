import PianoTunahAudio
import PianoTunahCore
import SwiftUI

/// The tuner card of the open piano: the reference, the tone, the mode,
/// the survey and the tuning order, and the microphone above the dial; the
/// status and the key's target and measurement below it, the survey or
/// tuning order panel beside it (under it in a narrow window), then the
/// keyboard with the curve.
///
/// Shortcuts as in the web version: ← → the previous and next key, A Auto,
/// L Lock, O the tuning order, and space (or T) the reference tone.
struct TunerView: View {
    @Environment(TunerModel.self) private var tuner
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    /// The width of the card, for where the panels go.
    @State private var width: CGFloat = 0

    /// From this width of the card on, the panels open beside the dial
    /// rather than under it (style.css: 960 px less the page's margins).
    private static let besideWidth: CGFloat = 900

    var body: some View {
        let palette = Palette.of(scheme)
        ScrollView {
            if let snapshot = tuner.snapshot {
                VStack(spacing: 14) {
                    TunerHeader(snapshot: snapshot, palette: palette)
                    main(snapshot, palette: palette)
                    KeyboardBlock(snapshot: snapshot)
                        .padding(.top, 10)
                    FoldsView(snapshot: snapshot, listening: tuner.isListening)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        .onKeyPress(characters: CharacterSet(charactersIn: "aAlLoOtT"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.characters.lowercased() {
            case "a": tuner.setMode(.auto)
            case "l": tuner.setMode(.lock)
            case "o": tuner.toggleOrder()
            case "t": tuner.playTone()
            default: return .ignored
            }
            return .handled
        }
    }

    /// The dial with what goes under it, and the open panel: beside the
    /// dial in a wide card, under it in a narrow one. One layout that
    /// changes, so the dial keeps its identity when a panel opens.
    @ViewBuilder
    private func main(_ snapshot: TunerSnapshot, palette: Palette) -> some View {
        let hasPanel = snapshot.survey != nil || snapshot.order != nil
        let beside = hasPanel && width >= Self.besideWidth
        let layout = beside
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 14))
        layout {
            VStack(spacing: 14) {
                DialView(snapshot: snapshot, listening: tuner.isListening) { tuner.step($0) }
                    .frame(maxWidth: 560)
                TunerReadout(snapshot: snapshot, listening: tuner.isListening, palette: palette)
                TunerWarnings(snapshot: snapshot, palette: palette)
            }
            .frame(maxWidth: 560)
            .layoutPriority(1)
            Group {
                if let survey = snapshot.survey {
                    SurveyPanel(survey: survey, palette: palette)
                } else if let order = snapshot.order {
                    OrderPanel(order: order, key: snapshot.key, wide: beside, palette: palette)
                }
            }
            .frame(minWidth: beside ? 320 : nil, maxWidth: .infinity, alignment: .topLeading)
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
        // One row, or two when the window is narrow (the web's flex-wrap).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                reference
                Spacer(minLength: 8)
                modes
                MicControl(level: snapshot.level, palette: palette)
            }
            VStack(alignment: .trailing, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    reference
                    Spacer(minLength: 8)
                    MicControl(level: snapshot.level, palette: palette)
                }
                modes
            }
        }
    }

    /// The reference and the tone.
    private var reference: some View {
        let decimal = DecimalSeparator(locale)
        return HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "A4 = " + fmtHz(snapshot.refA4, 1, decimal: decimal))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.muted.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(palette.sunk.color))
                .padding(.top, 2)
            ToneButton(snapshot: snapshot)
        }
    }

    /// Auto and Lock, then the survey and the tuning order. The survey is a
    /// mode of its own; the order shows outside it (Engine.orderActive).
    private var modes: some View {
        HStack(spacing: 10) {
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
            Toggle(isOn: Binding(get: { snapshot.mode == .survey }, set: { _ in tuner.toggleSurvey() })) {
                Text(LocalizedStringResource("mode.survey", defaultValue: "Survey", table: "Panels"))
            }
            .toggleStyle(.button)
            .help(Text("Measure the piano key by key before tuning", tableName: "Panels"))
            Toggle(isOn: Binding(get: { snapshot.orderOn }, set: { tuner.setOrderOn($0) })) {
                Text("Tuning order", tableName: "Panels")
            }
            .toggleStyle(.button)
            .help(Text("Step by step through the tuning (O)", tableName: "Panels"))
        }
        .fixedSize()
    }
}

/// The reference tone, as the web's split button: ▶ plays it, the menu
/// beside it chooses Piano or Sine and whether clicking a key plays it too.
/// While the sine sounds, ▶ turns into ■ and stops it. The sine sounds at
/// the measured partial, in the bass and tenor an octave or more above the
/// key, so the button names the note it plays.
private struct ToneButton: View {
    let snapshot: TunerSnapshot
    @Environment(TunerModel.self) private var tuner
    @AppStorage(ToneKind.storageKey) private var kind = ToneKind.piano
    @AppStorage(ToneKind.onKeyStorageKey) private var onKey = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                tuner.playTone()
            } label: {
                Text(noteText((tuner.sineOn ? "■ " : "▶ ") + noteName(playedKey), size: 13))
                    .monospacedDigit()
            }
            .help(title)
            .accessibilityLabel(Text(verbatim: title))
            Menu {
                Picker(selection: Binding(get: { kind }, set: {
                    kind = $0
                    tuner.toneKindChanged($0)
                })) {
                    Text("Piano tone").tag(ToneKind.piano)
                    Text("Sine tone").tag(ToneKind.sine)
                } label: {
                    Text("Reference tone")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Toggle("Also play when a key is clicked", isOn: $onKey)
            } label: {
                kind == .sine ? Text("Sine") : Text("Piano")
            }
            .fixedSize()
            .help("Reference tone")
        }
    }

    /// The key whose note the tone is: the sine's partial n lies
    /// 12·log2(n) semitones above the key.
    private var playedKey: Int {
        let n = kind == .sine ? snapshot.partial : 1
        return min(keyCount, snapshot.key + Int((12 * log2(Double(n))).rounded()))
    }

    private var title: String {
        guard kind == .sine else { return String(localized: "Play target tone (Space)") }
        let note = noteName(playedKey)
        let what = snapshot.partial > 1 ? String(localized: "\(note) (partial \(snapshot.partial))") : note
        return tuner.sineOn
            ? String(localized: "Stop sine tone \(what) (Space)")
            : String(localized: "Play sine tone \(what) (Space)")
    }
}

/// Start and stop, and the level as a line under the button, as the web's.
/// The control keeps its size whether listening or not, so the bar beside it
/// does not move; the input in use is in the button's help and in Settings.
private struct MicControl: View {
    let level: Double
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let listening = tuner.isListening
        Group {
            if listening {
                Button { tuner.stopListening() } label: { label(listening) }
                    .buttonStyle(.bordered)
            } else {
                Button { tuner.startListening() } label: { label(listening) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityLabel(listening ? Text("Stop microphone") : Text("Start microphone"))
        .help(inputInUse)
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            // The level over the button's width: −80 dB to −8.6 dB.
            let fraction = listening ? max(0, min(1, (level + 80) * 1.4 / 100)) : 0
            Capsule()
                .fill(palette.line.color)
                .overlay {
                    // Cut rather than squeezed, so the ends stay round.
                    Capsule()
                        .fill(palette.accent.color)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: fraction, anchor: .leading)
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
        }
    }

    /// Both texts, one hidden: the button is as wide as the wider of them.
    private func label(_ listening: Bool) -> some View {
        ZStack {
            Text("Start microphone").opacity(listening ? 0 : 1)
            Text("Stop microphone").opacity(listening ? 1 : 0)
        }
    }

    private var inputInUse: Text {
        guard let input = tuner.session.input else { return Text(verbatim: "") }
        return Text(verbatim: input.deviceName.isEmpty ? kHz(input.sampleRate) : input.deviceName + " · " + kHz(input.sampleRate))
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: notice.text)
                        .font(.system(size: 13))
                        .foregroundStyle((notice.kind == .ok ? palette.good : palette.warn).color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        tuner.closeNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Close", tableName: "Panels"))
                }
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
