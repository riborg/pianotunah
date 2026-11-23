import PianoTunahCore
import SwiftUI

/// The keys' own colors (web/style.css: --ivory, --ebony and the rest).
struct KeyColors {
    var ivory: RGB
    var ebony: RGB
    var gap: RGB
    var ivoryHover: RGB
    var ebonyHover: RGB
    var label: RGB
    var current: RGB
    var currentInk: RGB
    /// Text on the accent.
    var accentInk: RGB

    static let light = KeyColors(
        ivory: RGB(0xFFFDF6), ebony: RGB(0x1B1D1F), gap: RGB(0xB9B3A3), ivoryHover: RGB(0xFFF9E8),
        ebonyHover: RGB(0x3A3D42), label: RGB(0x6D6A60), current: RGB(0xDCEBF8), currentInk: RGB(0x2C5A85),
        accentInk: RGB(0xFFFFFF)
    )

    static let dark = KeyColors(
        ivory: RGB(0xD9D6CC), ebony: RGB(0x050607), gap: RGB(0x8A8678), ivoryHover: RGB(0xE6E2D6),
        ebonyHover: RGB(0x2A2D31), label: RGB(0x55534C), current: RGB(0xB9D3EC), currentInk: RGB(0x234D75),
        accentInk: RGB(0x0E1213)
    )

    static func of(_ scheme: ColorScheme) -> KeyColors {
        scheme == .dark ? dark : light
    }
}

/// The keyboard (app.js: renderKeyboard): flat keys, a map of the piano
/// rather than a picture of one. The current key is filled with the accent,
/// a dot at the top marks a measured B, a dashed outline the key the survey
/// or the order asks for, and the Cs are labelled. A key that is done
/// flashes for 700 ms; with Reduce Motion it is only highlighted.
///
/// One `Canvas`, not 88 buttons. A click selects the key under the pointer.
struct KeyboardView: View {
    let keys: TunerKeys
    let current: Int
    let flash: KeyFlash?
    let select: (Int) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var hovered: Int?
    @State private var flashing: Flashing?

    /// A flash under way.
    private struct Flashing: Equatable {
        var key: Int
        var start: Date
    }

    static let flashDuration = 0.7

    var body: some View {
        let layout = KeyboardLayout(top: keys.top)
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(paused: flashing == nil || reduceMotion)) { timeline in
                Canvas { context, size in
                    KeyboardDrawing(
                        keys: keys,
                        layout: layout,
                        current: current,
                        hovered: hovered,
                        flash: flashing.map { (key: $0.key, strength: flashStrength(at: timeline.date, since: $0.start)) },
                        palette: Palette.of(scheme),
                        colors: KeyColors.of(scheme)
                    ).draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                if let k = layout.key(at: p, in: size) { select(k) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = layout.key(at: p, in: size)
                case .ended: hovered = nil
                }
            }
        }
        .pointerStyle(.link)
        .help(hovered.map { Text(verbatim: label($0)) } ?? Text(verbatim: ""))
        .onChange(of: flash?.serial) {
            guard let flash, keys[flash.key] != nil else { return }
            let start = Date.now
            flashing = Flashing(key: flash.key, start: start)
            Task {
                try? await Task.sleep(for: .seconds(Self.flashDuration))
                if flashing?.start == start { flashing = nil }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Keyboard", tableName: "Keyboard"))
        .accessibilityValue(Text(verbatim: label(current)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(current + 1)
            case .decrement: select(current - 1)
            @unknown default: break
            }
        }
    }

    /// How strongly the flashed key is lit: from 1 down to 0, quickly at
    /// first (ease-out); a steady half with Reduce Motion.
    private func flashStrength(at date: Date, since start: Date) -> Double {
        if reduceMotion { return 0.5 }
        let t = min(1, max(0, date.timeIntervalSince(start) / Self.flashDuration))
        return (1 - t) * (1 - t)
    }

    /// The key's name and deviation, as the web's key.label.
    private func label(_ k: Int) -> String {
        let name = noteName(k)
        guard let s = keys[k], s.now.isFinite else {
            return String(localized: "\(name), not measured", table: "Keyboard")
        }
        let dev = fmtC(s.deviation, decimal: DecimalSeparator(locale))
        return String(localized: "\(name), \(dev) cents", table: "Keyboard")
    }
}

/// The drawing of the keyboard (style.css: .keyboard and .key).
private struct KeyboardDrawing {
    let keys: TunerKeys
    let layout: KeyboardLayout
    let current: Int
    let hovered: Int?
    /// The flashed key and how strongly it is lit, 0–1.
    let flash: (key: Int, strength: Double)?
    let palette: Palette
    let colors: KeyColors

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard keys.top > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let outline = UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).path(in: bounds)
        context.fill(outline, with: .color(colors.ivory.color))

        var keysContext = context
        keysContext.clip(to: outline)
        let ww = layout.whiteWidth(size)
        let labels = ww >= 14 // an 11 pt label needs a key 14 pt wide
        for k in layout.drawingOrder {
            drawKey(k, in: &keysContext, size: size, labels: labels)
        }
        context.stroke(outline, with: .color(colors.gap.color), lineWidth: 1)
    }

    private func drawKey(_ k: Int, in context: inout GraphicsContext, size: CGSize, labels: Bool) {
        let rect = layout.rect(k, in: size)
        let black = isBlack(k)
        let state = keys[k]
        let isCurrent = k == current

        if black {
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2).path(in: rect)
            let fill = isCurrent ? palette.accent : k == hovered ? colors.ebonyHover : colors.ebony
            context.fill(shape, with: .color(fill.color))
            if let flash, flash.key == k { lit(shape, flash.strength, in: &context) }
        } else {
            let fill = isCurrent ? colors.current : k == hovered ? colors.ivoryHover : colors.ivory
            context.fill(Path(rect), with: .color(fill.color))
            if isCurrent {
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(palette.accent.color), lineWidth: 2)
            }
            if let flash, flash.key == k { lit(Path(rect), flash.strength, in: &context) }
            // The gap to the next white key.
            if rect.maxX < size.width - 0.5 {
                var gap = Path()
                gap.move(to: CGPoint(x: rect.maxX - 0.5, y: 0))
                gap.addLine(to: CGPoint(x: rect.maxX - 0.5, y: size.height))
                context.stroke(gap, with: .color(colors.gap.color), lineWidth: 1)
            }
            if labels, pitchClass(k) == 0 || k == 1 {
                let text = Text(verbatim: noteName(k))
                    .font(.system(size: 11, weight: isCurrent ? .bold : .regular, design: .monospaced))
                    .foregroundStyle((isCurrent ? colors.currentInk : colors.label).color)
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.maxY - 3), anchor: .bottom)
            }
        }

        if state?.measuredB == true {
            let dot = CGRect(x: rect.midX - 2, y: 4, width: 4, height: 4)
            let color = black ? colors.ivory.color.opacity(0.6) : palette.accent.color.opacity(0.8)
            context.fill(Path(ellipseIn: dot), with: .color(color))
        }
        if state?.planned == true {
            context.stroke(
                Path(rect.insetBy(dx: 4, dy: 4)),
                with: .color(palette.accent.color),
                style: StrokeStyle(lineWidth: 2, dash: [4, 3])
            )
        }
    }

    /// Lights a flashed key with the in-tune color.
    private func lit(_ shape: Path, _ strength: Double, in context: inout GraphicsContext) {
        guard strength > 0 else { return }
        context.fill(shape, with: .color(palette.good.color.opacity(0.55 * strength)))
    }
}
