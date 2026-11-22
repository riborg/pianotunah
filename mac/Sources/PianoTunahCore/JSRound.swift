/// Rounds like JavaScript's `Math.round`: to the nearest integer, halves
/// towards +∞ (2.5 → 3, −2.5 → −2), and −0 for −0.5 up to −0.
///
/// Swift's `rounded()` takes halves away from zero, and `floor(x + 0.5)`
/// gives 1 for 0.49999999999999994, where the addition rounds up.
public func jsRound(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    let down = x.rounded(.down)
    let r = x - down >= 0.5 ? down + 1 : down
    return r == 0 && x.sign == .minus ? -0.0 : r
}
