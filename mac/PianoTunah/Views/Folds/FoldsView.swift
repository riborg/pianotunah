import PianoTunahCore
import SwiftUI

/// The folds under the dial (index.html: .fold-box): the beats around the
/// target and the partials of the sounding key. Both are closed at first;
/// whether each is open is remembered. A closed fold is not drawn, and the
/// core copies the spectrogram only while the Beats fold is open.
struct FoldsView: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    @Environment(TunerModel.self) private var tuner
    @Environment(\.colorScheme) private var scheme
    @AppStorage("beatsOpen") private var beatsOpen = false
    @AppStorage("partialsOpen") private var partialsOpen = false

    var body: some View {
        let palette = Palette.of(scheme)
        VStack(spacing: 6) {
            Fold(isOpen: $beatsOpen, palette: palette) {
                Text("Beats around the target, ±30 cents", tableName: "Folds")
            } accessory: {
                BeatRate(snapshot: snapshot, listening: listening, palette: palette)
            } content: {
                BeatsFold(snapshot: snapshot, listening: listening, palette: palette)
            }
            Fold(isOpen: $partialsOpen, palette: palette) {
                Text("Partials vs target", tableName: "Folds")
            } accessory: {
                EmptyView()
            } content: {
                PartialsFold(snapshot: snapshot, palette: palette)
            }
        }
        .onAppear { tuner.setBeatsFoldOpen(beatsOpen) }
        .onChange(of: beatsOpen) { tuner.setBeatsFoldOpen(beatsOpen) }
        .onDisappear { tuner.setBeatsFoldOpen(false) }
    }
}

/// A fold: a line above, the title as a disclosure, something beside the
/// title on the right, and the content, which is not built while closed.
private struct Fold<Title: View, Accessory: View, Content: View>: View {
    @Binding var isOpen: Bool
    let palette: Palette
    @ViewBuilder var title: Title
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: 1)
                .accessibilityHidden(true)
            DisclosureGroup(isExpanded: $isOpen) {
                if isOpen {
                    content
                        .padding(.top, 6)
                }
            } label: {
                Button {
                    isOpen.toggle()
                } label: {
                    title
                        .font(.system(size: 14))
                        .foregroundStyle(palette.accent.color)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
            }
            .overlay(alignment: .topTrailing) {
                accessory
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Whether two tones Δf Hz apart beat, and how fast (app.js: beat-rate).
struct BeatRate: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    let palette: Palette
    @Environment(\.locale) private var locale

    /// A reading to show beats for.
    static func live(_ s: TunerSnapshot, listening: Bool) -> Bool {
        listening && s.signal && s.cents.isFinite && s.folds.beatHz.isFinite
    }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.ink.color)
    }

    private var text: String {
        guard Self.live(snapshot, listening: listening) else { return "–" }
        let df = abs(snapshot.folds.beatHz)
        if df < 0.1 { return String(localized: "Beatless", table: "Folds") }
        let n = num(df, df < 10 ? 1 : 0, decimal: DecimalSeparator(locale))
        return String(localized: "\(n) beats/s", table: "Folds")
    }
}
