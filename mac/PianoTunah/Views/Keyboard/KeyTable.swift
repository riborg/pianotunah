import PianoTunahCore
import SwiftUI

extension KeyState: Identifiable {
    var id: Int { key }
}

/// The keys as a table (app.js: renderTable): key, note, target in cents
/// and Hz, B, partial, Before and Now, highest key first and sortable by
/// key. Now has its status color; B is marked * when measured and ? when it
/// differs from its neighbours. The current key is the selected row, and
/// selecting a row selects its key, as a click on the keyboard does: it
/// leaves Auto (the web's table takes no clicks).
///
/// The table keeps the focus it gets from a click, although TunerView takes
/// the focus on every tap. ↑ and ↓ step the key the way ← and → do, from the
/// engine's key, so the two never fight over a key not yet shown.
struct KeyTable: View {
    let keys: TunerKeys
    let current: Int
    let select: (Int) -> Void
    /// The key `delta` steps up or down.
    let step: (Int) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.locale) private var locale
    @State private var sortOrder = [KeyPathComparator(\KeyState.key, order: .reverse)]
    @FocusState private var focused: Bool

    var body: some View {
        let palette = Palette.of(scheme)
        let decimal = DecimalSeparator(locale)
        let selection = Binding<Int?>(
            get: { current },
            set: { if let k = $0, k != current { select(k) } }
        )
        ScrollViewReader { proxy in
            Table(keys.states.sorted(using: sortOrder), selection: selection, sortOrder: $sortOrder) {
                TableColumn(Text("Key", tableName: "Keyboard"), value: \.key) { s in
                    Text(verbatim: String(s.key))
                }
                .alignment(.trailing)
                TableColumn(Text("Note", tableName: "Keyboard")) { s in
                    Text(verbatim: noteName(s.key))
                }
                .alignment(.trailing)
                TableColumn(Text("Target (cents)", tableName: "Keyboard")) { s in
                    Text(verbatim: fmtC(s.targetCents, decimal: decimal))
                }
                .alignment(.trailing)
                TableColumn(Text("Target (Hz)", tableName: "Keyboard")) { s in
                    Text(verbatim: num(s.targetHz, 2, decimal: decimal))
                }
                .alignment(.trailing)
                TableColumn(Text(verbatim: "B")) { s in
                    Text(verbatim: fmtB(s.b, decimal: decimal) + (s.bOutlier ? " ?" : s.measuredB ? " *" : ""))
                }
                .alignment(.trailing)
                TableColumn(Text("Partial", tableName: "Keyboard")) { s in
                    Text(verbatim: String(s.partial))
                }
                .alignment(.trailing)
                TableColumn(Text("Before", tableName: "Keyboard")) { s in
                    Text(verbatim: fmtC(s.before, decimal: decimal))
                }
                .alignment(.trailing)
                TableColumn(Text("Now", tableName: "Keyboard")) { s in
                    Text(verbatim: fmtC(s.deviation, decimal: decimal))
                        .foregroundStyle(s.status == .noReading ? Color.primary : palette.status(s.status).color)
                }
                .alignment(.trailing)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 420)
            // The current key in view, also when ← → or the keyboard choose it.
            .onChange(of: current, initial: true) { proxy.scrollTo(current) }
            .focused($focused)
            // After TunerView's tap, which takes the focus for the whole tuner.
            .simultaneousGesture(TapGesture().onEnded { Task { @MainActor in focused = true } })
            .onKeyPress(.upArrow) { stepRow(-1) }
            .onKeyPress(.downArrow) { stepRow(1) }
        }
    }

    /// The key `rows` rows down the table: highest first, a row down is a
    /// key down.
    private func stepRow(_ rows: Int) -> KeyPress.Result {
        step(sortOrder.first?.order == .forward ? rows : -rows)
        return .handled
    }
}
