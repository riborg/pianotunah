import PianoTunahCore
import SwiftUI

/// The Partials fold (index.html: #partials-row): partials 1–8 of the
/// sounding key against their targets, the one being measured highlighted;
/// the partial to measure; the key's B and the button that measures it.
struct PartialsFold: View {
    let snapshot: TunerSnapshot
    let palette: Palette
    @Environment(TunerModel.self) private var tuner
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        VStack(alignment: .leading, spacing: 8) {
            Text("Deviation per partial for the sounding key. Highlighted = the one being measured.", tableName: "Folds")
                .font(.system(size: 13))
                .foregroundStyle(palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(1...8, id: \.self) { n in
                    PartialCell(
                        partial: n,
                        reading: snapshot.folds.partials.indices.contains(n - 1) ? snapshot.folds.partials[n - 1] : nil,
                        selected: n == snapshot.partial,
                        decimal: decimal,
                        palette: palette
                    )
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    picker
                    Spacer(minLength: 0)
                    inharmonicity(decimal)
                }
                VStack(alignment: .leading, spacing: 8) {
                    picker
                    inharmonicity(decimal)
                }
            }
        }
    }

    /// Measure partial − n +.
    private var picker: some View {
        HStack(spacing: 6) {
            Text("Measure partial", tableName: "Folds")
                .foregroundStyle(palette.muted.color)
            Button {
                tuner.stepPartial(-1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(snapshot.partial <= 1)
            .help(Text("Lower partial", tableName: "Folds"))
            .accessibilityLabel(Text("Lower partial", tableName: "Folds"))
            Text(verbatim: String(snapshot.partial))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.ink.color)
                .frame(minWidth: 16)
                .accessibilityLabel(Text("Measure partial", tableName: "Folds"))
                .accessibilityValue(Text(verbatim: String(snapshot.partial)))
            Button {
                tuner.stepPartial(1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(snapshot.partial >= 8)
            .help(Text("Higher partial", tableName: "Folds"))
            .accessibilityLabel(Text("Higher partial", tableName: "Folds"))
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .fixedSize()
    }

    /// The key's B, where it comes from, and the button that measures it.
    private func inharmonicity(_ decimal: DecimalSeparator) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: bText(decimal))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                tuner.measureInharmonicity()
            } label: {
                Text("Measure inharmonicity (B)", tableName: "Folds")
            }
            .disabled(snapshot.folds.measuringB)
            .help(Text("B: how far the string's overtones lie above whole multiples of the fundamental, from its stiffness. The stretch is computed from it. Press, then strike the key firmly.", tableName: "Folds"))
        }
    }

    /// "Inharmonicity B = … (measured)", a whole sentence per source.
    private func bText(_ decimal: DecimalSeparator) -> String {
        let key = snapshot.keys[snapshot.key]
        let b = fmtB(key?.b ?? snapshot.toneB, decimal: decimal)
        guard let key, key.measuredB else {
            return String(localized: "Inharmonicity B = \(b) (model)", table: "Folds")
        }
        return key.bOutlier
            ? String(localized: "Inharmonicity B = \(b) (measured, differs from the neighbours and is not used)", table: "Folds")
            : String(localized: "Inharmonicity B = \(b) (measured)", table: "Folds")
    }
}

/// A partial's number and its deviation, colored by status; the measured
/// one has an accent border.
private struct PartialCell: View {
    let partial: Int
    let reading: PartialReading?
    let selected: Bool
    let decimal: DecimalSeparator
    let palette: Palette

    var body: some View {
        let cents = reading?.cents ?? .nan
        let value = fmtC(cents, decimal: decimal)
        VStack(spacing: 1) {
            Text(verbatim: String(partial))
                .font(.system(size: 11))
                .foregroundStyle(palette.muted.color)
            Text(verbatim: value)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(cents.isFinite ? palette.status(reading?.status).color : palette.ink.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.sunk.color))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? palette.accent.color : .clear, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cents.isFinite
            ? Text("Partial \(partial): \(value) cents", tableName: "Folds")
            : Text("Partial \(partial): not heard", tableName: "Folds"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
