import PianoTunahCore
import SwiftUI

/// The dial (draw.js: drawDial): a half circle with the needle over a ±50
/// cent scale, compressed so the centre gets the most room, and the strobe
/// rings behind it, with the note hub and the ‹ › key buttons on top.
///
/// Rings as on a mechanical strobe: one per band, innermost first; still is
/// in tune, clockwise is too high, and a ring an octave up turns twice as
/// fast. Each ring is a whole circle clipped to the upper half, so it never
/// runs empty. A ring without a reading is grey and still.
///
/// The rings' angles live in a `StrobeAnimation` object, not in observed
/// state, so the 60–120 frames a second of the timeline redraw only the
/// canvas.
struct DialView: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    let step: (Int) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation = StrobeAnimation()

    /// The dial's height per width, as the web's .dial.
    static let aspect = 0.7

    var body: some View {
        let palette = Palette.of(scheme)
        let live = snapshot.signal && snapshot.cents.isFinite
        let spinning = listening && live && !reduceMotion
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: !spinning)) { timeline in
                    Canvas { context, size in
                        animation.advance(
                            to: timeline.date,
                            bands: spinning ? snapshot.strobe : []
                        )
                        DialDrawing(
                            width: size.width,
                            display: snapshot.cents,
                            signal: snapshot.signal,
                            bands: snapshot.strobe,
                            live: live,
                            tolerance: snapshot.tolerance,
                            phases: animation.phases,
                            palette: palette
                        ).draw(in: &context)
                    }
                }
                DialHub(snapshot: snapshot, listening: listening, width: w, palette: palette)
                    .position(x: w / 2, y: w * DialDrawing.cy)
                navButton("chevron.left", delta: -1, enabled: snapshot.key > 1, width: w)
                    .help("Previous key (←)")
                    .accessibilityLabel(Text("Previous key"))
                    .position(x: w * 0.19, y: w * 0.63)
                navButton("chevron.right", delta: 1, enabled: snapshot.key < snapshot.top, width: w)
                    .help("Next key (→)")
                    .accessibilityLabel(Text("Next key"))
                    .position(x: w * 0.81, y: w * 0.63)
            }
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
    }

    private func navButton(_ symbol: String, delta: Int, enabled: Bool, width: Double) -> some View {
        Button {
            step(delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(NavButtonStyle(palette: Palette.of(scheme)))
        .disabled(!enabled)
    }
}

/// A round button with a thin border, as the web's .nav.
private struct NavButtonStyle: ButtonStyle {
    let palette: Palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(palette.ink.color)
            .background(Circle().fill(configuration.isPressed ? palette.sunk.color : palette.surface.color))
            .overlay(Circle().strokeBorder(palette.line.color, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The strobe rings' angles, advanced by the animation's clock.
final class StrobeAnimation {
    private(set) var phases = [0.0, 0.0, 0.0]
    private var last: Date?

    /// Turns each ring by clamp(c, ±30) · 0.045 · 2^i rad/s since the last
    /// frame (at most 0.1 s); rings without a band or a reading stay.
    func advance(to date: Date, bands: [Engine.StrobeBand]) {
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        guard dt > 0 else { return }
        for i in phases.indices where i < bands.count && bands[i].cents.isFinite {
            let c = max(-30, min(30, bands[i].cents))
            phases[i] = (phases[i] + c * 0.045 * pow(2, Double(i)) * dt)
                .truncatingRemainder(dividingBy: 2 * .pi)
        }
    }
}

/// The drawing of the dial, proportional to its width as in draw.js.
struct DialDrawing {
    /// The centre's height, the hub's radius, the scale's radius and the
    /// rings' radii, all per width; the scale's half angle.
    static let cy = 0.54
    static let hub = 0.15
    static let radius = 0.41
    static let rings: [(Double, Double)] = [(0.185, 0.25), (0.26, 0.325), (0.335, 0.39)]
    static let segments = [10, 14, 18]
    static let maxAngle = 80 * Double.pi / 180

    let width: Double
    let display: Double
    let signal: Bool
    let bands: [Engine.StrobeBand]
    let live: Bool
    let tolerance: Double
    let phases: [Double]
    let palette: Palette

    private var center: CGPoint { CGPoint(x: width / 2, y: width * Self.cy) }

    /// The angle from straight up for c cents: √-compressed, ±50 at ±80°.
    private func ang(_ c: Double) -> Double {
        let sign: Double = c > 0 ? 1 : c < 0 ? -1 : 0
        return sign * (min(abs(c), 50) / 50).squareRoot() * Self.maxAngle
    }

    /// The canvas angle (0 is to the right, clockwise) for an angle from up.
    private func ca(_ a: Double) -> Double { -Double.pi / 2 + a }

    /// The point at angle a from up and radius r.
    private func at(_ a: Double, _ r: Double) -> CGPoint {
        CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
    }

    /// A ring sector between radii r0 < r1 from canvas angle a0 to a1.
    private func sector(_ r0: Double, _ r1: Double, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addRelativeArc(center: center, radius: r1, startAngle: .radians(a0), delta: .radians(a1 - a0))
        p.addRelativeArc(center: center, radius: r0, startAngle: .radians(a1), delta: .radians(a0 - a1))
        p.closeSubpath()
        return p
    }

    private func circle(_ r: Double) -> CGRect {
        CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }

    private func signed(_ v: Int) -> String {
        v == 0 ? "0" : (v > 0 ? "+" : "−") + String(abs(v))
    }

    func draw(in context: inout GraphicsContext) {
        let w = width
        guard w > 0 else { return }
        let R = w * Self.radius
        let mono = { (size: Double, weight: Font.Weight) in Font.system(size: size, weight: weight, design: .monospaced) }

        // Strobe rings, clipped to the upper half.
        var rings = context
        rings.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: center.y)))
        for (i, (f0, f1)) in Self.rings.enumerated() {
            let r0 = w * f0
            let r1 = w * f1
            let band = i < bands.count ? bands[i] : nil
            let on = live && (band?.cents.isFinite ?? false)
            var annulus = Path()
            annulus.addEllipse(in: circle(r1))
            annulus.addEllipse(in: circle(r0))
            rings.fill(annulus, with: .color(palette.stripe2.color), style: FillStyle(eoFill: true))
            let n = Self.segments[i]
            let step = Double.pi / Double(n)
            let phase = i < phases.count ? phases[i] : 0
            var stripes = Path()
            for j in 0..<(2 * n) {
                let s = phase + Double(j) * step
                stripes.addPath(sector(r0, r1, s, s + step / 2))
            }
            let color = on ? palette.scale(band!.cents, tolerance: tolerance) : palette.faint
            rings.fill(stripes, with: .color(color.color))
        }

        // The partial at the right end of each ring.
        for (i, (f0, f1)) in Self.rings.enumerated() where i < bands.count {
            let p = at(84 * Double.pi / 180, w * (f0 + f1) / 2)
            let r = max(9, w * 0.018)
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - 2 - r, width: 2 * r, height: 2 * r)),
                with: .color(palette.surface.color)
            )
            context.draw(
                Text(verbatim: String(bands[i].partial))
                    .font(mono(max(11, w * 0.022), .semibold))
                    .foregroundStyle(palette.muted.color),
                at: CGPoint(x: p.x, y: p.y - 1.5)
            )
        }

        // Tolerance and scale.
        var band = context
        band.opacity = 0.22
        band.fill(
            sector(R, R + w * 0.04, ca(ang(-tolerance)), ca(ang(tolerance))),
            with: .color(palette.good.color)
        )
        var arc = Path()
        arc.addRelativeArc(center: center, radius: R, startAngle: .radians(ca(-Self.maxAngle)), delta: .radians(2 * Self.maxAngle))
        context.stroke(arc, with: .color(palette.muted.color), lineWidth: 1)

        func tick(_ t: Double, _ len: Double, _ color: RGB, _ lineWidth: Double = 1) {
            var p = Path()
            p.move(to: at(ang(t), R))
            p.addLine(to: at(ang(t), R + len))
            context.stroke(p, with: .color(color.color), lineWidth: lineWidth)
        }
        for t in [3.0, 4, 6, 7, 8, 9, 15, 25, 30, 35, 40, 45] {
            tick(t, w * 0.014, palette.faint)
            tick(-t, w * 0.014, palette.faint)
        }
        let labelFont = mono(max(11, min(12, w * 0.022)), .regular)
        for t in [-50, -20, -10, -5, -2, -1, 0, 1, 2, 5, 10, 20, 50] {
            if t == 0 {
                tick(0, w * 0.045, palette.ink, 2)
            } else {
                tick(Double(t), w * 0.026, palette.muted)
            }
            if abs(t) == 1 && w <= 450 { continue }
            let text = context.resolve(Text(verbatim: signed(t)).font(labelFont).foregroundStyle(palette.muted.color))
            let size = text.measure(in: CGSize(width: w, height: w))
            var p = at(ang(Double(t)), R + w * 0.065)
            p.x = max(size.width / 2, min(w - size.width / 2, p.x))
            if abs(t) == 50 {
                // Kept inside the dial, below its tick: beside it a small dial has no room.
                p.y = at(ang(Double(t)), R).y + max(3, w * 0.01)
                context.draw(text, at: p, anchor: .top)
            } else {
                context.draw(text, at: p, anchor: .center)
            }
        }

        // Needle, with a halo in the surface color so it reads over the rings.
        guard display.isFinite else { return }
        let a = ang(display)
        var needle = Path()
        needle.move(to: at(a, w * Self.hub + 4))
        needle.addLine(to: at(a, R + w * 0.03))
        var hand = context
        hand.opacity = signal ? 1 : 0.35
        let round = { (width: Double) in StrokeStyle(lineWidth: width, lineCap: .round) }
        hand.stroke(needle, with: .color(palette.surface.color), style: round(max(6, w * 0.013)))
        hand.stroke(needle, with: .color(palette.scale(display, tolerance: tolerance).color), style: round(max(3, w * 0.006)))
    }
}

/// The hub in the middle of the dial: the deviation and the note name.
struct DialHub: View {
    let snapshot: TunerSnapshot
    let listening: Bool
    let width: Double
    let palette: Palette
    @Environment(\.locale) private var locale

    var body: some View {
        let decimal = DecimalSeparator(locale)
        let status: PitchStatus? = listening && snapshot.signal ? snapshot.status : nil
        let centsText = listening ? fmtC(snapshot.cents, decimal: decimal) : "–"
        let centsSize = min(26, max(15, width * 0.054))
        let d = width * 0.30
        VStack(spacing: width * 0.006) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: centsText)
                    .font(.system(size: centsSize, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(snapshot.signal ? palette.status(status).color : palette.muted.color)
                Text("cents")
                    .font(.system(size: min(12, max(11, width * 0.022)), weight: .medium))
                    .foregroundStyle(palette.muted.color)
            }
            NoteName(key: snapshot.key, size: min(54, max(30, width * 0.11)))
                .foregroundStyle(palette.ink.color)
        }
        .frame(width: d, height: d)
        .background(Circle().fill(palette.sunk.color))
        .overlay(Circle().strokeBorder(status == .good ? palette.good.color : palette.line.color, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// A note name as in chord symbols: the accidental raised and the octave
/// lowered, B♭₄.
struct NoteName: View {
    let key: Int
    let size: Double

    var body: some View {
        let name = noteName(key)
        let letter = String(name.prefix(1))
        let octave = String(name.drop(while: { !$0.isNumber }))
        let accidental = String(name.dropFirst().prefix(while: { !$0.isNumber }))
        let small = Font.system(size: size * 0.6, weight: .semibold, design: .serif)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.02) {
            Text(verbatim: letter)
                .font(.system(size: size, weight: .semibold, design: .serif))
            if !accidental.isEmpty {
                Text(noteText(accidental, size: size * 0.6))
                    .font(small)
                    .baselineOffset(size * 0.3)
            }
            Text(verbatim: octave)
                .font(small)
                .baselineOffset(-size * 0.11)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
    }
}
