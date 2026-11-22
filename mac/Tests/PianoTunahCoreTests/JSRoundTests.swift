import Testing
@testable import PianoTunahCore

@Test func jsRoundMatchesMathRound() throws {
    let cases = try #require(try Fixtures.json("jsround.json")["cases"].array)
    #expect(cases.count > 40)
    for c in cases {
        let x = try #require(c["x"].double)
        let want = try #require(c["round"].double)
        let got = jsRound(x)
        if want.isNaN {
            #expect(got.isNaN, "jsRound(\(x))")
        } else {
            // Bit for bit, so the sign of zero counts.
            #expect(got.bitPattern == want.bitPattern, "jsRound(\(x)) = \(got), Math.round gives \(want)")
        }
    }
}

@Test func jsRoundOnTheHardCases() {
    #expect(jsRound(0.49999999999999994) == 0)
    #expect(jsRound(2.5) == 3)
    #expect(jsRound(-2.5) == -2)
    #expect(jsRound(-0.5).sign == .minus)
}
