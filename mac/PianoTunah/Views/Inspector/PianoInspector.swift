import PianoTunahCore
import SwiftUI

/// The open piano's settings beside the tuner: the web's Piano, Tuning and
/// Pass tabs as sections of one form.
///
/// It shows the library's copy of the piano, which the engine's changes keep
/// up to date. The name and the notes are changed in the library; every
/// other change goes to the engine (TunerModel+Settings.swift) and comes
/// back from there, so the engine's next save never undoes it.
struct PianoInspector: View {
    @Environment(PianoLibrary.self) private var library
    @Environment(TunerModel.self) private var tuner

    var body: some View {
        if let piano = library.selected {
            // Until the engine has opened the piano, its first snapshot.
            let snapshot = tuner.snapshot.flatMap { $0.pianoID == piano.id ? $0 : nil }
            Form {
                PianoSection(piano: piano)
                SavedPianosSection()
                ReferenceSection(piano: piano, snapshot: snapshot)
                TuningSection(piano: piano)
                TemperamentSection(piano: piano)
                PassSection(piano: piano, snapshot: snapshot)
            }
            .formStyle(.grouped)
            // A fresh form for another piano: no field keeps its text.
            .id(piano.id)
        }
    }
}

/// A short explanation under a control, as the web's `.desc`.
struct InspectorNote: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A slider for a setting the engine owns. While it is dragged it shows
/// where the thumb is, not the value on its way through the engine, so the
/// thumb does not jump back between the change and its return.
struct SettingSlider<Label: View>: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let set: (Double) -> Void
    @ViewBuilder let label: (Double) -> Label

    @State private var shown: Double?
    @State private var editing = false

    var body: some View {
        let v = shown ?? value
        Slider(
            value: Binding(get: { v }, set: { new in
                shown = new
                if new != v { set(new) }
            }),
            in: range, step: step
        ) {
            label(v)
        } onEditingChanged: { e in
            editing = e
            if !e, shown == value { shown = nil }
        }
        .onChange(of: value) {
            if !editing { shown = nil }
        }
    }
}

/// A stored timestamp (ISO 8601, as JS's toISOString) as a medium date in
/// the app's language, as the web's fmtDate.
func inspectorDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d.formatted(date: .abbreviated, time: .omitted) }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)?.formatted(date: .abbreviated, time: .omitted) ?? "–"
}
