import PianoTunahCore
import SwiftUI

/// A color as three sRGB components, so the deviation scale can blend them.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// From self (t = 0) to `other` (t = 1).
    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}

/// The web version's colors (web/static/style.css): steel-blue accent, ebony and
/// ivory, and green, yellow and red kept for the status. One palette for the
/// light appearance and one for the dark, chosen by the color scheme.
struct Palette {
    var bg: RGB
    var surface: RGB
    var sunk: RGB
    var ink: RGB
    var muted: RGB
    var faint: RGB
    var line: RGB
    var accent: RGB
    var good: RGB
    var warn: RGB
    var bad: RGB
    var stripe2: RGB
    var scaleYellow: RGB
    var scaleOrange: RGB

    static let light = Palette(
        bg: RGB(0xECEEED), surface: RGB(0xFBFCFB), sunk: RGB(0xE3E7E5), ink: RGB(0x171B1C),
        muted: RGB(0x5A6463), faint: RGB(0xB9C1BF), line: RGB(0xD4DAD8), accent: RGB(0x2C5A85),
        good: RGB(0x1A7A4C), warn: RGB(0x985E0C), bad: RGB(0xC03C34), stripe2: RGB(0xDFE5E3),
        scaleYellow: RGB(0xC9A400), scaleOrange: RGB(0xDF7A16)
    )

    static let dark = Palette(
        bg: RGB(0x0E1213), surface: RGB(0x161C1D), sunk: RGB(0x0B0F10), ink: RGB(0xE7EBE9),
        muted: RGB(0x93A09D), faint: RGB(0x3A4547), line: RGB(0x283133), accent: RGB(0x86B2DC),
        good: RGB(0x3FC189), warn: RGB(0xE6A53C), bad: RGB(0xF0675D), stripe2: RGB(0x0B0F10),
        scaleYellow: RGB(0xF2D04A), scaleOrange: RGB(0xF39A3D)
    )

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    /// The color of a deviation: green within tolerance, then blending
    /// through yellow and orange to red (draw.js: scaleRgb).
    func scale(_ cents: Double, tolerance tol: Double) -> RGB {
        let colors = [good, scaleYellow, scaleOrange, bad]
        let stops = [tol, max(3, tol * 2.5), max(6, tol * 5), max(12, tol * 10)]
        let a = abs(cents)
        if a <= stops[0] { return colors[0] }
        for i in 1..<stops.count where a <= stops[i] {
            let t = (a - stops[i - 1]) / (stops[i] - stops[i - 1])
            return colors[i - 1].mix(colors[i], t)
        }
        return colors[3]
    }

    /// The text color for a status: green, yellow-brown, red, or muted.
    func status(_ s: PitchStatus?) -> RGB {
        switch s {
        case .good: good
        case .warn: warn
        case .bad: bad
        case .noReading, nil: muted
        }
    }
}
