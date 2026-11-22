// Number formatting with the language's decimal separator: a port of
// web/js/format.js.
//
// The digits come from JavaScript's own algorithms (`toFixed`,
// `toExponential`, `String(number)`), done here on the exact value of the
// double, rather than from NumberFormatter, String(format:) or Locale. Those
// round differently (printf takes the 0.25 tie to "0.2", JS to "0.3") and can
// differ between Foundation on Linux and on macOS.

/// The character between the whole and the fractional part of a number:
/// "." in English, "," in Swedish.
public enum DecimalSeparator: Character, Sendable, CaseIterable {
    case point = "."
    case comma = ","
}

// MARK: - format.js

/// `x` without its sign, with `d` decimals, rounded like JS `toFixed`.
/// `num(-1.25, 1, decimal: .comma)` is "1,3".
public func num(_ x: Double, _ d: Int = 1, decimal: DecimalSeparator) -> String {
    dec(jsToFixed(Swift.abs(x), d), decimal)
}

/// The shortest form, like JS `String(x)`: 0.5 → "0.5", 1 → "1", 1e-7 → "1e-7".
public func short(_ x: Double, decimal: DecimalSeparator) -> String {
    dec(jsString(x), decimal)
}

/// Cents with sign: "+1.2", "−0.4" (U+2212) or "±0.0". The sign follows the
/// rounded value, so 0.3 without decimals is "±0", not "+0". A value that is
/// not finite becomes "–" (U+2013).
public func fmtC(_ c: Double, _ d: Int = 1, decimal: DecimalSeparator) -> String {
    guard c.isFinite else { return "–" }
    // Number(Math.abs(c).toFixed(d)) === 0: the fixed digits are all zeros.
    let zero = jsToFixed(Swift.abs(c), d).allSatisfy { $0 == "0" || $0 == "." }
    let sign = zero ? "±" : c > 0 ? "+" : "−"
    return sign + num(c, d, decimal: decimal)
}

/// A frequency with `d` decimals and the unit: "440.00 Hz". Negative values
/// keep a hyphen-minus, as `toFixed` gives it.
public func fmtHz(_ f: Double, _ d: Int = 2, decimal: DecimalSeparator) -> String {
    dec(jsToFixed(f, d), decimal) + " Hz"
}

/// An inharmonicity coefficient with three significant digits, like JS
/// `toExponential(2)`: 0.0001234 → "1.23e-4", 1 → "1.00e+0".
public func fmtB(_ b: Double, decimal: DecimalSeparator) -> String {
    dec(jsToExponential(b, 2), decimal)
}

/// A typed decimal number with comma or point, such as " 441,5 " or "-.5".
/// Anything else is NaN: exponents, a plus sign, thousands separators and
/// digits other than ASCII 0–9.
///
/// Matches `/^\s*-?(\d+([.,]\d*)?|[.,]\d+)\s*$/` with JS's meaning of `\s`
/// and `\d`, working on Unicode scalars so "\r\n" is two characters as in JS.
public func parseNum(_ s: String) -> Double {
    let u = Array(s.unicodeScalars)
    var lo = 0
    var hi = u.count
    while lo < hi, isJSWhiteSpace(u[lo]) { lo += 1 }
    while hi > lo, isJSWhiteSpace(u[hi - 1]) { hi -= 1 }
    var i = lo
    var text = ""
    if i < hi, u[i] == "-" {
        text.append("-")
        i += 1
    }
    var whole = ""
    while i < hi, isASCIIDigit(u[i]) {
        whole.unicodeScalars.append(u[i])
        i += 1
    }
    var frac = ""
    if i < hi, u[i] == "." || u[i] == "," {
        i += 1
        while i < hi, isASCIIDigit(u[i]) {
            frac.unicodeScalars.append(u[i])
            i += 1
        }
    }
    // Something left over, or no digits at all ("", "-", ".").
    guard i == hi, !whole.isEmpty || !frac.isEmpty else { return .nan }
    text += (whole.isEmpty ? "0" : whole) + "." + (frac.isEmpty ? "0" : frac)
    // ASCII "-?d+.d+" only, which Double(_:) parses with correct rounding
    // and no locale.
    return Double(text) ?? .nan
}

private func dec(_ s: String, _ decimal: DecimalSeparator) -> String {
    guard decimal != .point, let i = s.firstIndex(of: ".") else { return s }
    var out = s
    out.replaceSubrange(i...i, with: String(decimal.rawValue))
    return out
}

private func isASCIIDigit(_ c: Unicode.Scalar) -> Bool {
    c.value >= 0x30 && c.value <= 0x39
}

/// JS WhiteSpace and LineTerminator, which `\s` matches and `Number()` trims.
private func isJSWhiteSpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

// MARK: - JavaScript number to string

/// JS `x.toFixed(digits)` for `digits` in 0...100: the integer n nearest to
/// x·10^digits, the larger one on an exact tie, written with `digits`
/// decimals. Negative values, −0.004 to two places included, get a leading
/// "-"; −0 does not. |x| ≥ 1e21 gives `jsString(x)`, as in JS.
public func jsToFixed(_ x: Double, _ digits: Int) -> String {
    precondition((0...100).contains(digits), "toFixed takes 0 to 100 digits")
    guard x.isFinite else { return jsString(x) }
    guard Swift.abs(x) < 1e21 else { return jsString(x) }
    let sign = x < 0 ? "-" : ""
    let exact = ExactDecimal(Swift.abs(x))
    var n: [UInt8]
    if exact.scale <= digits {
        n = exact.digits + Array(repeating: 0, count: digits - exact.scale)
    } else {
        let drop = exact.scale - digits
        let keep = exact.digits.count - drop
        if keep < 0 {
            n = [0]
        } else {
            n = keep == 0 ? [0] : Array(exact.digits[..<keep])
            if exact.digits[keep] >= 5 { roundUp(&n) }
        }
    }
    if digits > 0, n.count <= digits {
        n = Array(repeating: 0, count: digits + 1 - n.count) + n
    }
    var out = sign
    for (i, d) in n.enumerated() {
        if digits > 0, i == n.count - digits { out += "." }
        out.unicodeScalars.append(digitScalar(d))
    }
    return out
}

/// JS `x.toExponential(fractionDigits)` for `fractionDigits` in 0...100:
/// `fractionDigits + 1` significant digits, the larger on an exact tie, and
/// an exponent without leading zeros: 0.0001234 → "1.23e-4".
public func jsToExponential(_ x: Double, _ fractionDigits: Int) -> String {
    precondition((0...100).contains(fractionDigits), "toExponential takes 0 to 100 digits")
    guard x.isFinite else { return jsString(x) }
    let f = fractionDigits
    let sign = x < 0 ? "-" : ""
    var n: [UInt8]
    var e: Int
    if x == 0 {
        n = Array(repeating: 0, count: f + 1)
        e = 0
    } else {
        let exact = ExactDecimal(Swift.abs(x))
        let all = exact.digits
        e = all.count - 1 - exact.scale
        if all.count <= f + 1 {
            n = all + Array(repeating: 0, count: f + 1 - all.count)
        } else {
            n = Array(all[..<(f + 1)])
            if all[f + 1] >= 5 {
                roundUp(&n)
                if n.count > f + 1 {
                    // 9.995 → 10.00: one digit more, so drop a zero.
                    n.removeLast()
                    e += 1
                }
            }
        }
    }
    var out = sign
    out.unicodeScalars.append(digitScalar(n[0]))
    if f > 0 {
        out += "."
        for d in n[1...] { out.unicodeScalars.append(digitScalar(d)) }
    }
    out += e < 0 ? "e-" : "e+"
    out += String(Swift.abs(e))
    return out
}

/// JS `String(x)`: the shortest digits that read back as `x`, without
/// exponent from 1e-6 up to 1e21 and with one ("1e-7", "1.5e+21") outside.
/// NaN is "NaN", −0 is "0".
///
/// The digits come from Swift's `description`, which like V8 gives the
/// shortest decimal that round-trips, the one closest to the exact value
/// when several do. Only its layout differs ("1.0", "1e-07"), and that is
/// rebuilt here by the rules of Number::toString.
public func jsString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x == 0 { return "0" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    if x < 0 { return "-" + jsString(-x) }

    // description is "123.45", "0.001", "1e-07" or "1.2345e+16".
    let desc = x.description
    let parts = desc.split(separator: "e", maxSplits: 1)
    let exp10 = parts.count == 2 ? Int(parts[1])! : 0
    let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let intPart = mantissa[0]
    let fracPart = mantissa.count == 2 ? mantissa[1] : ""
    var ds = Array((intPart + fracPart).utf8).map { $0 - 0x30 }
    // The value is 0.d₁d₂…dₖ × 10ⁿ.
    var n = intPart.count + exp10
    while ds.first == 0 {
        ds.removeFirst()
        n -= 1
    }
    while ds.last == 0 { ds.removeLast() }
    let k = ds.count
    let digits = ds.map { String(digitScalar($0)) }.joined()

    if k <= n, n <= 21 {
        return digits + String(repeating: "0", count: n - k)
    }
    if 0 < n, n <= 21 {
        let i = digits.index(digits.startIndex, offsetBy: n)
        return String(digits[..<i]) + "." + String(digits[i...])
    }
    if -6 < n, n <= 0 {
        return "0." + String(repeating: "0", count: -n) + digits
    }
    let e = n - 1
    let expText = (e < 0 ? "e-" : "e+") + String(Swift.abs(e))
    if k == 1 { return digits + expText }
    return String(digits.first!) + "." + digits.dropFirst() + expText
}

private func digitScalar(_ d: UInt8) -> Unicode.Scalar {
    Unicode.Scalar(0x30 + d)
}

/// Adds one to the decimal integer `n` (most significant digit first),
/// growing it by a digit when it is all nines.
private func roundUp(_ n: inout [UInt8]) {
    var i = n.count - 1
    while i >= 0 {
        if n[i] < 9 {
            n[i] += 1
            return
        }
        n[i] = 0
        i -= 1
    }
    n.insert(1, at: 0)
}

/// The exact value of a finite double ≥ 0 as a decimal: `digits` (most
/// significant first, no leading zeros, [0] for zero) with `scale` of them
/// after the point. Every double is m·2^e, which is m·5^(−e) / 10^(−e) when e < 0,
/// so its decimal expansion is finite; 0.1 has 55 digits after the point.
private struct ExactDecimal {
    var digits: [UInt8]
    var scale: Int

    init(_ x: Double) {
        precondition(x.isFinite && x >= 0)
        if x == 0 {
            digits = [0]
            scale = 0
            return
        }
        var m = x.significandBitPattern
        var e = Int(x.exponentBitPattern)
        if e == 0 {
            e = 1 // subnormal
        } else {
            m |= 1 << UInt64(Double.significandBitCount)
        }
        let bias = (1 << (Double.exponentBitCount - 1)) - 1 // 1023
        e -= bias + Double.significandBitCount
        // Fewer multiplications for values with trailing zero bits.
        let tz = m.trailingZeroBitCount
        m >>= UInt64(tz)
        e += tz

        var big = BigDecimalInt(m)
        if e >= 0 {
            big.multiply(byPowerOf: 2, e)
            scale = 0
        } else {
            big.multiply(byPowerOf: 5, -e)
            scale = -e
        }
        digits = big.decimalDigits()
    }
}

/// A non-negative integer in base 10⁹ limbs, least significant first. Just
/// enough arithmetic for `ExactDecimal`.
private struct BigDecimalInt {
    static let base: UInt64 = 1_000_000_000
    var limbs: [UInt64]

    init(_ v: UInt64) {
        limbs = []
        var v = v
        repeat {
            limbs.append(v % Self.base)
            v /= Self.base
        } while v > 0
    }

    /// Multiplies by `p`^`count`, `p` being 2 or 5, a few factors at a time
    /// while the product stays below 2³².
    mutating func multiply(byPowerOf p: UInt64, _ count: Int) {
        let chunk = p == 2 ? 31 : 13
        var left = count
        while left > 0 {
            let c = Swift.min(left, chunk)
            var f: UInt64 = 1
            for _ in 0..<c { f *= p }
            multiply(by: f)
            left -= c
        }
    }

    private mutating func multiply(by f: UInt64) {
        var carry: UInt64 = 0
        for i in limbs.indices {
            let v = limbs[i] * f + carry
            limbs[i] = v % Self.base
            carry = v / Self.base
        }
        while carry > 0 {
            limbs.append(carry % Self.base)
            carry /= Self.base
        }
    }

    func decimalDigits() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 9)
        for (i, limb) in limbs.enumerated().reversed() {
            var chunk = [UInt8](repeating: 0, count: 9)
            var v = limb
            for j in stride(from: 8, through: 0, by: -1) {
                chunk[j] = UInt8(v % 10)
                v /= 10
            }
            if i == limbs.count - 1 {
                out += chunk.drop { $0 == 0 }
            } else {
                out += chunk
            }
        }
        return out.isEmpty ? [0] : out
    }
}
