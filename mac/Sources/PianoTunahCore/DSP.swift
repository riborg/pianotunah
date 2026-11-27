import Foundation

// Signal processing: FFT spectrum, key detection, exact partial measurement
// and inharmonicity estimation. A port of web/static/js/dsp.js; the numbers follow
// it operation by operation (see docs/macos-port.md, step 2), so the
// fixtures from web/test/fixtures.mjs agree to within an ulp of libm.
//
// The exact frequency is found in two steps: a rough position from the FFT
// peak (parabolic interpolation), then the phase difference of a DFT at that
// frequency over two offset windows. That gives fractions of a cent even in
// the bass.
//
// Sound is Float32, as the browser's getFloatTimeDomainData gives it, and
// each sample becomes a Double where the JS reads it from its Float32Array.

/// Math.min and Math.max: NaN if either is NaN (Swift's min and max are not).
@inline(__always) private func jsMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }
@inline(__always) private func jsMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }

/// The spectrum of the latest sound and the measurements made on it.
///
/// A non-Sendable final class: it holds large preallocated buffers that
/// `load` overwrites in place, so it is used from one analysis queue (or
/// actor) only, the way the web version uses one Analyzer on the main thread.
public final class Analyzer {
    /// The strongest peak near a frequency (``peakNear(_:cents:)``).
    public struct Peak: Sendable, Equatable {
        /// Hz, from parabolic interpolation between FFT bins (JS: freq).
        public var frequency: Double
        /// The peak's level, in dB.
        public var db: Double
        /// Height above the noise floor, in dB.
        public var prom: Double
    }

    /// One reading of a partial (``measure(_:cents:minProm:)``).
    public struct Reading: Sendable, Equatable {
        /// The exact frequency, in Hz (JS: freq).
        public var frequency: Double
        /// The peak's height above the noise floor, in dB.
        public var prom: Double
    }

    /// The key heard (``detectKey(_:prevKey:top:heard:)``).
    public struct KeyDetection: Sendable, Equatable {
        /// The key, or 0 for none.
        public var key: Int
        /// How clearly the key's partials show (dB); −∞ for none.
        public var score: Double
        /// The key's lead over its semitone neighbours, in dB.
        public var margin: Double
        /// Where the key was found: 0 or the heard cents.
        public var shift: Double

        /// The same as Survey keeps it.
        public var surveyDetection: Survey.Detection { Survey.Detection(key: key, score: score, margin: margin) }
    }

    /// A string's inharmonicity fitted from its partials
    /// (``inharmonicity(f1:bGuess:)``).
    public struct InharmonicityFit: Sendable, Equatable {
        /// Inharmonicity B (JS: B).
        public var b: Double
        /// The fundamental of the fit, in Hz: partial n at n·f0·√(1 + B·n²).
        public var f0: Double
        /// How many partials were found.
        public var partials: Int
        /// The highest partial found.
        public var maxN: Int
    }

    /// Samples per second (JS: sr).
    public let sampleRate: Double
    /// FFT size, a power of two (JS: n).
    public let size: Int
    /// Hz per FFT bin (JS: df).
    public let binWidth: Double

    private let fft: FFT
    private let re: UnsafeMutablePointer<Double>
    private let im: UnsafeMutablePointer<Double>
    private let db: UnsafeMutablePointer<Double>
    private let floor: UnsafeMutablePointer<Double>
    private let prefix: UnsafeMutablePointer<Double>
    private var buf: [Float] = []
    private var windows: [Int: [Double]] = [:]

    public init(sampleRate: Double, size: Int = 16384) {
        self.sampleRate = sampleRate
        self.size = size
        binWidth = sampleRate / Double(size)
        fft = FFT(size)
        func zeros(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        re = zeros(size)
        im = zeros(size)
        db = zeros(size / 2)
        floor = zeros(size / 2)
        prefix = zeros(size / 2 + 1)
        windows[size] = hannWindow(size)
    }

    deinit {
        for p in [re, im, db, floor, prefix] { p.deallocate() }
    }

    private func hann(_ n: Int) -> [Double] {
        if let w = windows[n] { return w }
        let w = hannWindow(n)
        windows[n] = w
        return w
    }

    /// Spectrum (dB) and a moving noise floor for the latest `size` samples.
    /// The whole buffer is kept for ``refine(_:)`` and ``zoom(_:cents:bins:)``;
    /// it must hold at least `size` samples.
    public func load(_ buf: [Float]) {
        precondition(buf.count >= size, "Analyzer.load needs at least \(size) samples")
        self.buf = buf
        let n = size
        let (re, im, db, floor, prefix) = (re, im, db, floor, prefix)
        let w = hann(n)
        let off = buf.count - n
        buf.withUnsafeBufferPointer { buf in
            w.withUnsafeBufferPointer { w in
                for i in 0..<n {
                    re[i] = Double(buf[off + i]) * w[i]
                    im[i] = 0
                }
            }
        }
        fft.transform(re, im)
        let half = n / 2
        for i in 0..<half {
            db[i] = 10 * log10(re[i] * re[i] + im[i] * im[i] + 1e-20)
            prefix[i + 1] = prefix[i] + db[i]
        }
        let r = 48
        for i in 0..<half {
            let lo = Swift.max(0, i - r)
            let hi = Swift.min(half, i + r + 1)
            floor[i] = (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }

    /// Strongest peak within ±cents of f. prom = height above the noise
    /// floor (dB). A frequency or cents that is NaN gives a peak of NaNs, as
    /// in the JS.
    public func peakNear(_ f: Double, cents: Double) -> Peak? {
        let df = binWidth
        let half = size / 2
        let r = pow(2, cents / 1200)
        var lo = (f / r / df).rounded(.down)
        var hi = ((f * r) / df).rounded(.up)
        let c = jsRound(f / df)
        lo = jsMax(1, jsMin(lo, c - 2))
        hi = jsMin(Double(half - 2), jsMax(hi, c + 2))
        if lo >= hi { return nil }
        // JS indexes the spectrum with NaN here and gets undefined.
        guard !lo.isNaN, !hi.isNaN else { return Peak(frequency: .nan, db: .nan, prom: .nan) }
        let l = Int(lo)
        let h = Int(hi)
        var best = l
        if l + 1 <= h {
            for i in l + 1...h where db[i] > db[best] { best = i }
        }
        if best == l || best == h {
            // Peak at the edge: check that it really is a local maximum.
            if db[best - 1] > db[best] || db[best + 1] > db[best] { return nil }
        }
        let a = db[best - 1]
        let b = db[best]
        let g = db[best + 1]
        let den = a - 2 * b + g
        let p = den != 0 ? (0.5 * (a - g)) / den : 0
        return Peak(frequency: (Double(best) + p) * df, db: b, prom: b - floor[best])
    }

    /// Phase-based refinement of a frequency near fc.
    public func refine(_ fc: Double) -> Double {
        let m = fc < 150 ? 16384 : fc < 600 ? 8192 : 4096
        let h = m / 2
        if buf.count < m + h { return fc }
        let w = hann(m)
        let omega = (2 * Double.pi * fc) / sampleRate
        let s1 = buf.count - m - h
        let s2 = buf.count - m
        let (p1, p2) = buf.withUnsafeBufferPointer { buf in
            w.withUnsafeBufferPointer { w in
                (dftPhase(buf, s1, m, omega, w), dftPhase(buf, s2, m, omega, w))
            }
        }
        var d = p2 - p1 - omega * Double(h)
        d -= 2 * Double.pi * jsRound(d / (2 * Double.pi))
        let f = fc + (d * sampleRate) / (2 * Double.pi * Double(h))
        return abs(f - fc) < 0.6 * binWidth ? f : fc
    }

    /// Exact frequency of a partial near target, or nil if it is not heard.
    public func measure(_ target: Double, cents: Double = 60, minProm: Double = 10) -> Reading? {
        guard let pk = peakNear(target, cents: cents), !(pk.prom < minProm) else { return nil }
        return Reading(frequency: refine(pk.frequency), prom: pk.prom)
    }

    /// Zoomed spectrum: magnitude (dB) at `bins` points from +cents to −cents
    /// around fc. Used for the beat view.
    public func zoom(_ fc: Double, cents: Double, bins: Int) -> [Float] {
        // Whole buffer below 600 Hz: the main lobe is then ±10 cents at C4
        // instead of ±38, so the trace is visible within ±30 cents.
        let m = Swift.min(buf.count, fc < 600 ? 32768 : 16384)
        let w = hann(m)
        let start = buf.count - m
        var out = [Float](repeating: 0, count: bins)
        buf.withUnsafeBufferPointer { buf in
            w.withUnsafeBufferPointer { w in
                for i in 0..<bins {
                    let c = cents - (2 * cents * Double(i)) / Double(bins - 1)
                    let omega = (2 * Double.pi * fc * pow(2, c / 1200)) / sampleRate
                    out[i] = Float(dftDb(buf, start, m, omega, w))
                }
            }
        }
        return out
    }

    /// Guess which key is played by scoring each key on how clearly its
    /// expected partials show in the spectrum. Then a subharmonic check: the
    /// note an octave (or twelfth) below the winner has all the winner's
    /// partials, so it is chosen if its own partials are heard too.
    /// heard: optional cents per key (index = key) where the key was last
    /// measured; NaN or missing for none. A key is then also looked for
    /// there, so one far from its target is still found.
    public func detectKey(_ targets: Targets, prevKey: Int = 0, top: Int = keyCount, heard: [Double]? = nil) -> KeyDetection {
        var scores = [Double](repeating: -.infinity, count: keyCount + 1)
        var shifts = [Double](repeating: 0, count: keyCount + 1)
        var best = 0
        var bestScore = -Double.infinity
        // Keys above keyCount never win in the JS (their score is NaN).
        let last = Swift.min(top, keyCount)
        if last >= 1 {
            for k in 1...last {
                scores[k] = keyScore(targets, key: k, cents: 0)
                let h = heard.flatMap { $0.indices.contains(k) ? $0[k] : nil } ?? .nan
                if abs(h) >= 10 {
                    let sh = keyScore(targets, key: k, cents: h)
                    if sh > scores[k] { (scores[k], shifts[k]) = (sh, h) }
                }
                let s = scores[k] + (k == prevKey ? 2 : 0)
                if s > bestScore {
                    bestScore = s
                    best = k
                }
            }
        }
        if best == 0 { return KeyDetection(key: 0, score: -.infinity, margin: 0, shift: 0) }
        // One step at a time (octave, twelfth, two octaves and a third),
        // repeated, so two octaves down becomes two octave steps. The third
        // step is for the bass, where partial 5 can be the strongest. Own
        // partials = those not shared with the winner. The two strongest of
        // them count, since one partial can be nearly silent (strike point,
        // unisons cancelling). The thresholds are above noise peaks (~10 dB).
        func sounds(_ c: Int, _ own: [Int]) -> Bool {
            let p = own.compactMap { partialProm(targets, key: c, partial: $0) }.sorted { $0 > $1 }.prefix(2)
            guard !p.isEmpty else { return false }
            let lowest = p.dropFirst().reduce(p.first!, jsMin)
            return lowest >= 15 && p.reduce(0, +) / Double(p.count) >= 20
        }
        let steps: [(Int, [Int])] = [(12, [3, 5, 7]), (19, [2, 4, 5]), (28, [2, 3, 4])]
        var moved = true
        while moved {
            moved = false
            for (shift, own) in steps where best - shift >= 1 && sounds(best - shift, own) {
                best -= shift
                moved = true
                break
            }
        }
        // A neighbour above keyCount reads undefined in the JS: NaN.
        let neigh = [best - 2, best - 1, best + 1, best + 2]
            .filter { $0 >= 1 && $0 <= top }
            .map { $0 <= keyCount ? scores[$0] : .nan }
        let most = neigh.reduce(-Double.infinity, jsMax)
        return KeyDetection(key: best, score: scores[best], margin: scores[best] - most, shift: shifts[best])
    }

    /// Mean height of key k's first 8 partials, shifted by cents. A peak
    /// loses up to 8 dB the further it is from where the partial should be,
    /// so a key that sounds where it is expected beats a neighbour 40 cents
    /// off. −∞ if none is in the measured range.
    public func keyScore(_ targets: Targets, key k: Int, cents: Double) -> Double {
        var sum = 0.0
        var count = 0
        for n in 1...8 {
            guard let p = partialProm(targets, key: k, partial: n, cents: cents, penalty: 8) else {
                if partialFreq(targets.frequency[k], targets.inharmonicity[k], n) > 9000 { break }
                continue
            }
            sum += p
            count += 1
        }
        return count != 0 ? sum / Double(Swift.max(count, 2)) : -.infinity
    }

    /// The partial's height above the noise floor (dB, at least 0), or nil
    /// if it is outside the measured range (below 50 Hz or above 9 kHz).
    /// cents shifts the partial; penalty (dB) is subtracted at the edge of
    /// the ±45 cent window.
    public func partialProm(_ targets: Targets, key k: Int, partial n: Int, cents: Double = 0, penalty: Double = 0) -> Double? {
        let fn = partialFreq(targets.frequency[k], targets.inharmonicity[k], n) * pow(2, cents / 1200)
        if fn < 50 || fn > jsMin(9000, sampleRate * 0.45) { return nil }
        guard let pk = peakNear(fn, cents: 45) else { return 0 }
        let off = jsMin(1, abs(1200 * log2(pk.frequency / fn)) / 45)
        return jsMax(0, pk.prom - penalty * off * off)
    }

    /// Estimate B from up to 16 partials. Searches upwards and refines the
    /// model after each partial found, so the search window follows the
    /// string's real inharmonicity. Linear fit: (f_n/n)² = f0² + f0²·B·n².
    public func inharmonicity(f1: Double, bGuess: Double) -> InharmonicityFit? {
        var b = bGuess
        var f0 = f1 / (1 + b).squareRoot()
        var pts: [(n: Int, f: Double)] = []
        let nyq = sampleRate / 2
        for n in 1...16 {
            let fexp = Double(n) * f0 * (1 + b * Double(n) * Double(n)).squareRoot()
            if fexp > nyq * 0.8 { break }
            if fexp < 45 { continue }
            guard let m = measure(fexp, cents: n < 4 ? 30 : 20, minProm: 12) else { continue }
            pts.append((n, m.frequency))
            if pts.count >= 3, let fit = fitB(pts) { (b, f0) = (fit.b, fit.f0) }
        }
        if pts.count < 4 { return nil }
        // NaN passes, as in the JS.
        guard let fit = fitB(pts), !(fit.b <= 0 || fit.b > 0.05) else { return nil }
        return InharmonicityFit(b: fit.b, f0: fit.f0, partials: pts.count, maxN: pts[pts.count - 1].n)
    }
}

/// Least-squares line through (n², (f/n)²): B = slope / intercept and
/// f0 = √intercept, or nil if there is no line or the intercept is not above 0.
private func fitB(_ pts: [(n: Int, f: Double)]) -> (b: Double, f0: Double)? {
    let n = Double(pts.count)
    var sx = 0.0
    var sy = 0.0
    var sxx = 0.0
    var sxy = 0.0
    for (k, f) in pts {
        let x = Double(k * k)
        let y = pow(f / Double(k), 2)
        sx += x
        sy += y
        sxx += x * x
        sxy += x * y
    }
    let den = n * sxx - sx * sx
    if den == 0 { return nil }
    let slope = (n * sxy - sx * sy) / den
    let icept = (sy - slope * sx) / n
    if icept <= 0 { return nil }
    return (slope / icept, icept.squareRoot())
}

/// The level (dB) of the latest `len` samples: 10·log10 of their mean
/// square. NaN if the buffer is shorter, as in the JS.
public func rmsDb(_ buf: [Float], len: Int = 2048) -> Double {
    let from = buf.count - len
    if from < 0 { return .nan }
    var s = 0.0
    for i in from..<Swift.max(from, buf.count) { s += Double(buf[i]) * Double(buf[i]) }
    return 10 * log10(s / Double(len) + 1e-20)
}

// MARK: - Steady readings

/// How many readings ``steady(_:)`` looks at (JS: STEADY_N).
public let steadyN = 9
private let steadyTrim = 2
private let steadySpread = 2.0
private let steadyDrift = 1.5

/// Whether the latest ``steadyN`` readings (cents) hold still: the middle
/// ones, without the two lowest and highest, lie within 2 cents, and the
/// first and last four (medians) are within 1.5, so a string still gliding
/// after the pin moved does not count. On a real piano single readings swing
/// 1–4 cents with the strings' own beats and the slow wave after the attack;
/// see dsp.js for how the limits were chosen.
public func steady(_ cs: [Double]) -> Bool {
    if cs.count < steadyN { return false }
    let w = Array(cs.suffix(steadyN))
    let mid = Array(w.sorted { $0 < $1 }[steadyTrim..<(steadyN - steadyTrim)])
    return mid[mid.count - 1] - mid[0] < steadySpread
        && abs(median(Array(w.prefix(4))) - median(Array(w.suffix(4)))) < steadyDrift
}

/// The median; NaN for none. The values should not be NaN (JS sorts those
/// in an engine-defined order).
public func median(_ a: [Double]) -> Double {
    if a.isEmpty { return .nan }
    let s = a.sorted { $0 < $1 }
    let m = s.count >> 1
    return s.count % 2 != 0 ? s[m] : (s[m - 1] + s[m]) / 2
}

// MARK: - Beats

/// Beats as the ear hears them: the strength of the measured partial
/// pulsing. Every 0.02 s, the partial's level (dB) over the last 0.04 s,
/// kept over the note. With 1.5 s of them the decay (a parabola) is taken
/// out, and the strongest pulse between 0.3 and 12 a second is found. The
/// note beats when that pulse is at least 2 a second and 1.5 dB deep, found
/// 3 times in a row (and gone when missed as many times). See dsp.js for
/// how the limits were chosen.
///
/// A struct: its state is a few small arrays and counters, so it is Sendable
/// and a copy is an independent snapshot. Keep one per note, mutate it in
/// place, and ``reset()`` it for the next note.
public struct BeatMeter: Sendable {
    /// The strongest pulse (``pulse()``).
    public struct Pulse: Sendable, Equatable {
        /// Pulses per second, on a 0.05 grid from 0.3 (accumulated, so not
        /// exactly round).
        public var rate: Double
        /// Depth: twice the amplitude of the pulse, in dB.
        public var db: Double

        public init(rate: Double, db: Double) {
            self.rate = rate
            self.db = db
        }
    }

    static let envHop = 0.02
    static let envWin = 0.04
    static let beatSpan = 1.5
    /// s: only the latest levels, where the decay is near a parabola.
    static let beatFit = 3.0
    static let beatHits = 3
    static let beatRate = 2.0
    static let beatDb = 1.5

    /// When each level was taken, in s on the caller's clock (JS: ts).
    public private(set) var times: [Double] = []
    /// The levels, in dB (JS: ys).
    public private(set) var levels: [Double] = []
    /// Pulses found in a row, and missed in a row.
    public private(set) var hits = 0
    public private(set) var misses = 0
    /// Whether the note beats, as last confirmed.
    public private(set) var on = false

    private var window: [Double] = []

    public init() {}

    public mutating func reset() {
        times = []
        levels = []
        hits = 0
        misses = 0
        on = false
    }

    /// Seconds of levels taken since the last reset.
    public var span: Double { times.isEmpty ? 0 : times[times.count - 1] - times[0] }

    /// buf: the latest samples, ending at time t (s, any steady clock); f:
    /// the partial's frequency. Only levels not taken yet are added, and on
    /// the first call only those of the last 0.1 s.
    public mutating func add(_ buf: [Float], sampleRate sr: Double, frequency f: Double, time t: Double) {
        let m = Int(jsRound(Self.envWin * sr))
        if window.count != m { window = hannWindow(m) }
        let omega = (2 * Double.pi * f) / sr
        // A gap longer than buf can fill: the note was lost, start again.
        if let last = times.last, last < t - Double(buf.count) / sr + Self.envWin { reset() }
        let from = times.last.map { $0 + Self.envHop / 2 } ?? t - 0.1
        var g = (from / Self.envHop).rounded(.up)
        buf.withUnsafeBufferPointer { buf in
            window.withUnsafeBufferPointer { w in
                while g * Self.envHop <= t {
                    defer { g += 1 }
                    let start = Double(buf.count) - jsRound((t - g * Self.envHop) * sr) - Double(m)
                    if start < 0 { continue }
                    times.append(g * Self.envHop)
                    levels.append(dftDb(buf, Int(start), m, omega, w))
                }
            }
        }
        // Keep a little more than the fit needs, so the span stays known.
        let drop = times.prefix { $0 < t - Self.beatFit - 1 }.count
        if drop > 0 {
            times.removeFirst(drop)
            levels.removeFirst(drop)
        }
    }

    /// The strongest pulse, or nil before 1.5 s of levels.
    public func pulse() -> Pulse? {
        if span < Self.beatSpan { return nil }
        let i0 = times.firstIndex { $0 >= times[times.count - 1] - Self.beatFit }!
        let ts = times[i0...]
        let ys = Array(levels[i0...])
        let n = ts.count
        let t0 = ts.first!
        let x = ts.map { $0 - t0 }
        // Least squares parabola through the levels.
        var s = [Double](repeating: 0, count: 5)
        var y = [Double](repeating: 0, count: 3)
        for (i, t) in x.enumerated() {
            for e in 0..<5 { s[e] += pow(t, Double(e)) }
            for e in 0..<3 { y[e] += pow(t, Double(e)) * ys[i] }
        }
        var m = [[s[0], s[1], s[2], y[0]], [s[1], s[2], s[3], y[1]], [s[2], s[3], s[4], y[2]]]
        for c in 0..<3 {
            for r in 0..<3 where r != c {
                let q = m[r][c] / m[c][c]
                for j in c..<4 { m[r][j] -= q * m[c][j] }
            }
        }
        let c0 = m[0][3] / m[0][0]
        let c1 = m[1][3] / m[1][1]
        let c2 = m[2][3] / m[2][2]
        let res = ys.indices.map { i in ys[i] - c0 - c1 * x[i] - c2 * pow(x[i], 2) }
        var best = Pulse(rate: 0, db: 0)
        // Accumulated as in the JS: rate is 0.3 + 0.05 + … , not 0.3 + 0.05·i.
        var rate = 0.3
        while rate <= 12 {
            var re = 0.0
            var im = 0.0
            for i in res.indices {
                re += res[i] * cos(2 * Double.pi * rate * x[i])
                im += res[i] * sin(2 * Double.pi * rate * x[i])
            }
            let db = (2 * hypot(re, im)) / Double(n)
            if db > best.db { best = Pulse(rate: rate, db: db) }
            rate += 0.05
        }
        return best
    }

    /// true or false once 1.5 s are in, otherwise nil; also nil while a
    /// change is not yet confirmed 3 times in a row. Call once per add.
    public mutating func beats() -> Bool? {
        beats(given: pulse())
    }

    /// ``beats()`` with the pulse already taken: `pulse` must be this
    /// meter's ``pulse()`` since the last add.
    public mutating func beats(given pulse: Pulse?) -> Bool? {
        guard let p = pulse else { return nil }
        let hit = p.rate >= Self.beatRate && p.db >= Self.beatDb
        hits = hit ? hits + 1 : 0
        misses = hit ? 0 : misses + 1
        if hits >= Self.beatHits { on = true }
        if misses >= Self.beatHits { on = false }
        if on { return misses != 0 ? nil : true }
        return hits != 0 ? nil : false
    }

    /// Whether the meter heard the note without finding a beat that it
    /// could not yet confirm: then a note too short to decide may count as
    /// clean.
    public var quiet: Bool { span >= 0.5 && hits == 0 && !on }
}
