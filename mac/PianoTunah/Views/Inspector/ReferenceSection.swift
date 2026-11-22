import PianoTunahCore
import SwiftUI

/// The reference A4 (the top of the web's Tuning tab): ±1 and ±0.1 Hz, the
/// field, the presets, the piano's current pitch, and the advice on the
/// reference and overpull from where the middle of the piano was.
struct ReferenceSection: View {
    let piano: Piano
    let snapshot: TunerSnapshot?
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale
    /// What the latest "Use the piano's current pitch" did.
    @State private var fitMessage: Text?

    private static let presets: [Double] = [415, 430, 432, 435, 440, 442, 444]

    var body: some View {
        let decimal = DecimalSeparator(locale)
        let id = piano.id
        let ref = piano.settings.refA4
        let c = centsBetween(ref, 440)
        Section {
            LabeledContent {
                RefField(id: id, ref: ref)
            } label: {
                Text("Reference A4", tableName: "Inspector")
                if abs(c) < 0.05 {
                    Text("Standard pitch", tableName: "Inspector")
                } else {
                    Text("\(fmtC(c, decimal: decimal)) cents from 440 Hz", tableName: "Inspector")
                }
            }

            HStack {
                ForEach([-1, -0.1, 0.1, 1], id: \.self) { d in
                    Button {
                        tuner.stepRef(id, by: d)
                    } label: {
                        Text(verbatim: (d < 0 ? "−" : "+") + short(abs(d), decimal: decimal))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Picker(selection: Binding(get: { ref }, set: { tuner.setRef(id, $0) })) {
                ForEach(Self.presets, id: \.self) { hz in
                    Text(verbatim: short(hz, decimal: decimal)).tag(hz)
                }
            } label: {
                Text("Presets", tableName: "Inspector")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task {
                        if let hz = await tuner.fitRef(id) {
                            fitMessage = Text("Reference set to \(fmtHz(hz, 1, decimal: decimal)) from the piano’s current pitch.", tableName: "Inspector")
                        } else {
                            fitMessage = Text("Play A4 (or survey a few keys in the middle) so the app can measure the piano’s pitch.", tableName: "Inspector")
                        }
                    }
                } label: {
                    Text("Use the piano’s current pitch", tableName: "Inspector").frame(maxWidth: .infinity)
                }
                if let fitMessage { InspectorNote(fitMessage) }
            }

            if let snapshot {
                RefAdviceView(id: id, advice: snapshot.refAdvice, overpull: piano.settings.overpull)
            }
        } header: {
            Text("Reference A4", tableName: "Inspector")
        }
    }
}

/// The reference in Hz, with the language's decimal separator. Return or
/// leaving the field sets it (clamped); input that is no number goes back
/// to the reference. ↑ and ↓ step 0.1 Hz, with Shift 1 Hz.
private struct RefField: View {
    let id: String
    let ref: Double
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(text: $text) {
                Text("Reference frequency in Hz", tableName: "Inspector")
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 64)
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                step(press.modifiers.contains(.shift) ? 1 : 0.1)
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                step(press.modifiers.contains(.shift) ? -1 : -0.1)
            }
            Text(verbatim: "Hz")
        }
        .onAppear { show() }
        .onChange(of: ref) { show() }
        .onChange(of: focused) {
            if !focused { commit() }
        }
    }

    private func show() {
        text = num(ref, 1, decimal: DecimalSeparator(locale))
    }

    private func commit() {
        let hz = parseNum(text)
        if hz.isFinite { tuner.setRef(id, hz) }
        show()
    }

    private func step(_ d: Double) -> KeyPress.Result {
        let typed = parseNum(text)
        tuner.setRef(id, (typed.isFinite ? typed : ref) + d)
        return .handled
    }
}

/// Where the middle of the piano was when the pass started, and what to
/// do about it (app.js: renderRef with engine.refAdvice).
private struct RefAdviceView: View {
    let id: String
    let advice: Engine.RefAdvice
    let overpull: Double
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        VStack(alignment: .leading, spacing: 6) {
            switch advice {
            case .none:
                InspectorNote(Text("Survey or measure a few keys in the middle and the app can suggest a reference that suits the piano.", tableName: "Inspector"))
            case .near(let m):
                InspectorNote(Text("The piano was close to the target (\(fmtC(m, decimal: decimal)) cents in the middle) when the pass started.", tableName: "Inspector"))
            case .off(let a):
                InspectorNote(Text("The piano was \(fmtC(a.m, decimal: decimal)) cents from the target in the middle (≈ A4 = \(fmtHz(a.hz, 1, decimal: decimal))).", tableName: "Inspector"))
                if a.p != 0, let o = a.o, let ohz = a.ohz {
                    let p = percent(a.p)
                    InspectorNote(Text("To reach the target: \(p) overpull. A key that starts at \(fmtC(a.m, 0, decimal: decimal)) cents is tuned to \(fmtC(o, 0, decimal: decimal)) (A4 ≈ \(fmtHz(ohz, 1, decimal: decimal))) and settles towards the target as the tension evens out. Check again with a new pass after 2–4 weeks. To avoid raising the pitch, use the piano’s current pitch instead.", tableName: "Inspector"))
                    if a.big == true {
                        InspectorNote(Text("More than 25 cents flat on an old piano, 50 on a newer one: raise in two passes, a quick one with overpull and then a fine one. Old strings can break; raise gradually.", tableName: "Inspector"))
                    }
                    if overpull != a.p {
                        Button {
                            tuner.setSettings(id) { $0.overpull = a.p }
                        } label: {
                            Text("Use \(p) overpull", tableName: "Inspector").frame(maxWidth: .infinity)
                        }
                    }
                } else if a.m > 0 {
                    InspectorNote(Text("Tune down to the target, or use the piano’s current pitch.", tableName: "Inspector"))
                } else {
                    InspectorNote(Text("Small deviations are tuned directly without overpull.", tableName: "Inspector"))
                }
            }
        }
    }

    private func percent(_ p: Double) -> String {
        (p / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
