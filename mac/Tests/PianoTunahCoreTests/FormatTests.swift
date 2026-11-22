import Testing
@testable import PianoTunahCore

/// One language's section of format.json, with its decimal separator.
private func languages() throws -> [(name: String, decimal: DecimalSeparator, cases: JSON)] {
    let langs = try #require(try Fixtures.json("format.json")["langs"].object)
    #expect(Set(langs.keys) == ["en", "sv"])
    return try langs.keys.sorted().map { name in
        let l = langs[name]!
        let mark = try #require(l["decimal"].string?.first)
        let decimal = try #require(DecimalSeparator(rawValue: mark), "decimal \(mark)")
        return (name, decimal, l)
    }
}

/// The number `d` of a case, as an Int.
private func digits(_ c: JSON) throws -> Int {
    try #require(c["d"].int)
}

@Test func fmtCMatchesTheJS() throws {
    for (lang, decimal, l) in try languages() {
        let cases = try #require(l["fmtC"].array)
        #expect(cases.count > 100)
        for c in cases {
            let x = try #require(c["c"].double)
            let d = try digits(c)
            let want = try #require(c["s"].string)
            #expect(fmtC(x, d, decimal: decimal) == want, "\(lang) fmtC(\(x), \(d))")
        }
    }
}

@Test func numMatchesTheJS() throws {
    for (lang, decimal, l) in try languages() {
        let cases = try #require(l["num"].array)
        #expect(cases.count > 90)
        for c in cases {
            let x = try #require(c["x"].double)
            let d = try digits(c)
            let want = try #require(c["s"].string)
            #expect(num(x, d, decimal: decimal) == want, "\(lang) num(\(x), \(d))")
        }
    }
}

@Test func fmtHzMatchesTheJS() throws {
    for (lang, decimal, l) in try languages() {
        let cases = try #require(l["fmtHz"].array)
        #expect(cases.count == 20)
        for c in cases {
            let f = try #require(c["f"].double)
            let d = try digits(c)
            let want = try #require(c["s"].string)
            #expect(fmtHz(f, d, decimal: decimal) == want, "\(lang) fmtHz(\(f), \(d))")
        }
    }
}

@Test func fmtBMatchesTheJS() throws {
    for (lang, decimal, l) in try languages() {
        let cases = try #require(l["fmtB"].array)
        #expect(cases.count == 14)
        for c in cases {
            let b = try #require(c["b"].double)
            let want = try #require(c["s"].string)
            #expect(fmtB(b, decimal: decimal) == want, "\(lang) fmtB(\(b))")
        }
    }
}

@Test func shortMatchesTheJS() throws {
    for (lang, decimal, l) in try languages() {
        let cases = try #require(l["short"].array)
        #expect(cases.count == 10)
        for c in cases {
            let x = try #require(c["x"].double)
            let want = try #require(c["s"].string)
            #expect(short(x, decimal: decimal) == want, "\(lang) short(\(x))")
        }
    }
}

@Test func parseNumMatchesTheJS() throws {
    for (lang, _, l) in try languages() {
        let cases = try #require(l["parseNum"].array)
        #expect(cases.count == 37)
        for c in cases {
            let s = try #require(c["s"].string)
            let want = try #require(c["x"].double)
            expectSame(parseNum(s), want, "\(lang) parseNum(\(s.debugDescription))")
        }
    }
}

/// Equal bit for bit, so −0 is not 0; any NaN equals NaN.
private func expectSame(_ got: Double, _ want: Double, _ what: String) {
    if want.isNaN {
        #expect(got.isNaN, "\(what) = \(got), want NaN")
    } else {
        #expect(got.bitPattern == want.bitPattern, "\(what) = \(got), want \(want)")
    }
}

// The values below were taken from Node 26, beyond what format.json covers.

@Test func jsStringOutsideTheFixtures() {
    let cases: [(Double, String)] = [
        (1e21, "1e+21"), (1e20, "100000000000000000000"), (123e-20, "1.23e-18"), (.leastNonzeroMagnitude, "5e-324"),
        (.greatestFiniteMagnitude, "1.7976931348623157e+308"), (-1e-7, "-1e-7"), (0.000001, "0.000001"),
        (1.5e-7, "1.5e-7"), (9007199254740992, "9007199254740992"), (-0.0, "0"), (0.1, "0.1"), (100, "100"),
        (1.5e300, "1.5e+300"), (1.5e21, "1.5e+21"), (123456.789, "123456.789"),
        (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
    ]
    for (x, want) in cases { #expect(jsString(x) == want, "String(\(x))") }
}

@Test func jsToFixedOutsideTheFixtures() {
    let cases: [(Double, Int, String)] = [
        (0.5, 0, "1"), (2.5, 0, "3"), (-2.5, 0, "-3"), (1.45, 1, "1.4"), (1e21, 2, "1e+21"), (-0.0001, 2, "-0.00"),
        (0, 2, "0.00"), (-0.0, 1, "0.0"), (1.005, 2, "1.00"), (123.456, 10, "123.4560000000"),
        (0.1, 20, "0.10000000000000000555"), (.leastNonzeroMagnitude, 2, "0.00"), (1e20, 2, "100000000000000000000.00"),
        (-1.5, 0, "-2"), (0.000001, 7, "0.0000010"), (1152921504606846976, 1, "1152921504606846976.0"),
    ]
    for (x, d, want) in cases { #expect(jsToFixed(x, d) == want, "(\(x)).toFixed(\(d))") }
}

@Test func jsToExponentialOutsideTheFixtures() {
    let cases: [(Double, Int, String)] = [
        (0, 2, "0.00e+0"), (9.999, 2, "1.00e+1"), (-12345, 2, "-1.23e+4"), (1.25, 1, "1.3e+0"),
        (.leastNonzeroMagnitude, 2, "4.94e-324"), (.greatestFiniteMagnitude, 2, "1.80e+308"), (123, 0, "1e+2"), (0.5, 0, "5e-1"),
        (-0.0, 2, "0.00e+0"), (1, 20, "1.00000000000000000000e+0"),
    ]
    for (x, d, want) in cases { #expect(jsToExponential(x, d) == want, "(\(x)).toExponential(\(d))") }
}

@Test func parseNumOutsideTheFixtures() {
    let cases: [(String, Double)] = [
        // "\r\n" is one Character in Swift but two code units in JS.
        ("\r\n12\r\n", 12), ("\u{3000}5", 5), ("\u{FEFF}5", 5), ("\u{2028}1,5\u{2029}", 1.5),
        ("1\u{301}", .nan), ("\u{85}1", .nan), ("\u{200B}1", .nan),
        ("-0,0", -0.0), (",0", 0), ("0.1000000000000000055511151231257827", 0.1),
        ("123456789012345678901234567890", 1.2345678901234568e29),
    ]
    for (s, want) in cases { expectSame(parseNum(s), want, "parseNum(\(s.debugDescription))") }
}
