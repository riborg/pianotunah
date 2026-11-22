import PianoTunahCore
import SwiftUI

/// The pass (the web's Pass tab): how far it has come, a new pass after a
/// confirmation, and the history of earlier ones, latest first.
struct PassSection: View {
    let piano: Piano
    let snapshot: TunerSnapshot?
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale
    @State private var confirming = false
    @State private var started = false

    var body: some View {
        let decimal = DecimalSeparator(locale)
        let stats = snapshot?.passStats
        let top = snapshot?.top ?? (piano.settings.keyCount == 85 ? 85 : keyCount)
        Section {
            LabeledContent {
                Text(verbatim: "\(stats?.ok ?? 0)/\(top)").monospacedDigit()
            } label: {
                Text("Within tolerance", tableName: "Inspector")
            }
            LabeledContent {
                Text(verbatim: String(stats?.measured ?? 0)).monospacedDigit()
            } label: {
                Text("Measured", tableName: "Inspector")
            }
            LabeledContent {
                Text(verbatim: inspectorDate(piano.passStartedAt.isEmpty ? piano.createdAt : piano.passStartedAt))
            } label: {
                Text("Started", tableName: "Inspector")
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    confirming = true
                } label: {
                    Text("New pass", tableName: "Inspector").frame(maxWidth: .infinity)
                }
                .confirmationDialog(
                    Text("Save the pass to the history and start over?", tableName: "Inspector"),
                    isPresented: $confirming
                ) {
                    Button {
                        tuner.newPass(piano.id)
                        started = true
                    } label: {
                        Text("New pass", tableName: "Inspector")
                    }
                }
                if started {
                    InspectorNote(Text("New pass started. Inharmonicity and settings are kept.", tableName: "Inspector"))
                }
            }

            if !piano.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History", tableName: "Inspector").font(.headline)
                    ForEach(Array(piano.history.enumerated().reversed()), id: \.offset) { _, p in
                        Text("\(inspectorDate(p.startedAt)): \(String(p.measured)) keys, ref \(num(p.refA4, 1, decimal: decimal)) Hz, before \(num(p.meanAbsBefore, 1, decimal: decimal)) cents → after \(num(p.meanAbsAfter, 1, decimal: decimal)) cents on average", tableName: "Inspector")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Pass", tableName: "Inspector")
        }
    }
}
