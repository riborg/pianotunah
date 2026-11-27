import Foundation

// The FFT and window of web/static/js/dsp.js. Pure Swift in Float64, not vDSP (see
// docs/adr/0003-mac-core-is-pure-swift.md): the same bit reversal, twiddle
// tables and butterfly order as the JS, so the spectra agree to the last
// bits but for an ulp or so from the platform's cos and sin.

/// An iterative radix-2 FFT of a fixed size, a power of two.
struct FFT {
    let n: Int
    private let rev: [Int]
    private let cosines: [Double]
    private let sines: [Double]

    init(_ n: Int) {
        precondition(n >= 2 && n & (n - 1) == 0, "FFT size must be a power of two")
        self.n = n
        let bits = n.trailingZeroBitCount
        var rev = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var r = 0
            for b in 0..<bits { r |= ((i >> b) & 1) << (bits - 1 - b) }
            rev[i] = r
        }
        self.rev = rev
        var c = [Double](repeating: 0, count: n / 2)
        var s = [Double](repeating: 0, count: n / 2)
        for i in 0..<n / 2 {
            c[i] = cos((2 * Double.pi * Double(i)) / Double(n))
            s[i] = -sin((2 * Double.pi * Double(i)) / Double(n))
        }
        cosines = c
        sines = s
    }

    /// Transforms re and im (n values each) in place.
    func transform(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
        rev.withUnsafeBufferPointer { rev in
            for i in 0..<n {
                let j = rev[i]
                if j > i {
                    re.swapAt(i, j)
                    im.swapAt(i, j)
                }
            }
        }
        cosines.withUnsafeBufferPointer { cosines in
            sines.withUnsafeBufferPointer { sines in
                var size = 2
                while size <= n {
                    let half = size >> 1
                    let step = n / size
                    var start = 0
                    while start < n {
                        for k in 0..<half {
                            let wr = cosines[k * step]
                            let wi = sines[k * step]
                            let a = start + k
                            let b = a + half
                            let tr = re[b] * wr - im[b] * wi
                            let ti = re[b] * wi + im[b] * wr
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                        }
                        start += size
                    }
                    size <<= 1
                }
            }
        }
    }
}

private extension UnsafeMutablePointer where Pointee == Double {
    func swapAt(_ i: Int, _ j: Int) {
        let t = self[i]
        self[i] = self[j]
        self[j] = t
    }
}

/// The symmetric Hann window of n points: 0.5 − 0.5·cos(2πi / (n − 1)).
func hannWindow(_ n: Int) -> [Double] {
    var w = [Double](repeating: 0, count: n)
    for i in 0..<n { w[i] = 0.5 - 0.5 * cos((2 * Double.pi * Double(i)) / Double(n - 1)) }
    return w
}

/// The DFT of `m` windowed samples from `start` at one frequency (radians
/// per sample), with the phasor rotated recursively as dsp.js does; a direct
/// cos/sin per sample gives slightly different numbers. Returns (re, im).
@inline(__always)
private func dft(
    _ buf: UnsafeBufferPointer<Float>, _ start: Int, _ m: Int, _ omega: Double, _ w: UnsafeBufferPointer<Double>
) -> (Double, Double) {
    var re = 0.0
    var im = 0.0
    var cr = 1.0
    var ci = 0.0
    let c = cos(omega)
    let s = -sin(omega)
    for i in 0..<m {
        let x = Double(buf[start + i]) * w[i]
        re += x * cr
        im += x * ci
        let t = cr * c - ci * s
        ci = cr * s + ci * c
        cr = t
    }
    return (re, im)
}

/// The phase (radians) of the DFT at omega (JS: dftPhase).
func dftPhase(
    _ buf: UnsafeBufferPointer<Float>, _ start: Int, _ m: Int, _ omega: Double, _ w: UnsafeBufferPointer<Double>
) -> Double {
    let (re, im) = dft(buf, start, m, omega, w)
    return atan2(im, re)
}

/// The power (dB) of the DFT at omega (JS: dftDb).
func dftDb(
    _ buf: UnsafeBufferPointer<Float>, _ start: Int, _ m: Int, _ omega: Double, _ w: UnsafeBufferPointer<Double>
) -> Double {
    let (re, im) = dft(buf, start, m, omega, w)
    return 10 * log10(re * re + im * im + 1e-20)
}
