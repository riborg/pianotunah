import PianoTunahCore
import SwiftUI

/// The target curve over the keyboard (draw.js: drawChart with xs): the
/// target in cents from equal temperament key by key, so the temperament's
/// jaggedness shows, and a dot per measured key in its status color, at
/// target plus deviation. The x positions are the keys' centres from
/// `KeyboardLayout`, so each point sits over its key.
///
/// Hovering shows the key's target, B and deviation; a click selects the
/// nearest key.
struct CurveView: View {
    let keys: TunerKeys
    let current: Int
    let select: (Int) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Int?
    /// The tooltip's size, nil until it is first laid out.
    @State private var tipSize: CGSize?

    var body: some View {
        let palette = Palette.of(scheme)
        GeometryReader { geo in
            let size = geo.size
            let chart = CurveGeometry(keys: keys, size: size)
            Canvas { context, _ in
                chart.draw(in: &context, current: current, palette: palette)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = keys.top > 0 ? chart.key(at: p.x) : nil
                case .ended: hovered = nil
                }
            }
            .onTapGesture { p in
                if keys.top > 0 { select(chart.key(at: p.x)) }
            }
            .overlay(alignment: .topLeading) {
                if let k = hovered, let state = keys[k] {
                    CurveTip(state: state, palette: palette)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                        // Within the curve, right of the key, above its target;
                        // hidden until measured, or it would stick out a frame.
                        .offset(
                            x: max(4, min(chart.x(k) + 12, size.width - (tipSize?.width ?? 0) - 4)),
                            y: max(4, chart.y(state.targetCents) - (tipSize?.height ?? 0) - 10)
                        )
                        .opacity(tipSize == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Target curve in cents per key", tableName: "Keyboard"))
    }
}

/// The curve's scales for a size: the range covers the target and the
/// points, at least ±10 cents, in steps of 10, 20, 50 or 100 cents so that a
/// row is at least 16 points high.
///
/// The points stretch the range to ±`reach` cents at most, so that one wild
/// reading does not flatten the curve; a point beyond the range is drawn at
/// its edge as a triangle pointing out. The web's drawChart does not limit
/// the range.
private struct CurveGeometry {
    let keys: TunerKeys
    let layout: KeyboardLayout
    let size: CGSize
    let yMin: Double
    let yMax: Double
    let step: Double

    static let padTop = 8.0
    static let padBottom = 6.0
    static let reach = 100.0

    init(keys: TunerKeys, size: CGSize) {
        self.keys = keys
        self.size = size
        layout = KeyboardLayout(top: keys.top)
        var lo = -10.0
        var hi = 10.0
        for s in keys.states {
            guard s.targetCents.isFinite else { continue }
            lo = min(lo, s.targetCents)
            hi = max(hi, s.targetCents)
            let c = s.targetCents + s.now
            if c.isFinite {
                lo = min(lo, max(c, -Self.reach))
                hi = max(hi, min(c, Self.reach))
            }
        }
        let room = (size.height - Self.padTop - Self.padBottom) / 16
        func lines(_ s: Double) -> Double { (hi / s).rounded(.up) - (lo / s).rounded(.down) }
        let step = [10.0, 20, 50, 100].first { lines($0) <= room } ?? 100
        self.step = step
        yMin = (lo / step).rounded(.down) * step
        yMax = (hi / step).rounded(.up) * step
    }

    func x(_ k: Int) -> Double { layout.x(k, width: size.width) }

    func y(_ c: Double) -> Double {
        Self.padTop + (yMax - c) / (yMax - yMin) * (size.height - Self.padTop - Self.padBottom)
    }

    func key(at x: Double) -> Int { layout.nearest(x: x, width: size.width) }

    func draw(in context: inout GraphicsContext, current: Int, palette: Palette) {
        guard keys.top > 0, size.width > 2 * KeyboardLayout.inset else { return }
        let left = KeyboardLayout.inset
        let right = size.width - KeyboardLayout.inset
        let bottom = size.height - Self.padBottom

        // The grid: a line per step, 0 darker, and one per C.
        for c in stride(from: yMin, through: yMax, by: step) {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(c)))
            line.addLine(to: CGPoint(x: right, y: y(c)))
            context.stroke(line, with: .color((c == 0 ? palette.muted : palette.line).color), lineWidth: 1)
        }
        for k in 1...keys.top where pitchClass(k) == 0 {
            var line = Path()
            line.move(to: CGPoint(x: x(k), y: Self.padTop))
            line.addLine(to: CGPoint(x: x(k), y: bottom))
            context.stroke(line, with: .color(palette.line.color), lineWidth: 1)
        }

        // The current key.
        var cur = Path()
        cur.move(to: CGPoint(x: x(current), y: Self.padTop))
        cur.addLine(to: CGPoint(x: x(current), y: bottom))
        context.stroke(cur, with: .color(palette.accent.color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // The target, key by key.
        var target = Path()
        for s in keys.states {
            let p = CGPoint(x: x(s.key), y: y(s.targetCents))
            if s.key == 1 { target.move(to: p) } else { target.addLine(to: p) }
        }
        context.stroke(target, with: .color(palette.accent.color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        // The measured keys; beyond the range at its edge, pointing out.
        for s in keys.states where s.now.isFinite {
            let cents = s.targetCents + s.now
            let c = CGPoint(x: x(s.key), y: y(min(max(cents, yMin), yMax)))
            let color = palette.status(s.status).color
            if cents > yMax || cents < yMin {
                let out = Self.outside(c, up: cents > yMax)
                context.stroke(out, with: .color(palette.surface.color), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                context.fill(out, with: .color(color))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)), with: .color(palette.surface.color))
                context.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color))
            }
        }

        // The scale on top of the curve, with a halo so it stays readable
        // where the curve passes; none below the bottom line.
        let font = Font.system(size: 11, design: .monospaced)
        for c in stride(from: yMin + step, through: yMax, by: step) {
            let label = Self.signed(c)
            let halo = context.resolve(Text(verbatim: label).font(font).foregroundStyle(palette.surface.color))
            let ink = context.resolve(Text(verbatim: label).font(font).foregroundStyle(palette.muted.color))
            let at = CGPoint(x: left + 2, y: y(c) + 8)
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0), (0, -1.5), (0, 1.5), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                context.draw(halo, at: CGPoint(x: at.x + dx, y: at.y + dy), anchor: .leading)
            }
            context.draw(ink, at: at, anchor: .leading)
        }
    }

    /// A point beyond the range: a triangle on the edge at `c`, pointing up
    /// or down, out of the curve.
    static func outside(_ c: CGPoint, up: Bool) -> Path {
        let tip = up ? -5.0 : 5.0
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y + tip))
        p.addLine(to: CGPoint(x: c.x - 5, y: c.y - tip))
        p.addLine(to: CGPoint(x: c.x + 5, y: c.y - tip))
        p.closeSubpath()
        return p
    }

    /// A scale label: "0", "+20", "−20".
    static func signed(_ c: Double) -> String {
        let n = Int(abs(c).rounded())
        return n == 0 ? "0" : (c > 0 ? "+" : "−") + String(n)
    }
}

/// The tooltip of the hovered key (app.js: chartHover).
private struct CurveTip: View {
    let state: KeyState
    let palette: Palette
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        let s = state
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            row(Text(noteText(noteName(s.key), size: 12)), Text("key \(s.key)", tableName: "Keyboard"))
            row(
                Text("Target", tableName: "Keyboard"),
                Text("\(fmtC(s.targetCents, decimal: decimal)) cents · \(fmtHz(s.targetHz, decimal: decimal))", tableName: "Keyboard")
            )
            row(Text(verbatim: "B"), bText(decimal))
            if s.now.isFinite {
                row(Text("Deviation", tableName: "Keyboard"), Text("\(fmtC(s.deviation, decimal: decimal)) cents", tableName: "Keyboard"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.ink.color)
        .frame(minWidth: 180, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func row(_ name: Text, _ value: Text) -> some View {
        GridRow {
            name.fontWeight(.semibold)
            value
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// B and where it comes from (app.js: bSource).
    private func bText(_ decimal: DecimalSeparator) -> Text {
        let b = fmtB(state.b, decimal: decimal)
        if !state.measuredB { return Text("\(b) model", tableName: "Keyboard") }
        if state.bOutlier { return Text("\(b) measured, differs from the neighbours and is not used", tableName: "Keyboard") }
        return Text("\(b) measured", tableName: "Keyboard")
    }
}
