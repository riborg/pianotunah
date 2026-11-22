import Testing
@testable import PianoTunahCore

/// Fixtures/survey.json, written by test/fixtures.mjs from web/js/survey.js.
private func surveyFixture() throws -> JSON {
    try Fixtures.json("survey.json")
}

private func scope(_ j: JSON) throws -> Survey.Scope {
    try #require(j.string.flatMap(Survey.Scope.init(rawValue:)), "scope \(j)")
}

private func ints(_ j: JSON) throws -> [Int] {
    let a = try #require(j.array, "not an array: \(j)")
    return try a.map { try #require($0.int, "not an integer: \($0)") }
}

private func optionalInt(_ j: JSON) throws -> Int? {
    if j.isNull { return nil }
    let n: Int = try #require(j.int, "not an integer: \(j)")
    return n
}

private func number(_ j: JSON) throws -> Double {
    try #require(j.double, "not a number: \(j)")
}

private func sorted(_ s: Set<Int>) -> [Int] { s.sorted() }

@Test func surveyConstants() throws {
    let c = try surveyFixture()["constants"]
    #expect(try #require(c["PITCH_READINGS"].int) == Survey.pitchReadings)
    #expect(try #require(c["B_READINGS"].int) == Survey.bReadings)
    #expect(try ints(c["QUICK_KEYS"]) == Survey.allAKeys)
    #expect(try number(c["OFFSET_LIMIT"]) == Survey.offsetLimit)
}

@Test func surveyScopesAreStoredAsBefore() {
    #expect(Survey.Scope.allA.rawValue == "quick")
    #expect(Survey.Scope.allKeys.rawValue == "full")
}

@Test func surveyPlanKeys() throws {
    let cases = try #require(try surveyFixture()["planKeys"].array)
    #expect(cases.count == 5)
    for c in cases {
        let s = try scope(c["plan"])
        let top = try #require(c["top"].int)
        #expect(Survey.keys(s, top: top) == (try ints(c["keys"])), "planKeys(\(s), \(top))")
    }
}

@Test func surveyKeysOnNoKeys() {
    #expect(Survey.keys(.allKeys, top: 0).isEmpty)
    #expect(Survey.keys(.allA, top: 0).isEmpty)
}

@Test func surveyBTimeout() throws {
    let t = try surveyFixture()["bTimeoutMs"]
    #expect(Survey.Scope.allA.bTimeoutMs == (try number(t["quick"])))
    #expect(Survey.Scope.allKeys.bTimeoutMs == (try number(t["full"])))
}

@Test func surveyNewKeyState() throws {
    let j = try surveyFixture()["newKeyState"]
    #expect(j.object?.count == 8, "fields of newKeyState changed")
    let sk = Survey.KeyState()
    #expect(sk.waitAttack == j["waitAttack"].bool)
    #expect(sk.pitch == (try #require(j["pitch"].doubles)))
    #expect(sk.bs == (try #require(j["bs"].doubles)))
    #expect(sk.ms == (try number(j["ms"])))
    #expect(sk.lost == j["lost"].bool)
    #expect(j["heard"].isNull && sk.heard == nil)
    #expect(sk.wrong == j["wrong"].int)
    #expect(sk.wrongFrames == j["wrongFrames"].int)
}

/// Measures or skips the keys the run asks for, as the app does, the way
/// test/fixtures.mjs plays each run.
@Test func surveyRuns() throws {
    let runs = try #require(try surveyFixture()["runs"].array)
    #expect(runs.count == 5)
    for r in runs {
        let name = r["name"].string ?? "?"
        let s = try scope(r["plan"])
        let top = try #require(r["top"].int)
        let surveyed = Set(try ints(r["surveyed"]))
        var run = Survey.Run(s, top: top, isSurveyed: surveyed.contains)
        #expect(run.offsets.isEmpty, "\(name)")
        #expect(sorted(run.done) == (try ints(r["start"]["done"])), "\(name): start done")
        #expect(sorted(run.skipped) == (try ints(r["start"]["skipped"])), "\(name): start skipped")

        let steps = try #require(r["steps"].array)
        var k = run.nextPending(s, top: top, after: 0)
        #expect(k == (try optionalInt(r["firstFrom0"])), "\(name): first key")
        var i = 0
        while let key = k {
            guard i < steps.count else {
                Issue.record("\(name): more steps than the fixture's \(steps.count)")
                break
            }
            let step = steps[i]
            #expect(key == step["key"].int, "\(name): step \(i) key")
            let action = try #require(step["action"].string)
            if action == "skip" { run.skipped.insert(key) } else { run.done.insert(key) }
            let next = run.nextPending(s, top: top, after: key)
            #expect(run.handled(key) == step["handled"].bool, "\(name): step \(i) handled")
            #expect(next == (try optionalInt(step["next"])), "\(name): step \(i) next")
            k = next
            i += 1
        }
        #expect(i == steps.count, "\(name): steps")
        #expect(sorted(run.done) == (try ints(r["end"]["done"])), "\(name): end done")
        #expect(sorted(run.skipped) == (try ints(r["end"]["skipped"])), "\(name): end skipped")
    }
}

@Test func surveyNextPendingProbes() throws {
    let probes = try #require(try surveyFixture()["nextPending"].array)
    #expect(probes.count == 13)
    for p in probes {
        let s = try scope(p["plan"])
        let top = try #require(p["top"].int)
        let run = Survey.Run(done: Set(try ints(p["done"])), skipped: Set(try ints(p["skipped"])))
        let from = try #require(p["from"].int)
        #expect(run.nextPending(s, top: top, after: from) == (try optionalInt(p["next"])), "nextPending(\(s), \(top), \(from))")
    }
}

@Test func surveyWrongKey() throws {
    let cases = try #require(try surveyFixture()["wrongKey"].array)
    #expect(cases.count == 19)
    for c in cases {
        let d = c["d"]
        let heard: Survey.Detection? = d.isNull
            ? nil
            : Survey.Detection(key: try #require(d["key"].int), score: try number(d["score"]), margin: try number(d["margin"]))
        let k = try #require(c["k"].int)
        let raw = try number(c["raw"])
        let ref = try number(c["ref"])
        let done = Set(try ints(c["done"]))
        let want = try #require(c["result"].int)
        #expect(Survey.wrongKey(heard, key: k, raw: raw, ref: ref, done: done) == want,
                "wrongKey(\(String(describing: heard)), \(k), \(raw), \(ref), \(done.sorted()))")
    }
}

@Test func surveyKeyStates() throws {
    let cases = try #require(try surveyFixture()["keyStates"].array)
    #expect(cases.count == 18)
    for c in cases {
        let s = try scope(c["plan"])
        var sk = Survey.KeyState()
        sk.pitch = Array(repeating: 0, count: try #require(c["pitch"].int))
        sk.bs = Array(repeating: 0, count: try #require(c["bs"].int))
        sk.ms = try number(c["ms"])
        let what = "\(s) pitch \(sk.pitch.count) bs \(sk.bs.count) ms \(sk.ms)"
        #expect(sk.bGivenUp(s) == c["bGivenUp"].bool, "bGivenUp \(what)")
        #expect(sk.isDone(needsB: true, s) == c["keyDoneNeedB"].bool, "keyDone needB \(what)")
        #expect(sk.isDone(needsB: false, s) == c["keyDoneNoB"].bool, "keyDone no B \(what)")
    }
}
