import Foundation
import PianoTunahCore

/// What the folds under the dial show (index.html: the Beats and Partials
/// folds), made on the analysis queue with the rest of the snapshot.
struct FoldsSnapshot: Sendable {
    /// The beat rate against the goal, Hz; NaN without a reading (JS:
    /// engine.beatHz). Shown beside the Beats fold even while it is closed.
    var beatHz = Double.nan
    /// Partials 1–8 of the sounding key against their targets; empty while
    /// no note of the key is heard.
    var partials: [PartialReading] = []
    /// The manual B measurement runs.
    var measuringB = false
    /// The spectrogram; nil while the Beats fold is closed, so a closed
    /// fold costs nothing.
    var spectrogram: Spectrogram?
}

/// One partial of the sounding key (JS: engine.partialDevs[i]).
struct PartialReading: Sendable {
    /// Cents from the partial's target; NaN where it is not heard.
    var cents: Double
    var status: PitchStatus
}

/// The spectrogram as the view draws it (draw.js: drawSpectro): one column
/// per frame, newest on the right, and in each the zoomed spectrum around
/// the target as opacities. The color of a column is its reading's
/// deviation, which the view adds with the palette.
struct Spectrogram: Sendable {
    static let columns = Engine.spectrogramColumns
    static let bins = Engine.spectrogramBins
    static let cents = Engine.spectrogramCents
    /// A bin is shown when within this many dB of its column's peak (JS:
    /// SPEC_RANGE_DB).
    static let rangeDb = 12.0

    /// Opacity 0–255 per pixel, row by row (`bins` rows of `columns`), the
    /// top row +30 cents.
    var alpha: [UInt8]
    /// The reading of each column in cents; NaN for a frame without one.
    var readings: [Double]

    /// The engine's columns, oldest first; fewer than `columns` are padded
    /// on the left with empty ones. Opacity: (dB within `rangeDb` of the
    /// column's peak)^1.5, as the web.
    init(_ history: [Engine.SpectrogramColumn?]) {
        let n = Self.columns
        let bins = Self.bins
        var alpha = [UInt8](repeating: 0, count: n * bins)
        var readings = [Double](repeating: .nan, count: n)
        let shown = history.suffix(n)
        let offset = n - shown.count
        for (i, column) in shown.enumerated() {
            guard let column else { continue }
            let x = offset + i
            readings[x] = column.cents
            guard let peak = column.magnitudes.max() else { continue }
            for y in 0..<min(bins, column.magnitudes.count) {
                let v = (Double(column.magnitudes[y]) - Double(peak) + Self.rangeDb) / Self.rangeDb
                let a = v.isNaN ? 0 : max(0, min(1, v))
                alpha[y * n + x] = UInt8((pow(a, 1.5) * 255).rounded())
            }
        }
        self.alpha = alpha
        self.readings = readings
    }
}

/// The folds' part of the core, on the analysis queue with it.
final class FoldsCore {
    /// The Beats fold is open, so the spectrogram is copied every frame.
    var beatsOpen = false

    /// What the folds show of the engine now. On the analysis queue.
    func snapshot(_ engine: Engine) -> FoldsSnapshot {
        var s = FoldsSnapshot()
        s.beatHz = engine.beatHz
        s.measuringB = engine.measureB != nil
        // The web shows the deviations only while the key is heard.
        if engine.signal {
            let devs = engine.partialDeviations
            s.partials = (0..<8).map { i in
                let d = i < devs.count ? devs[i] ?? .nan : .nan
                return PartialReading(cents: d, status: engine.statusClass(d))
            }
        }
        if beatsOpen { s.spectrogram = Spectrogram(engine.spectrogram) }
        return s
    }
}

extension TunerModel {
    /// Tells the core whether the Beats fold is open: only then does it copy
    /// the spectrogram into the snapshot.
    func setBeatsFoldOpen(_ open: Bool) {
        send { core in
            guard core.folds.beatsOpen != open else { return }
            core.folds.beatsOpen = open
            // A snapshot now, so the history shows also without a frame.
            core.perform { _ in }
        }
    }

    /// The measured partial of the current key one step up or down (1–8);
    /// saved with the piano.
    func stepPartial(_ delta: Int) {
        send { $0.performSaving { $0.setPartial(delta) } }
    }

    /// Measures B of the current key from the next 4 s of readings. The
    /// engine ends it with the first frame after that; if the note dies
    /// away first no frame comes, so it is ended after 6 s (as app.js).
    func measureInharmonicity() {
        guard isListening else {
            showNotice(String(localized: "Start the microphone first.", table: "Folds"))
            return
        }
        guard let key = snapshot?.key else { return }
        let now = ProcessInfo.processInfo.systemUptime * 1000
        send { $0.perform { _ = $0.startMeasureB(now: now) } }
        showNotice(String(localized: "Strike \(noteName(key)) firmly and let it ring …", table: "Folds"), seconds: 4)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            // The run started here ends 4 s after `now`; a later press
            // starts another, which this leaves alone.
            self?.send { core in
                core.perform { engine in
                    if engine.measureB?.until == now + 4000 { engine.finishMeasureB() }
                }
            }
        }
    }

    /// The text of a message about a B measurement; nil for the others.
    static func inharmonicityText(_ message: Engine.Message, decimal: DecimalSeparator) -> String? {
        switch message {
        case .bMeasured(let key, let b):
            String(localized: "Inharmonicity for \(noteName(key)): B = \(fmtB(b, decimal: decimal))", table: "Folds")
        case .bOutlier(let key, let b):
            String(localized: "Inharmonicity for \(noteName(key)): B = \(fmtB(b, decimal: decimal)), far from the neighbouring keys, so it is not used. Measure again.", table: "Folds")
        case .bFailed:
            String(localized: "Could not measure inharmonicity. Strike the key firmly and let it ring for a couple of seconds.", table: "Folds")
        default:
            nil
        }
    }
}
