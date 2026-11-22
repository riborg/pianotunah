import PianoTunahCore
import SwiftUI

/// The piano itself (the web's Piano tab): name, instrument and size, keys,
/// strings per key, unisons and notes.
struct PianoSection: View {
    let piano: Piano
    @Environment(PianoLibrary.self) private var library
    @Environment(TunerModel.self) private var tuner

    var body: some View {
        let s = piano.settings
        let id = piano.id
        let kind = pianoKind(s.pianoKind) ?? pianoKinds[0]
        let top = s.keyCount == 85 ? 85 : keyCount
        Section {
            TextField(text: Binding(get: { piano.name }, set: { library.rename(id, to: $0) })) {
                Text("Name", tableName: "Inspector")
            }

            Picker(selection: Binding(get: { kind.id }, set: { tuner.setPianoKind(id, $0) })) {
                Text("Upright piano", tableName: "Inspector").tag("upright")
                Text("Grand piano", tableName: "Inspector").tag("grand")
            } label: {
                Text("Instrument", tableName: "Inspector")
            }

            LabeledContent {
                HStack(spacing: 4) {
                    TextField(
                        value: Binding(get: { s.sizeCm }, set: { tuner.setSize(id, $0) }),
                        format: .number.precision(.fractionLength(0))
                    ) {
                        sizeLabel(kind.id)
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    Text(verbatim: "cm")
                }
            } label: {
                sizeLabel(kind.id)
                sizeClassName(sizeClass(kind.id, s.sizeCm))
            }
            InspectorNote(kind.id == "grand"
                ? Text("Measure from the front edge of the keyboard to the tail. Used as the initial guess for the strings’ inharmonicity until the piano is surveyed.", tableName: "Inspector")
                : Text("Measure from the floor to the top of the lid. Used as the initial guess for the strings’ inharmonicity until the piano is surveyed.", tableName: "Inspector"))

            Picker(selection: Binding(get: { top }, set: { n in tuner.setSettings(id) { $0.keyCount = n } })) {
                Text("88 (A0–C8)", tableName: "Inspector").tag(88)
                Text("85 (A0–A7, older piano)", tableName: "Inspector").tag(85)
            } label: {
                Text("Keys", tableName: "Inspector")
            }

            StringsRow(value: s.twoStringsTo, top: top, set: { tuner.setStrings(id, two: $0, one: s.oneStringTo) }) {
                Text("Two strings up to key", tableName: "Inspector")
            }
            StringsRow(value: s.oneStringTo, top: top, set: { tuner.setStrings(id, two: s.twoStringsTo, one: $0) }) {
                Text("One string up to key", tableName: "Inspector")
            }
            Picker(selection: Binding(get: { s.unisons == "dsu" ? "dsu" : "one" }, set: { tuner.setUnisons(id, $0) })) {
                Text("One string first", tableName: "Inspector").tag("one")
                Text("Double string unison (DSU)", tableName: "Inspector").tag("dsu")
            } label: {
                Text("Unisons", tableName: "Inspector")
            }
            InspectorNote(Text("Counted from A0 = 1; 0 = none. The tuning order uses it for which keys need a wedge and which have no unison to tune.", tableName: "Inspector"))

            TextField(
                text: Binding(get: { piano.notes }, set: { library.setNotes(id, $0) }),
                prompt: Text("Make, model, room, humidity …", tableName: "Inspector"),
                axis: .vertical
            ) {
                Text("Notes", tableName: "Inspector")
            }
            .lineLimit(3...8)
        } header: {
            Text("Piano", tableName: "Inspector")
        }
    }

    private func sizeLabel(_ kind: String) -> Text {
        kind == "grand" ? Text("Length", tableName: "Inspector") : Text("Height", tableName: "Inspector")
    }

    private func sizeClassName(_ c: SizeClass) -> Text {
        switch c {
        case .smallUpright: Text("small upright", tableName: "Inspector")
        case .midUpright: Text("medium upright", tableName: "Inspector")
        case .tallUpright: Text("tall upright", tableName: "Inspector")
        case .babyGrand: Text("baby grand", tableName: "Inspector")
        case .parlourGrand: Text("parlour grand", tableName: "Inspector")
        case .concertGrand: Text("concert grand", tableName: "Inspector")
        }
    }
}

/// A key number for the strings per key, with the note it is (or "none"
/// for 0). The engine clamps it to the keyboard, one string never above
/// two.
private struct StringsRow<Label: View>: View {
    let value: Int
    let top: Int
    let set: @MainActor @Sendable (Int) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(value: Binding(get: { value }, set: { set($0) }), format: .number) {
                    label()
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                Stepper(value: Binding(get: { value }, set: { set($0) }), in: 0...top) {
                    label()
                }
                .labelsHidden()
            }
        } label: {
            label()
            if value > 0 {
                Text(verbatim: noteName(value))
            } else {
                Text("none", tableName: "Inspector")
            }
        }
    }
}

/// New, Duplicate, Import, Export and Delete, as in the Piano menu.
struct SavedPianosSection: View {
    @Environment(PianoLibrary.self) private var library

    var body: some View {
        Section {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    button(Text("New", tableName: "Inspector")) { library.newPiano() }
                    button(Text("Duplicate", tableName: "Inspector")) { library.duplicateSelected() }
                }
                GridRow {
                    button(Text("Import…", tableName: "Inspector")) { library.isImporting = true }
                    button(Text("Export…", tableName: "Inspector")) { library.beginExport() }
                }
                GridRow {
                    Button(role: .destructive) {
                        library.requestDelete()
                    } label: {
                        Text("Delete…", tableName: "Inspector").frame(maxWidth: .infinity)
                    }
                    .gridCellColumns(2)
                }
            }
        } header: {
            Text("Saved pianos", tableName: "Inspector")
        }
    }

    private func button(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title.frame(maxWidth: .infinity)
        }
    }
}
