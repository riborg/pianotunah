import Foundation

/// Any JSON value, for data that is loosely typed in the web version: saved
/// settings from older pianos, fields the app does not know. `jsNumber` and
/// `isTruthy` convert it the way JavaScript's `Number(x)` and `if (x)` do.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The member `key` of an object, or nil (JS: undefined).
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The value as a string, if it is one.
    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The value as a number, if it is one (no conversion).
    public var number: Double? {
        if case .number(let x) = self { return x }
        return nil
    }

    /// The value as an object, if it is one.
    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// JavaScript's `Number(x)`: null is 0, true 1, a string is parsed as a
    /// JS numeric literal after trimming white space ("" is 0, "0x1A" is 26,
    /// anything else NaN), an array is converted through its string form and
    /// an object is NaN.
    public var jsNumber: Double {
        switch self {
        case .null: 0
        case .bool(let b): b ? 1 : 0
        case .number(let x): x
        case .string(let s): JSONValue.jsNumber(s)
        case .array(let a):
            // String([]) is "", String([x]) is String(x), and two or more
            // elements are joined with a comma, which no number has.
            switch a.count {
            case 0: 0
            case 1:
                switch a[0] {
                case .null: 0
                case .bool, .object: .nan
                default: a[0].jsNumber
                }
            default: .nan
            }
        case .object: .nan
        }
    }

    /// Whether JavaScript counts the value as true: everything except null,
    /// false, 0, NaN and "".
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let x): x != 0 && !x.isNaN
        case .string(let s): !s.isEmpty
        case .array, .object: true
        }
    }

    /// JavaScript's white space and line terminators, which `Number` trims.
    private static let jsWhitespace = CharacterSet(charactersIn:
        "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}"
        + "\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

    /// `Number(s)` for a string.
    static func jsNumber(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: jsWhitespace)
        if t.isEmpty { return 0 }
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let chars = Array(t.utf8)
        if chars.count > 2, chars[0] == UInt8(ascii: "0") {
            let radix: Int? = switch chars[1] {
            case UInt8(ascii: "x"), UInt8(ascii: "X"): 16
            case UInt8(ascii: "o"), UInt8(ascii: "O"): 8
            case UInt8(ascii: "b"), UInt8(ascii: "B"): 2
            default: nil
            }
            if let radix {
                var v = 0.0
                for c in chars.dropFirst(2) {
                    guard let d = Int(String(UnicodeScalar(c)), radix: radix) else { return .nan }
                    v = v * Double(radix) + Double(d)
                }
                return v
            }
        }
        // [+-] (digits [. [digits]] | . digits) [(e|E) [+-] digits]
        var i = 0
        func digits() -> Int {
            let start = i
            while i < chars.count, chars[i] >= UInt8(ascii: "0"), chars[i] <= UInt8(ascii: "9") { i += 1 }
            return i - start
        }
        if i < chars.count, chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-") { i += 1 }
        var mantissa = digits()
        if i < chars.count, chars[i] == UInt8(ascii: ".") {
            i += 1
            mantissa += digits()
        }
        guard mantissa > 0 else { return .nan }
        if i < chars.count, chars[i] == UInt8(ascii: "e") || chars[i] == UInt8(ascii: "E") {
            i += 1
            if i < chars.count, chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { return .nan }
        }
        guard i == chars.count else { return .nan }
        return Double(t) ?? .nan
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let x = try? c.decode(Double.self) {
            self = .number(x)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let x): try c.encode(x)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
