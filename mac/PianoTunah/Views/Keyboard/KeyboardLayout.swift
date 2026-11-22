import CoreGraphics
import PianoTunahCore

/// Where the keys lie, as in the web's buildKeyboard: equal white keys side
/// by side, and each black key centred on the gap between two whites. The
/// keyboard and the curve above it share it, so the curve's points sit over
/// their keys.
///
/// Positions are fractions of the keyboard's width; both views are inset
/// `inset` points on either side (draw.js: drawChart's pad with xs).
struct KeyboardLayout: Equatable {
    /// The views' inset on the left and on the right.
    static let inset = 6.0
    /// A black key's width per keyboard width, and its height per height.
    static let blackWidth = 0.0115
    static let blackHeight = 0.6

    /// The highest key, 85 or 88.
    let top: Int
    /// The number of white keys.
    let whites: Int
    /// The centre of key k per keyboard width, at index k (0 unused).
    private let centres: [Double]
    /// For a white key its index among the whites; for a black key the
    /// index of the gap it sits on.
    private let slots: [Int]
    /// The white keys from left to right.
    private let whiteKeys: [Int]

    init(top: Int) {
        let top = max(1, top)
        self.top = top
        let whiteKeys = (1...top).filter { !isBlack($0) }
        let whites = Double(whiteKeys.count)
        var centres = [0.0]
        var slots = [0]
        var wi = 0
        for k in 1...top {
            if isBlack(k) {
                centres.append(Double(wi) / whites)
                slots.append(wi)
            } else {
                centres.append((Double(wi) + 0.5) / whites)
                slots.append(wi)
                wi += 1
            }
        }
        self.whites = whiteKeys.count
        self.whiteKeys = whiteKeys
        self.centres = centres
        self.slots = slots
    }

    /// The centre of key k in a view `width` wide that has the inset.
    func x(_ k: Int, width: Double) -> Double {
        let k = max(1, min(top, k))
        return Self.inset + centres[k] * (width - 2 * Self.inset)
    }

    /// The key whose centre is nearest to x, in a view with the inset.
    func nearest(x: Double, width: Double) -> Int {
        let f = (x - Self.inset) / max(1, width - 2 * Self.inset)
        var best = 1
        for k in 2...max(2, top) where k <= top && abs(centres[k] - f) < abs(centres[best] - f) {
            best = k
        }
        return best
    }

    /// The width of a white key on a keyboard of this size (without inset).
    func whiteWidth(_ size: CGSize) -> Double {
        size.width / Double(max(1, whites))
    }

    /// The rectangle of key k on a keyboard of this size (without inset).
    func rect(_ k: Int, in size: CGSize) -> CGRect {
        let ww = whiteWidth(size)
        if isBlack(k) {
            let w = Self.blackWidth * size.width
            return CGRect(x: Double(slots[k]) * ww - w / 2, y: 0, width: w, height: size.height * Self.blackHeight)
        }
        return CGRect(x: Double(slots[k]) * ww, y: 0, width: ww, height: size.height)
    }

    /// The key at a point on a keyboard of this size (without inset): a
    /// black key where one lies over the whites.
    func key(at p: CGPoint, in size: CGSize) -> Int? {
        guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height else { return nil }
        if p.y <= size.height * Self.blackHeight {
            let gap = Int((p.x / whiteWidth(size)).rounded())
            for k in 1...top where isBlack(k) && slots[k] == gap && rect(k, in: size).contains(p) {
                return k
            }
        }
        let wi = min(whites - 1, max(0, Int(p.x / whiteWidth(size))))
        return whiteKeys[wi]
    }

    /// Every white key, then every black one: the order to draw them in.
    var drawingOrder: [Int] {
        whiteKeys + (1...top).filter(isBlack)
    }
}
