import Foundation
import Testing
@testable import PianoTunahCore

// Order.swift against order.json and order-checks.json from test/fixtures.mjs.

private typealias Order = TuningOrder

private func int(_ j: JSON, _ what: @autoclosure () -> String = "") throws -> Int {
    try #require(j.int, "not an integer: \(j) \(what())")
}

private func layout(_ j: JSON) throws -> Order.Layout {
    Order.Layout(
        top: try int(j["top"], "top"),
        twoStringsTo: j["twoStringsTo"].isNull ? 0 : try int(j["twoStringsTo"]),
        oneStringTo: j["oneStringTo"].isNull ? 0 : try int(j["oneStringTo"]),
        dsu: j["dsu"].bool ?? false
    )
}

private func partials(_ j: JSON) throws -> PartialPair {
    PartialPair(try int(j[0], "partial"), try int(j[1], "partial"))
}

private func check(_ j: JSON) throws -> Order.Check {
    let a = try #require(j.array, "check \(j)")
    return Order.Check(try int(a[0]), try int(a[1]), a.count > 2 ? try partials(a[2]) : nil)
}

private func task(_ j: JSON) throws -> Order.Task {
    let action = try #require(j["what"].string.flatMap(Order.Action.init(rawValue:)), "what \(j)")
    let checks: [Order.Check]? = if j["checks"].isNull { nil } else {
        try #require(j["checks"].array, "checks \(j)").map(check)
    }
    return Order.Task(key: try int(j["k"]), from: j["from"].isNull ? nil : try int(j["from"]), action: action, checks: checks)
}

private func step(_ j: JSON) throws -> Order.Step {
    let id = try #require(j["id"].string.flatMap(Order.StepID.init(rawValue:)), "id \(j["id"])")
    return Order.Step(id: id, loose: j["loose"].bool ?? false, tasks: try #require(j["tasks"].array).map(task))
}

private func position(_ j: JSON) throws -> Order.Position? {
    j.isNull ? nil : Order.Position(step: try int(j["step"]), index: try int(j["i"]))
}

private func orderFixture() throws -> JSON { try Fixtures.json("order.json") }

@Test func stripMatchesTheFixture() throws {
    let s = try #require(try orderFixture()["strip"].ints)
    #expect(s == [Order.strip.lowerBound, Order.strip.upperBound])
}

@Test func buildOrderMatchesTheFixture() throws {
    let builds = try #require(try orderFixture()["builds"].array)
    #expect(builds.count == 7)
    var tasks = 0
    for b in builds {
        let l = try layout(b["settings"])
        let recheck = try #require(b["recheck"].ints)
        let got = Order(l, recheck: recheck)
        let want = try #require(b["order"].array).map(step)
        #expect(got.steps.count == want.count, "\(l): steps")
        for (g, w) in zip(got.steps, want) {
            #expect(g.id == w.id && g.loose == w.loose, "\(l): step \(w.id)")
            #expect(g.tasks.count == w.tasks.count, "\(l): \(w.id) has \(g.tasks.count) tasks, JS \(w.tasks.count)")
            for (i, (gt, wt)) in zip(g.tasks, w.tasks).enumerated() {
                #expect(gt == wt, "\(l): \(w.id)[\(i)]")
            }
            tasks += w.tasks.count
        }
    }
    print("buildOrder: \(builds.count) builds, \(tasks) tasks")
}

@Test func walkMatchesTheFixture() throws {
    let f = try orderFixture()
    let last = try #require(f["builds"].array?.last)
    let o = Order(try layout(last["settings"]), recheck: try #require(last["recheck"].ints))
    let walk = try #require(f["walk"].array)
    var pos: Order.Position? = .start
    var worst = 0.0
    for w in walk {
        let p = try #require(pos, "the walk ends early at \(w)")
        #expect(p == Order.Position(step: try int(w["step"]), index: try int(w["i"])))
        let want = try #require(w["progress"].double)
        let got = o.progress(p)
        let err = abs(got - want) / max(abs(want), 1e-300)
        worst = max(worst, want == 0 ? abs(got) : err)
        #expect(want == 0 ? got == 0 : err <= 1e-12, "progress \(p): \(got), JS \(want)")
        let t = o.task(at: p).map { "\($0.key) \($0.action.rawValue)" }
        #expect(t == w["task"].string, "task at \(p)")
        #expect(o.previous(before: p) == (try position(w["prev"])), "prev of \(p)")
        pos = o.next(after: p)
    }
    #expect(pos == nil, "the walk goes on past the fixture")
    print("walk: \(walk.count) positions, largest progress error \(worst)")
}

@Test func clampPosMatchesTheFixture() throws {
    let f = try orderFixture()
    let last = try #require(f["builds"].array?.last)
    let o = Order(try layout(last["settings"]), recheck: try #require(last["recheck"].ints))
    let cases = try #require(f["clampPos"].array)
    #expect(cases.count == 7)
    for c in cases {
        // Decoded as the saved piano's `order` field is, then clamped.
        let data = try JSONEncoder().encode(c["pos"].value)
        let pos = try JSONDecoder().decode(Order.Position?.self, from: data)
        let got = o.clamp(pos)
        let step = try #require(c["clamped"]["step"].double)
        let i = try #require(c["clamped"]["i"].double)
        // JS keeps a fraction ({ step: 4, i: 3.7 } stays 3.7, which taskAt
        // finds no task at); a Position holds whole numbers and rounds down.
        #expect(got == Order.Position(step: Int(step.rounded(.down)), index: Int(i.rounded(.down))),
                "clampPos(\(c["pos"].value))")
    }
}

@Test func positionIsStoredWithTheWebKeys() throws {
    let data = try JSONEncoder().encode(Order.Position(step: 4, index: 7))
    let back = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(back == ["step": 4, "i": 7])
    #expect(try JSONDecoder().decode(Order.Position.self, from: data) == Order.Position(step: 4, index: 7))
    let loose = try JSONDecoder().decode(Order.Position.self, from: Data(#"{"step": "3", "i": true}"#.utf8))
    #expect(loose == Order.Position(step: 3, index: 1))
    let notObject = try JSONDecoder().decode(Order.Position.self, from: Data("5".utf8))
    #expect(notObject == .start)
}

@Test func confirmReadingMatchesTheFixture() throws {
    let cases = try #require(try orderFixture()["confirmReading"].array)
    #expect(cases.count == 5)
    for c in cases {
        var conf = Order.Confirmation(attack: try int(c["since"]))
        for s in try #require(c["steps"].array) {
            let attack = try int(s["attack"])
            let ok = try #require(s["ok"].bool as Bool?)
            let done = conf.reading(attack: attack, ok: ok)
            #expect(done == s["done"].bool, "since \(c["since"]): strike \(attack) \(ok)")
            let st = s["state"]
            let want = Order.Confirmation(
                since: try int(st["since"]), current: try int(st["cur"]), ok: st["ok"].bool, streak: try int(st["streak"]))
            #expect(conf == want, "since \(c["since"]): state after strike \(attack) \(ok)")
        }
    }
}

@Test func unisonAdviceMatchesTheFixture() throws {
    let cases = try #require(try orderFixture()["unisonAdvice"].array)
    #expect(cases.count == 121)
    for c in cases {
        let l = Order.Layout(top: 88, twoStringsTo: try int(c["twoStringsTo"]), oneStringTo: try int(c["oneStringTo"]))
        let t: Order.Task? = if c["task"].isNull { nil } else {
            Order.Task(key: try int(c["task"]["k"]),
                       action: try #require(c["task"]["what"].string.flatMap(Order.Action.init(rawValue:))))
        }
        let status = try #require(c["status"].string.flatMap(PitchStatus.init(rawValue:)))
        let clean = try #require(c["clean"].bool as Bool?)
        let got = Order.unisonAdvice(t, strings: l.strings, clean: clean, status: status)
        #expect(got?.rawValue == c["advice"].string, "\(c["task"].value) clean \(clean) \(status)")
    }
}

@Test func unisonTasksAreTheWebOnes() {
    #expect(Order.unisonTasks == [.unison, .pull, .pair, .third])
}

@Test func layoutFromSettings() {
    var s = Settings.defaults
    #expect(Order.Layout(s) == Order.Layout(top: 88, twoStringsTo: 32, oneStringTo: 0, dsu: false))
    s.keyCount = 85
    s.unisons = "dsu"
    s.oneStringTo = 8
    #expect(Order.Layout(s) == Order.Layout(top: 85, twoStringsTo: 32, oneStringTo: 8, dsu: true))
}

// MARK: - checkRows and tunedBefore

private func neighbour(_ j: JSON) throws -> Order.Neighbour? {
    if j.isNull { return nil }
    return Order.Neighbour(lo: try int(j["lo"]), hi: try int(j["hi"]), partials: try partials(j["p"]),
                           beat: try #require(j["beat"].double))
}

/// Within 1e-12 relative, or 1e-12 absolute where JS gives a beat near 0
/// (some are ~1e-13 where 0 is meant). Returns the error.
private func beatError(_ got: Double, _ want: Double) -> Double {
    let d = abs(got - want)
    return abs(want) < 1e-9 ? d : d / abs(want)
}

private func expectRows(_ got: [Order.CheckRow], _ want: JSON, _ what: String) throws -> Double {
    let rows = try #require(want.array, "\(what): rows")
    #expect(got.count == rows.count, "\(what): \(got.count) rows, JS \(rows.count)")
    var worst = 0.0
    func compare(_ g: Order.Neighbour?, _ w: Order.Neighbour?, _ side: String) {
        #expect(g.map { [$0.lo, $0.hi, $0.partials.lower, $0.partials.upper] }
                == w.map { [$0.lo, $0.hi, $0.partials.lower, $0.partials.upper] }, "\(what): \(side)")
        if let g, let w {
            let e = beatError(g.beat, w.beat)
            worst = max(worst, e)
            #expect(e <= 1e-12, "\(what): \(side) beat \(g.beat), JS \(w.beat)")
        }
    }
    for (g, w) in zip(got, rows) {
        let id = "\(what) \(g.lo)-\(g.hi)"
        let lo = try int(w["lo"]), hi = try int(w["hi"]), semis = try int(w["semis"]), p = try partials(w["p"])
        #expect(g.lo == lo && g.hi == hi && g.semis == semis, "\(id): JS \(lo)-\(hi)")
        #expect(g.partials == p, "\(id): partials")
        let wb = try #require(w["beat"].double)
        let e = beatError(g.beat, wb)
        worst = max(worst, e)
        #expect(e <= 1e-12, "\(id): beat \(g.beat), JS \(wb)")
        compare(g.below, try neighbour(w["below"]), "\(id) below")
        compare(g.above, try neighbour(w["above"]), "\(id) above")
    }
    return worst
}

private func plainTargets() -> Targets {
    var s = Settings.defaults
    s.stretch = "none"
    var t = computeTargets(s)
    t.inharmonicity = Array(repeating: 0, count: t.inharmonicity.count)
    return t
}

private func targets(_ name: String?) throws -> Targets {
    switch name {
    case "defaults": computeTargets(.defaults)
    case "plain": plainTargets()
    default: throw FixtureError.missing("targets \(name ?? "nil")")
    }
}

@Test func checkRowsAndTunedBeforeMatchTheFixture() throws {
    let f = try Fixtures.json("order-checks.json")
    let sets = try #require(f["sets"].array)
    #expect(sets.count == 3)
    var worst = 0.0
    var compared = 0
    var windowed = 0
    for set in sets {
        let l = try layout(set["settings"])
        let t = try targets(set["targets"].string)
        let o = Order(l)
        let cases = try #require(set["tasks"].array)
        // Every task with a key but those of the pitch raise, in order.
        let positions = o.steps.enumerated().filter { $0.element.id != .raise }.flatMap { si, s in
            s.tasks.indices.map { Order.Position(step: si, index: $0) }
        }
        #expect(positions.count == cases.count, "\(l): tasks")
        for (p, c) in zip(positions, cases) {
            let what = "\(l) \(p)"
            #expect(p == Order.Position(step: try int(c["step"]), index: try int(c["i"])), "\(what): position")
            let tuned = o.tunedBefore(p)
            #expect(tuned.sorted() == c["tunedBefore"].ints, "\(what): tunedBefore")
            let task = try #require(o.task(at: p))
            worst = max(worst, try expectRows(Order.checkRows(t, task, top: l.top), c["rows"], "\(what) rows"))
            let wantTuned = c["rowsTuned"].isNull ? c["rows"] : c["rowsTuned"]
            if !c["rowsTuned"].isNull { windowed += 1 }
            worst = max(worst, try expectRows(Order.checkRows(t, task, top: l.top, tuned: tuned), wantTuned, "\(what) rowsTuned"))
            compared += 1
        }
    }
    for e in try #require(f["extra"].array) {
        let task = try task(e["task"])
        let tuned = Set(try #require(e["tuned"].ints))
        let got = Order.checkRows(try targets(e["targets"].string), task, top: try int(e["top"]), tuned: tuned)
        worst = max(worst, try expectRows(got, e["rows"], "extra \(task)"))
        compared += 1
    }
    print("checkRows: \(compared) tasks (\(windowed) with windows), largest beat error \(worst)")
}
