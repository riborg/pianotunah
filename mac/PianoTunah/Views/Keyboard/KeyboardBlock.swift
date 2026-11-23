import PianoTunahCore
import SwiftUI

/// The block under the dial (index.html: .keys-block): the marker over the
/// current key, the target curve, the keyboard, the hint to survey while the
/// curve is only estimated, the legend with the curve's fold, and the keys
/// as a table.
struct KeyboardBlock: View {
    let snapshot: TunerSnapshot
    @Environment(TunerModel.self) private var tuner
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The curve is shown (the web's curve fold).
    @AppStorage("curveOpen") private var curveOpen = true
    @State private var tableOpen = false

    /// The room above the keys for the marker.
    static let markerRoom = 30.0
    static let keyboardHeight = 56.0
    static let curveHeight = 96.0

    var body: some View {
        let palette = Palette.of(scheme)
        let keys = snapshot.keys
        let current = min(snapshot.key, max(1, keys.top))
        // No keys until the engine's first snapshot.
        if keys.top > 0 {
            content(keys: keys, current: current, palette: palette)
        }
    }

    private func content(keys: TunerKeys, current: Int, palette: Palette) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.markerRoom)
                if curveOpen {
                    CurveView(keys: keys, current: current) { tuner.selectKey($0) }
                        .frame(height: Self.curveHeight)
                        .padding(.bottom, 4)
                        .zIndex(1) // the tooltip over the keys
                }
                KeyboardView(keys: keys, current: current, flash: snapshot.flash) { tuner.clickKey($0) }
                    .frame(height: Self.keyboardHeight)
                    .padding(.horizontal, KeyboardLayout.inset)
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    KeyMarker(key: current, good: keys[current]?.status == .good, palette: palette)
                        .position(x: KeyboardLayout(top: keys.top).x(current, width: geo.size.width), y: 4 + KeyMarker.height / 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: current)
                }
                .allowsHitTesting(false)
            }
            // Until some inharmonicity is measured, the curve comes from the model.
            if curveOpen && snapshot.mode != .survey && !keys.anyMeasuredB {
                CurveHint(palette: palette) { tuner.surveyAllA() }
            }
            KeyboardLegend(palette: palette, curveOpen: $curveOpen)
            // Folded with the curve, as on the web.
            if curveOpen {
                DisclosureGroup(isExpanded: $tableOpen) {
                    // Not built while closed.
                    if tableOpen {
                        KeyTable(keys: keys, current: current, select: { tuner.selectKey($0) }, step: { tuner.step($0) })
                            .padding(.top, 8)
                    }
                } label: {
                    Text("Show as table", tableName: "Keyboard")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.accent.color)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The flag above the current key: its name on the accent, or on green when
/// it is in tune.
private struct KeyMarker: View {
    let key: Int
    let good: Bool
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    static let height = 28.0

    var body: some View {
        let fill = good ? palette.good : palette.accent
        let ink = good ? palette.surface : KeyColors.of(scheme).accentInk
        VStack(spacing: 0) {
            Text(noteText(noteName(key), size: 13))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(ink.color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(fill.color))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            MarkerPointer()
                .fill(fill.color)
                .frame(width: 12, height: 6)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// The triangle under the marker, pointing down.
private struct MarkerPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// What the colors and the dot mean.
private struct KeyboardLegend: View {
    let palette: Palette
    @Binding var curveOpen: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button {
                curveOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: curveOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Curve", tableName: "Keyboard")
                }
                .foregroundStyle(palette.accent.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            swatch(palette.good, Text("Within tolerance", tableName: "Keyboard"))
            swatch(palette.warn, Text("Close", tableName: "Keyboard"))
            swatch(palette.bad, Text("Outside", tableName: "Keyboard"))
            item(Circle().fill(palette.accent.color).frame(width: 6, height: 6), Text("Measured B", tableName: "Keyboard"))
            if curveOpen {
                item(Capsule().fill(palette.accent.color).frame(width: 16, height: 2), Text("Target vs equal temperament", tableName: "Keyboard"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.muted.color)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private func swatch(_ color: RGB, _ label: Text) -> some View {
        item(RoundedRectangle(cornerRadius: 3).fill(color.color).frame(width: 12, height: 12), label)
    }

    private func item(_ mark: some View, _ label: Text) -> some View {
        HStack(spacing: 5) {
            mark.accessibilityHidden(true)
            label
        }
    }
}

/// Under the curve until some B is measured: the curve is estimated from
/// the piano's size, and an All A survey measures it.
private struct CurveHint: View {
    let palette: Palette
    let survey: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("The curve is estimated from the size of the piano.", tableName: "Keyboard")
                .foregroundStyle(palette.ink.color)
            Button(action: survey) {
                Text("Survey all A", tableName: "Keyboard")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line.color, lineWidth: 1))
    }
}
