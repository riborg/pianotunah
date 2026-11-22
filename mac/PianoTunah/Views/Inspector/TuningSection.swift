import PianoTunahCore
import SwiftUI

/// The rest of the web's Tuning tab: stretch, octave types, extra treble
/// and bass, overpull and tolerance.
struct TuningSection: View {
    let piano: Piano
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    private static let tolerances: [Double] = [0.5, 1, 2, 3]

    var body: some View {
        let s = piano.settings
        let id = piano.id
        let decimal = DecimalSeparator(locale)
        Section {
            Picker(selection: Binding(get: { s.stretch }, set: { v in tuner.setSettings(id) { $0.stretch = v } })) {
                ForEach(stretchPresets) { p in
                    stretchName(p.id).tag(p.id)
                }
            } label: {
                Text("Stretch", tableName: "Inspector")
            }
            if let desc = stretchDescription(s.stretch) { InspectorNote(desc) }

            if s.stretch == "custom" {
                octavePicker(Text("Bass", tableName: "Inspector"), s.bassOctave) { v in tuner.setSettings(id) { $0.bassOctave = v } }
                octavePicker(Text("Middle", tableName: "Inspector"), s.midOctave) { v in tuner.setSettings(id) { $0.midOctave = v } }
                octavePicker(Text("Treble", tableName: "Inspector"), s.trebleOctave) { v in tuner.setSettings(id) { $0.trebleOctave = v } }
            }

            SettingSlider(value: s.extraTreble, range: -10...20, step: 1, set: { v in tuner.setSettings(id) { $0.extraTreble = v } }) { v in
                Text("Extra treble", tableName: "Inspector")
                Text("\(fmtC(v, 0, decimal: decimal)) cents at C8", tableName: "Inspector")
            }
            SettingSlider(value: s.extraBass, range: -10...20, step: 1, set: { v in tuner.setSettings(id) { $0.extraBass = v } }) { v in
                Text("Extra bass", tableName: "Inspector")
                Text("\(bassCents(v, decimal)) cents at A0", tableName: "Inspector")
            }
            SettingSlider(value: s.overpull, range: 0...35, step: 5, set: { v in tuner.setSettings(id) { $0.overpull = v } }) { v in
                Text("Overpull", tableName: "Inspector")
                Text(verbatim: (v / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
            }

            Picker(selection: Binding(get: { s.tolerance }, set: { v in tuner.setSettings(id) { $0.tolerance = v } })) {
                ForEach(Self.tolerances, id: \.self) { t in
                    Text("±\(short(t, decimal: decimal)) cents", tableName: "Inspector").tag(t)
                }
            } label: {
                Text("Tolerance", tableName: "Inspector")
            }
        } header: {
            Text("Tuning", tableName: "Inspector")
        }
    }

    /// As the web: the bass goes down by the amount, so it is written as
    /// a fall whatever its sign.
    private func bassCents(_ v: Double, _ decimal: DecimalSeparator) -> String {
        v != 0 ? "−" + num(v, 0, decimal: decimal) : "±0"
    }

    private func octavePicker(_ label: Text, _ value: String, set: @escaping @MainActor @Sendable (String) -> Void) -> some View {
        Picker(selection: Binding(get: { value }, set: { set($0) })) {
            ForEach(octaveTypes) { t in
                Text(verbatim: t.id).tag(t.id)
            }
        } label: {
            label
        }
    }

    private func stretchName(_ id: String) -> Text {
        switch id {
        case "none": Text("None (theoretical equal temperament)", tableName: "Inspector")
        case "light": Text("Light", tableName: "Inspector")
        case "normal": Text("Normal", tableName: "Inspector")
        case "wide": Text("Wide (concert)", tableName: "Inspector")
        case "railsback": Text("Railsback curve", tableName: "Inspector")
        case "custom": Text("Custom", tableName: "Inspector")
        default: Text(verbatim: id)
        }
    }

    private func stretchDescription(_ id: String) -> Text? {
        switch id {
        case "none": Text("Exactly 1200 cents per octave. Sounds too narrow on a real piano; useful for comparison.", tableName: "Inspector")
        case "light": Text("Pure 2:1 octaves in the treble and 4:2 in the bass. Good for small pianos and a soft sound.", tableName: "Inspector")
        case "normal": Text("The most common compromise: 4:2 in the middle and treble, 6:3 in the bass.", tableName: "Inspector")
        case "wide": Text("More stretch for large grands and concert use: 8:4 in the bass and extra height in the treble.", tableName: "Inspector")
        case "railsback": Text("Fixed average curve after Railsback’s measurements (≈ −25 cents at A0, +30 cents at C8). Does not use inharmonicity.", tableName: "Inspector")
        case "custom": Text("Choose the octave type for bass, middle and treble yourself.", tableName: "Inspector")
        default: nil
        }
    }
}

/// The historical temperaments and their root, folded away unless one is
/// in use.
struct TemperamentSection: View {
    let piano: Piano
    @Environment(TunerModel.self) private var tuner
    @State private var expanded = false

    var body: some View {
        let s = piano.settings
        let id = piano.id
        Section(isExpanded: $expanded) {
            InspectorNote(Text("For harpsichords, organs and early music. Modern pianos are tuned in equal temperament; with the others some keys sound out of tune.", tableName: "Inspector"))
            Picker(selection: Binding(get: { s.temperament }, set: { v in tuner.setSettings(id) { $0.temperament = v } })) {
                ForEach(temperaments) { t in
                    temperamentName(t.id).tag(t.id)
                }
            } label: {
                Text("Temperament", tableName: "Inspector")
            }
            if let desc = temperamentDescription(s.temperament) { InspectorNote(desc) }
            Picker(selection: Binding(get: { s.root }, set: { v in tuner.setSettings(id) { $0.root = v } })) {
                ForEach(0..<12, id: \.self) { pc in
                    Text(verbatim: pcName(pc)).tag(pc)
                }
            } label: {
                Text("Root", tableName: "Inspector")
            }
            .disabled(s.temperament == "et")
        } header: {
            Text("Historical temperaments", tableName: "Inspector")
        }
        // Never hide a historical temperament in use.
        .onChange(of: s.temperament, initial: true) {
            if s.temperament != "et" { expanded = true }
        }
    }

    private func temperamentName(_ id: String) -> Text {
        switch id {
        case "et": Text("Equal temperament", tableName: "Inspector")
        case "werckmeister3": Text("Werckmeister III (1691)", tableName: "Inspector")
        case "kirnberger3": Text("Kirnberger III (1779)", tableName: "Inspector")
        case "vallotti": Text("Vallotti (18th century)", tableName: "Inspector")
        case "young2": Text("Young II (1799)", tableName: "Inspector")
        case "meantone4": Text("Quarter-comma meantone", tableName: "Inspector")
        case "meantone6": Text("Sixth-comma meantone", tableName: "Inspector")
        default: Text(verbatim: id)
        }
    }

    private func temperamentDescription(_ id: String) -> Text? {
        switch id {
        case "et": Text("Every fifth is narrowed by the same amount (1/12 Pythagorean comma). Standard for modern pianos; all keys sound alike.", tableName: "Inspector")
        case "werckmeister3": Text("Four fifths (C–G, G–D, D–A, B–F♯) are narrowed by 1/4 PC, the rest are pure. Keys with few accidentals sound purer.", tableName: "Inspector")
        case "kirnberger3": Text("C–G–D–A–E are narrowed by 1/4 syntonic comma (pure major third C–E), F♯–C♯ by a schisma.", tableName: "Inspector")
        case "vallotti": Text("Six fifths F–C–G–D–A–E–B are narrowed by 1/6 PC, the other six are pure. A mild well temperament.", tableName: "Inspector")
        case "young2": Text("Like Vallotti but shifted one fifth: C–G–D–A–E–B–F♯ are narrowed by 1/6 PC.", tableName: "Inspector")
        case "meantone4": Text("Pure major thirds in the common keys. The wolf fifth G♯–E♭ makes remote keys unusable.", tableName: "Inspector")
        case "meantone6": Text("Milder meantone (Silbermann). The wolf fifth G♯–E♭ is smaller but still there.", tableName: "Inspector")
        default: nil
        }
    }
}
