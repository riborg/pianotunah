import CoreGraphics
import PianoTunahCore
import SwiftUI

/// The Beats fold: the spectrogram of the last ≈ 9 s around the target and
/// the beat strip under it (index.html: #spectro and #beat). Both are
/// pictures; the rate beside the fold's title says it in words.
struct BeatsFold: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    let palette: Palette

    var body: some View {
        VStack(spacing: 6) {
            SpectrogramView(
                spectrogram: snapshot.folds.spectrogram,
                tolerance: snapshot.tolerance,
                palette: palette
            )
            .frame(height: 140)
            BeatStrip(
                beatHz: snapshot.folds.beatHz,
                display: snapshot.cents,
                live: BeatRate.live(snapshot, listening: listening),
                tolerance: snapshot.tolerance,
                palette: palette
            )
            .frame(height: 40)
        }
        .accessibilityHidden(true)
    }
}

/// The spectrogram (draw.js: drawSpectro): a column per frame, newest on
/// the right, ±30 cents around the target from top to bottom. A bin's
/// opacity is its level near the column's peak, its color the column's
/// deviation. The 100 × 48 picture is scaled up smoothly, with the
/// tolerance as dashed lines, the target as a line and the readings as a
/// line on top.
struct SpectrogramView: View {
    let spectrogram: Spectrogram?
    let tolerance: Double
    let palette: Palette

    /// The room for the scale on the left.
    static let scaleWidth = 30.0

    var body: some View {
        let image = spectrogram.flatMap { Self.image($0, tolerance: tolerance, palette: palette) }
        Canvas { context, size in
            draw(image, in: &context, size: size)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.sunk.color))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func draw(_ image: CGImage?, in context: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width)
        let h = Double(size.height)
        let padL = Self.scaleWidth
        let pw = w - padL
        guard pw > 0, h > 0 else { return }
        if let image {
            context.draw(
                Image(decorative: image, scale: 1).interpolation(.high),
                in: CGRect(x: padL, y: 0, width: pw, height: h)
            )
        }
        let range = Spectrogram.cents
        func y(_ c: Double) -> Double { h / 2 - max(-range, min(range, c)) / range * (h / 2) }
        func line(_ c: Double) -> Path {
            Path { p in
                p.move(to: CGPoint(x: padL, y: y(c)))
                p.addLine(to: CGPoint(x: w, y: y(c)))
            }
        }

        let dash = StrokeStyle(lineWidth: 1, dash: [2, 4])
        for c in [-tolerance, tolerance] {
            context.stroke(line(c), with: .color(palette.muted.color), style: dash)
        }
        context.stroke(line(0), with: .color(palette.ink.color.opacity(0.5)), lineWidth: 1)

        // The measured deviation as a thin line on top, broken where a
        // frame had no reading.
        if let readings = spectrogram?.readings {
            let colW = pw / Double(readings.count)
            var path = Path()
            var drawing = false
            for (i, c) in readings.enumerated() {
                guard c.isFinite else {
                    drawing = false
                    continue
                }
                let point = CGPoint(x: padL + (Double(i) + 0.5) * colW, y: y(c))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            context.stroke(path, with: .color(palette.ink.color), lineWidth: 1.5)
        }

        let n = Int(range)
        let labels: [(String, Double, UnitPoint)] = [
            ("+\(n)", 1, .topTrailing),
            ("0", h / 2, .trailing),
            ("−\(n)", h - 1, .bottomTrailing),
        ]
        for (text, ly, anchor) in labels {
            context.draw(
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted.color),
                at: CGPoint(x: padL - 4, y: ly),
                anchor: anchor
            )
        }
    }

    /// The picture: each column in its deviation's color, the opacities
    /// from the core. Premultiplied, as Core Graphics wants it.
    static func image(_ s: Spectrogram, tolerance: Double, palette: Palette) -> CGImage? {
        let n = Spectrogram.columns
        let bins = Spectrogram.bins
        guard s.alpha.count == n * bins, s.readings.count == n,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: n * bins * 4)
        for x in 0..<n {
            let c = s.readings[x]
            guard c.isFinite else { continue }
            let rgb = palette.scale(c, tolerance: tolerance)
            let r = rgb.r * 255
            let g = rgb.g * 255
            let b = rgb.b * 255
            for y in 0..<bins {
                let a = s.alpha[y * n + x]
                guard a > 0 else { continue }
                let f = Double(a) / 255
                let o = (y * n + x) * 4
                pixels[o] = UInt8((r * f).rounded())
                pixels[o + 1] = UInt8((g * f).rounded())
                pixels[o + 2] = UInt8((b * f).rounded())
                pixels[o + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n, height: bins,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// The beat strip (draw.js: drawBeat): two tones Δf Hz apart pulse Δf
/// times a second, drawn as a mirrored envelope over the last 3 s that
/// moves to the left. Beatless, or without a reading, it is flat. With
/// Reduce Motion it stands still.
///
/// The phase lives in a `BeatAnimation` object, not in observed state, so
/// the timeline's frames redraw only the canvas.
struct BeatStrip: View {
    let beatHz: Double
    let display: Double
    let live: Bool
    let tolerance: Double
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation = BeatAnimation()

    /// The strip shows this many seconds.
    static let span = 3.0

    var body: some View {
        let df = min(abs(beatHz), 40)
        let moving = live && !reduceMotion && df >= 0.1
        TimelineView(.animation(paused: !moving)) { timeline in
            Canvas { context, size in
                animation.advance(to: timeline.date, rate: moving ? df : 0)
                draw(in: &context, size: size, df: df, phase: animation.phase)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.sunk.color))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, df: Double, phase: Double) {
        let w = Double(size.width)
        let h = Double(size.height)
        guard w > 0, h > 0 else { return }
        guard live else {
            let flat = Path { p in
                p.move(to: CGPoint(x: 0, y: h / 2))
                p.addLine(to: CGPoint(x: w, y: h / 2))
            }
            context.stroke(flat, with: .color(palette.faint.color), lineWidth: 1)
            return
        }
        var edge: [CGPoint] = []
        var x = 0.0
        while x <= w {
            let env = df < 0.1 ? 1 : abs(cos(.pi * (phase - df * (w - x) * Self.span / w)))
            edge.append(CGPoint(x: x, y: h / 2 - env * (h / 2 - 3)))
            x += 2
        }
        var shape = Path()
        shape.addLines(edge)
        shape.addLines(edge.reversed().map { CGPoint(x: $0.x, y: h - $0.y) })
        shape.closeSubpath()
        let color = palette.scale(display, tolerance: tolerance).color
        context.fill(shape, with: .color(color.opacity(0.85)))
    }
}

/// The beat strip's phase, in beats, advanced by the animation's clock.
final class BeatAnimation {
    private(set) var phase = 0.0
    private var last: Date?

    /// Moves on by `rate` beats a second since the last frame (at most
    /// 0.1 s).
    func advance(to date: Date, rate: Double) {
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        phase = (phase + rate * dt).truncatingRemainder(dividingBy: 1000)
    }
}
