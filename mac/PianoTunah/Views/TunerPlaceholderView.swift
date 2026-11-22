import PianoTunahCore
import SwiftUI

/// Stands in for the tuner until the audio and the real views come: the
/// piano's name, and what the core computes for it, to show that the core
/// is wired in.
struct TunerPlaceholderView: View {
    let piano: Piano
    @Environment(PianoLibrary.self) private var library
    @Environment(\.locale) private var locale

    var body: some View {
        // A new engine each time the piano changes; computing the targets
        // is quick. The real tuner keeps one engine on its analysis queue.
        let engine = Engine(piano: piano)
        let decimal = DecimalSeparator(locale)
        Form {
            TextField("Name", text: Binding(
                get: { piano.name },
                set: { library.rename(piano.id, to: $0) }
            ))
            Section("Target") {
                LabeledContent("A4", value: fmtHz(engine.targets.frequency[a4], 2, decimal: decimal))
                LabeledContent("A4 from equal temperament", value: fmtC(engine.targets.cents[a4], 1, decimal: decimal) + " ¢")
                LabeledContent("Keys", value: String(engine.top))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(piano.name.isEmpty ? String(localized: "Untitled") : piano.name)
    }
}

extension DecimalSeparator {
    /// The separator the locale writes numbers with.
    init(_ locale: Locale) {
        self = locale.decimalSeparator == "," ? .comma : .point
    }
}
