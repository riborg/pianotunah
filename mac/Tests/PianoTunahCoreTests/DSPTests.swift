import Foundation
import Testing
@testable import PianoTunahCore

// DSP.swift against dsp.json, the sound in dsp/*.f32 and steady.json from
// web/test/fixtures.mjs.
//
// Tolerances: frequencies within 0.01 cent (1200·log2(got/want)); B and f0
// of the inharmonicity fit within 1e-6 relative; dB values (prom, score,
// margin, rmsDb, zoom, BeatMeter levels and pulse depth) within 1e-6 dB.
// Keys, shifts, counts, verdicts, times and pulse rates exactly. The JS and
// Swift numbers differ only by the ulps that V8's and the platform's libm
// (cos, sin, log10, pow, hypot) give apart; each test prints the largest
// difference it saw.

private let centsTolerance = 0.01
private let dbTolerance = 1e-6
private let relTolerance = 1e-6

private func dspFixture() throws -> JSON { try Fixtures.json("dsp.json") }

private func num(_ j: JSON) throws -> Double { try #require(j.double, "not a number: \(j)") }

private func int(_ j: JSON) throws -> Int { try #require(j.int, "not an integer: \(j)") }

private func nums(_ j: JSON) throws -> [Double] { try #require(j.doubles, "not numbers: \(j)") }

private func cents(_ a: Double, _ b: Double) -> Double { abs(1200 * log2(a / b)) }

/// The largest differences seen in one test, by quantity.
private final class MaxError {
    private var worst: [String: Double] = [:]

    func note(_ what: String, _ e: Double) {
        worst[what] = max(worst[what] ?? 0, e)
    }

    func report(_ test: String) {
        let parts = worst.keys.sorted().map { "\($0) \(worst[$0]!)" }
        print("\(test) max error: \(parts.joined(separator: ", "))")
    }
}

/// Fixture targets as the core keeps them; only freq and B are used.
private func targets(_ j: JSON) throws -> Targets {
    let freq = try nums(j["freq"])
    let b = try nums(j["B"])
    #expect(freq.count == keyCount + 1 && b.count == keyCount + 1)
    return Targets(inharmonicity: b, stretch: [], temperament: [], cents: [], frequency: freq)
}

@Test func dspTargetsMatchTheory() throws {
    // The fixture's targets are computeTargets of its settings; check that
    // the Swift ones agree, so the DSP tests do not hide a Theory mismatch.
    let d = try dspFixture()
    let t = try targets(d["targets"]["defaults"])
    let mine = computeTargets()
    for k in 1...keyCount {
        #expect(abs(mine.frequency[k] - t.frequency[k]) <= 1e-12 * t.frequency[k])
        #expect(abs(mine.inharmonicity[k] - t.inharmonicity[k]) <= 1e-12 * t.inharmonicity[k])
    }
}

@Test func dspAnalyzer() throws {
    let d = try dspFixture()
    let all = try #require(d["targets"].object)
    let tset = try all.mapValues(targets)
    let sounds = try #require(d["sounds"].array)
    #expect(sounds.count == 16)
    let err = MaxError()
    var calls = 0
    for s in sounds {
        let file = try #require(s["file"].string)
        let buf = try Fixtures.f32("dsp/\(file)")
        #expect(buf.count == (try int(s["length"])), "\(file) length")
        let a = Analyzer(sampleRate: try num(s["sampleRate"]))
        a.load(buf)

        let rms = rmsDb(buf)
        err.note("rmsDb dB", abs(rms - (try num(s["rmsDb"]))))
        #expect(abs(rms - (try num(s["rmsDb"]))) <= dbTolerance, "\(file) rmsDb")

        for c in try #require(s["detectKey"].array) {
            let tname = try #require(c["targets"].string)
            let t = try #require(tset[tname])
            var heard: [Double]?
            if let h = c["heard"].object {
                var cs = [Double](repeating: .nan, count: keyCount + 1)
                for (k, v) in h { cs[try #require(Int(k))] = try num(v) }
                heard = cs
            }
            let got = a.detectKey(t, prevKey: c["prevKey"].int ?? 0, top: c["top"].int ?? keyCount, heard: heard)
            let want = c["result"]
            let what = "\(file) detectKey \(c)"
            #expect(got.key == (try int(want["key"])), "\(what) key")
            #expect(got.shift == (try num(want["shift"])), "\(what) shift")
            for (name, g, w) in [("score", got.score, try num(want["score"])), ("margin", got.margin, try num(want["margin"]))] {
                if w.isFinite {
                    err.note("detectKey \(name) dB", abs(g - w))
                    #expect(abs(g - w) <= dbTolerance, "\(what) \(name) \(g) vs \(w)")
                } else {
                    #expect(g == w || (g.isNaN && w.isNaN), "\(what) \(name) \(g) vs \(w)")
                }
            }
            #expect(got.surveyDetection == Survey.Detection(key: got.key, score: got.score, margin: got.margin))
            calls += 1
        }

        for c in try #require(s["measure"].array) {
            let got = a.measure(try num(c["target"]), cents: try num(c["cents"]), minProm: try num(c["minProm"]))
            let what = "\(file) measure partial \(c["partial"])"
            let want = c["result"]
            if want.isNull {
                #expect(got == nil, "\(what)")
                continue
            }
            let g = try #require(got, "\(what) is nil")
            let dc = cents(g.frequency, try num(want["freq"]))
            let dp = abs(g.prom - (try num(want["prom"])))
            err.note("measure freq cents", dc)
            err.note("measure prom dB", dp)
            #expect(dc <= centsTolerance, "\(what) freq")
            #expect(dp <= dbTolerance, "\(what) prom")
            calls += 1
        }

        for c in try #require(s["inharmonicity"].array) {
            let got = a.inharmonicity(f1: try num(c["f1"]), bGuess: try num(c["Bguess"]))
            let what = "\(file) inharmonicity"
            let want = c["result"]
            if want.isNull {
                #expect(got == nil, "\(what)")
                continue
            }
            let g = try #require(got, "\(what) is nil")
            let wb = try num(want["B"])
            let wf = try num(want["f0"])
            err.note("inharmonicity B rel", abs(g.b - wb) / wb)
            err.note("inharmonicity f0 cents", cents(g.f0, wf))
            #expect(abs(g.b - wb) <= relTolerance * wb, "\(what) B \(g.b) vs \(wb)")
            #expect(abs(g.f0 - wf) <= relTolerance * wf, "\(what) f0")
            #expect(cents(g.f0, wf) <= centsTolerance, "\(what) f0 cents")
            #expect(g.partials == (try int(want["partials"])), "\(what) partials")
            #expect(g.maxN == (try int(want["maxN"])), "\(what) maxN")
            calls += 1
        }

        for c in try #require(s["zoom"].array) {
            let got = a.zoom(try num(c["fc"]), cents: try num(c["cents"]), bins: try int(c["bins"]))
            let want = try nums(c["db"])
            #expect(got.count == want.count, "\(file) zoom bins")
            for (g, w) in zip(got, want) {
                err.note("zoom dB", abs(Double(g) - w))
                #expect(abs(Double(g) - w) <= dbTolerance, "\(file) zoom \(g) vs \(w)")
            }
            calls += 1
        }
    }
    #expect(calls >= 120)
    err.report("dspAnalyzer (\(calls) calls)")
}

@Test func dspBeatMeter() throws {
    let meters = try #require(try dspFixture()["beatMeter"].array)
    #expect(meters.count == 3)
    let err = MaxError()
    var frames = 0
    for mj in meters {
        let name = try #require(mj["name"].string)
        let x = try Fixtures.f32("dsp/\(try #require(mj["file"].string))")
        #expect(x.count == (try int(mj["length"])))
        let sr = try num(mj["sampleRate"])
        let f = try num(mj["f"])
        let size = try int(mj["frameSize"])
        var bm = BeatMeter()
        for fj in try #require(mj["frames"].array) {
            let end = try int(fj["end"])
            let t = Double(end) / sr
            #expect(t == (try num(fj["t"])), "\(name) t")
            bm.add(Array(x[(end - size)..<end]), sampleRate: sr, frequency: f, time: t)
            let pulse = bm.pulse()
            let verdict = bm.beats(given: pulse)
            let what = "\(name) at \(end)"
            #expect(bm.times.count == (try int(fj["levels"])), "\(what) levels")
            #expect(bm.span == (try num(fj["span"])), "\(what) span")
            if fj["pulse"].isNull {
                #expect(pulse == nil, "\(what) pulse")
            } else {
                let p = try #require(pulse, "\(what) pulse is nil")
                #expect(p.rate == (try num(fj["pulse"]["rate"])), "\(what) rate \(p.rate)")
                let dd = abs(p.db - (try num(fj["pulse"]["db"])))
                err.note("pulse db", dd)
                #expect(dd <= dbTolerance, "\(what) pulse db")
            }
            #expect(verdict == fj["verdict"].bool, "\(what) verdict")
            #expect(bm.quiet == fj["quiet"].bool, "\(what) quiet")
            frames += 1
        }
        #expect(bm.times == (try nums(mj["ts"])), "\(name) ts")
        let ys = try nums(mj["ys"])
        #expect(bm.levels.count == ys.count)
        for (g, w) in zip(bm.levels, ys) {
            err.note("levels dB", abs(g - w))
            #expect(abs(g - w) <= dbTolerance, "\(name) level")
        }
    }
    err.report("dspBeatMeter (\(frames) frames)")
}

@Test func dspBeatMeterGap() throws {
    let g = try dspFixture()["beatMeterGap"]
    let buf = try Fixtures.f32("dsp/\(try #require(g["file"].string))")
    let sr = try num(g["sampleRate"])
    let f = try num(g["f"])
    var bm = BeatMeter()
    for add in try #require(g["adds"].array) {
        bm.add(buf, sampleRate: sr, frequency: f, time: try num(add["t"]))
        #expect(bm.times == (try nums(add["ts"])), "ts after t = \(add["t"])")
        if let ys = add["ys"].doubles {
            #expect(bm.levels.count == ys.count)
            for (a, b) in zip(bm.levels, ys) { #expect(abs(a - b) <= dbTolerance) }
        }
    }
}

@Test func dspSteady() throws {
    let s = try Fixtures.json("steady.json")
    #expect(try int(s["STEADY_N"]) == steadyN)
    let cases = try #require(s["steady"].array)
    #expect(cases.count >= 50)
    for c in cases {
        let cs = try nums(c["cs"])
        #expect(steady(cs) == c["steady"].bool, "steady(\(cs))")
    }
}

@Test func dspMedian() throws {
    for c in try #require(try Fixtures.json("steady.json")["median"].array) {
        let a = try nums(c["a"])
        let want = try num(c["median"])
        let got = median(a)
        #expect(got.bitPattern == want.bitPattern || (got.isNaN && want.isNaN), "median(\(a)) = \(got), want \(want)")
    }
}

@Test func dspBeatsDecision() throws {
    for seq in try #require(try Fixtures.json("steady.json")["beats"].array) {
        var bm = BeatMeter()
        for st in try #require(seq["steps"].array) {
            let p = st["pulse"]
            let pulse = p.isNull ? nil : BeatMeter.Pulse(rate: try num(p["rate"]), db: try num(p["db"]))
            let verdict = bm.beats(given: pulse)
            #expect(verdict == st["verdict"].bool, "beats after \(p)")
            #expect(bm.hits == (try int(st["hits"])))
            #expect(bm.misses == (try int(st["misses"])))
            #expect(bm.on == st["on"].bool)
        }
    }
}

@Test func dspEdgeCases() {
    let a = Analyzer(sampleRate: 48000)
    a.load([Float](repeating: 0, count: 16384))
    // NaN in gives NaN out, as JS does, rather than a trap.
    let p = a.peakNear(.nan, cents: 30)
    #expect(p != nil && p!.frequency.isNaN && p!.prom.isNaN)
    let m = a.measure(.nan)
    #expect(m != nil && m!.frequency.isNaN)
    #expect(a.peakNear(.infinity, cents: 30) == nil)
    #expect(a.peakNear(-.infinity, cents: 30) == nil)
    #expect(a.refine(440) == 440)  // a buffer too short for the phase step
    #expect(rmsDb([1, 1]).isNaN)
    #expect(rmsDb([1, 1], len: 0).isNaN)
    let none = a.detectKey(computeTargets(), top: 0)
    #expect(none.key == 0 && none.score == -.infinity && none.margin == 0)
    #expect(median([]).isNaN)
    #expect(!steady([1, 2, 3]))
    var bm = BeatMeter()
    #expect(bm.pulse() == nil && bm.beats() == nil && !bm.quiet && bm.span == 0)
}
