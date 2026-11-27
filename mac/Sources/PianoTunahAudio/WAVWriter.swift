import Foundation

/// Mono 32-bit float WAV files, byte for byte as web/static/js/mic.js's `wavBlob`
/// writes them: a 44-byte RIFF header (format 3, IEEE float) and the
/// samples, little-endian. Recordings are at most ``maxSeconds`` long.
///
/// Pure functions; any thread.
public enum WAVWriter {
    /// The longest recording, in s (app.js: REC_MAX_S).
    public static let maxSeconds: Double = 120
    public static let headerSize = 44

    /// The most samples a recording at this rate holds.
    public static func maxSamples(sampleRate: Double, maxSeconds: Double = maxSeconds) -> Int {
        Int((sampleRate * maxSeconds).rounded())
    }

    /// The header for `sampleCount` samples. The rate is written as a whole
    /// number of Hz, as a DataView's setUint32 does with the web's rate.
    public static func header(sampleCount: Int, sampleRate: Double) -> [UInt8] {
        let rate = UInt32(sampleRate.rounded())
        let bytes = UInt32(sampleCount * 4)
        var h: [UInt8] = []
        h.reserveCapacity(headerSize)
        func str(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        str("RIFF")
        u32(36 + bytes)
        str("WAVE")
        str("fmt ")
        u32(16)
        u16(3) // IEEE float
        u16(1) // mono
        u32(rate)
        u32(rate &* 4) // bytes per second
        u16(4) // block align
        u16(32) // bits per sample
        str("data")
        u32(bytes)
        return h
    }

    /// A WAV file of `samples`, cut to ``maxSeconds``.
    public static func wav(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Data {
        let n = min(samples.count, maxSamples(sampleRate: sampleRate))
        var data = Data(capacity: headerSize + n * 4)
        data.append(contentsOf: header(sampleCount: n, sampleRate: sampleRate))
        #if _endian(little)
        data.append(UnsafeBufferPointer(rebasing: samples[0..<n]))
        #else
        for i in 0..<n {
            withUnsafeBytes(of: samples[i].bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        #endif
        return data
    }

    /// A WAV file of `samples`, cut to ``maxSeconds``.
    public static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        samples.withUnsafeBufferPointer { wav($0, sampleRate: sampleRate) }
    }
}
