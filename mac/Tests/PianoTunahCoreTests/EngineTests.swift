import Foundation
import Testing
@testable import PianoTunahCore

// Engine.swift against the scenarios in Fixtures/engine/ from
// web/test/fixtures.mjs: each is replayed step by step, commands and frames of
// sound, and after every step the events and a snapshot of the engine must
// match the web version's. Events, keys, modes, positions and every other
// decision exactly; numbers within 1e-9 relative, or 1e-9 absolute below 1
// (docs/macos-port.md, step 1). Each scenario prints the largest difference
// it saw.

private let tolerance = 1e-9

private let scenarioNames = [
    "lock-save", "lock-ref", "auto-follow", "auto-ref", "jump", "measure-b", "beats", "order-confirm",
    "order-advice", "order-beating", "survey", "survey-commands", "order-commands", "advice", "pass", "settings",
]

// MARK: - JSON both ways

private func json(_ v: JSONValue) -> JSON {
    switch v {
    case .null: .null
    case .bool(let b): .bool(b)
    case .number(let x): .number(x)
    case .string(let s): .string(s)
    case .array(let a): .array(a.map(json))
    case .object(let o): .object(o.mapValues(json))
    }
}

private func jsonValue(_ j: JSON) -> JSONValue {
    switch j {
    case .null: .null
    case .bool(let b): .bool(b)
    case .number(let x): .number(x)
    case .string(let s): .string(s)
    case .array(let a): .array(a.map(jsonValue))
    case .object(let o): .object(o.mapValues(jsonValue))
    }
}

private func num(_ x: Double) -> JSON { .number(x) }
private func num(_ x: Int) -> JSON { .number(Double(x)) }
private func nums(_ xs: [Double]) -> JSON { .array(xs.map(num)) }
private func ints(_ xs: [Int]) -> JSON { .array(xs.map(num)) }
private func opt<T>(_ x: T?, _ f: (T) -> JSON) -> JSON { x.map(f) ?? .null }

private func piano(_ j: JSON) throws -> Piano {
    Piano(object: try #require(jsonValue(j).object, "piano \(j)"))
}

// MARK: - What the engine shows, as the fixtures write it

private func eventJSON(_ e: Engine.Event) -> JSON {
    func ev(_ type: String, _ fields: [String: JSON] = [:]) -> JSON {
        .object(fields.merging(["type": .string(type)]) { a, _ in a })
    }
    switch e {
    case .key(let k, let manual): return ev("key", ["k": num(k), "manual": .bool(manual)])
    case .mode(let m): return ev("mode", ["mode": .string(m.rawValue)])
    case .targets: return ev("targets")
    case .dirty: return ev("dirty")
    case .saved(let k): return ev("saved", ["k": num(k)])
    case .flash(let k): return ev("flash", ["k": num(k)])
    case .survey: return ev("survey")
    case .order: return ev("order")
    case .orderState: return ev("orderState")
    case .measureB(let on): return ev("measureB", ["on": .bool(on)])
    case .log(let line): return ev("log", ["line": .string(line)])
    case .message(let m):
        var f: [String: JSON] = ["id": .string(m.id)]
        switch m {
        case .jump(let k, let c): f["k"] = num(k); f["c"] = num(c)
        case .bMeasured(let k, let b), .bOutlier(let k, let b): f["k"] = num(k); f["B"] = num(b)
        case .surveyDone(let r):
            f["quick"] = .bool(r.quick)
            f["b"] = num(r.measuredB)
            f["n"] = num(r.keys)
            f["skipped"] = ints(r.skipped)
            f["outliers"] = ints(r.outliers)
        case .bFailed, .orderDone: break
        }
        return ev("message", f)
    }
}

private func positionJSON(_ p: TuningOrder.Position) -> JSON {
    .object(["step": num(p.step), "i": num(p.index)])
}

private func refAdviceJSON(_ a: Engine.RefAdvice) -> JSON {
    switch a {
    case .none: return .object(["kind": .string("none")])
    case .near(let m): return .object(["kind": .string("near"), "m": num(m)])
    case .off(let o):
        var f: [String: JSON] = ["kind": .string("off"), "m": num(o.m), "hz": num(o.hz), "p": num(o.p)]
        if let x = o.o { f["o"] = num(x) }
        if let x = o.ohz { f["ohz"] = num(x) }
        if let x = o.big { f["big"] = .bool(x) }
        return .object(f)
    }
}

/// The snapshot web/test/fixtures.mjs takes after each step (snap there).
private func snapshot(_ e: Engine) -> [String: JSON] {
    let k = e.key
    let m = e.beatMeter
    let stats = e.stats
    let s: [String: JSON] = [
        "key": num(k), "mode": .string(e.mode.rawValue), "top": num(e.top), "signal": .bool(e.signal),
        "stable": .bool(e.stable), "level": num(e.level), "prevLevel": num(e.prevLevel), "levels": nums(e.levels),
        "noise": num(e.noise), "gate": num(e.gate), "attacks": num(e.attacks), "inAttack": .bool(e.inAttack),
        "cand": num(e.candidate), "candCount": num(e.candidateCount), "autoFrames": num(e.autoFrames),
        "shift": num(e.shift), "readings": num(e.readings.count),
        "reading": opt(e.readings.last) { nums([$0.cents, $0.hz]) }, "refTainted": .bool(e.refTainted),
        "display": num(e.display), "measHz": num(e.measuredHz), "beatHz": num(e.beatHz),
        "strobe": .array(e.strobe.map { .array([num($0.partial), num($0.cents)]) }),
        "strobeReadings": .array(e.strobeReadings.map(nums)),
        "partialDevs": .array(e.partialDeviations.map { opt($0, num) }),
        "col": opt(e.frameColumn) { c in
            .object(["c": num(c.cents), "n": num(c.magnitudes.count),
                     "bins": nums([0, 12, 24, 36, 47].map { Double(c.magnitudes[$0]) })])
        },
        "spec": num(e.spectrogram.count), "specCols": num(e.spectrogram.compactMap { $0 }.count),
        "beating": .bool(e.beating), "beatKnown": .bool(e.beatKnown), "beatFedAt": num(e.beatFedAt),
        "beatUnheard": .bool(e.beatUnheard), "unisonSkip": num(e.unisonSkip),
        "meter": .object(["levels": num(m.times.count), "span": num(m.span), "hits": num(m.hits),
                          "misses": num(m.misses), "on": .bool(m.on), "quiet": .bool(m.quiet)]),
        "frameTime": num(e.frameTime),
        "rec": opt(e.piano.keys[k]) { json($0.json) }, "measured": num(e.piano.keys.count),
        "dev": num(e.curDev(k)), "before": num(e.beforeDev(k)), "goal": num(e.goal(k)),
        "statusDev": num(e.statusDev(k)), "status": .string(e.statusClass(e.statusDev(k)).rawValue),
        "shown": .string(e.statusClass(e.display).rawValue), "tolerance": num(e.tolerance),
        "partial": num(e.partialOf(k)), "strings": num(e.strings(k)), "B": num(e.targets.inharmonicity[k]),
        "freq": num(e.targets.frequency[k]), "sine": num(e.sineFreq()), "goalF1": num(e.goalF1(k)),
        "bBad": ints(e.bBad.sorted()),
        "inharmonicity": .object(Dictionary(uniqueKeysWithValues: e.piano.inharmonicity.map { (String($0.key), num($0.value)) })),
        "bReadings": nums(e.bReadings),
        "measureB": opt(e.measureB) { .object(["k": num($0.key), "until": num($0.until)]) },
        "jump": opt(e.jump) { .object(["k": num($0.key), "hz": num($0.hz), "attack": num($0.attack)]) },
        "survey": opt(e.survey) { sk in
            .object([
                "waitAttack": .bool(sk.waitAttack), "pitch": num(sk.pitch.count), "lastPitch": opt(sk.pitch.last, num),
                "bs": num(sk.bs.count), "lastB": opt(sk.bs.last, num), "ms": num(sk.ms), "lost": .bool(sk.lost),
                "wrong": num(sk.wrong), "wrongFrames": num(sk.wrongFrames),
                "heard": opt(sk.heard) { .object(["key": num($0.key), "score": num($0.score), "margin": num($0.margin)]) },
            ])
        },
        "run": opt(e.run) { r in
            .object(["done": ints(r.done.sorted()), "skipped": ints(r.skipped.sorted()), "offsets": nums(r.offsets)])
        },
        "surveyPlan": .string(e.surveyPlan.rawValue), "needsB": .bool(e.needsB(k)), "surveyed": .bool(e.isSurveyed(k)),
        "orderOn": .bool(e.orderOn), "orderActive": .bool(e.orderActive), "orderPos": positionJSON(e.orderPos),
        "task": opt(e.orderTask) { .object(["k": num($0.key), "what": .string($0.action.rawValue)]) },
        "orderSteps": ints(e.order.steps.map(\.tasks.count)),
        "confirm": .object(["since": num(e.orderConfirm.since), "cur": num(e.orderConfirm.current),
                            "ok": opt(e.orderConfirm.ok) { .bool($0) }, "streak": num(e.orderConfirm.streak)]),
        "advice": opt(e.orderAdvice) { .string($0.rawValue) }, "recheck": opt(e.orderRecheck, ints),
        "tuningOrder": positionJSON(e.piano.order),
        "midShift": num(e.midShift), "refAdvice": refAdviceJSON(e.refAdvice),
        "pitchAdvice": opt(e.pitchAdvice) { .object(["m": num($0.m), "off": .bool($0.off)]) },
        "suggestedOverpull": num(e.suggestedOverpull), "fitRefHz": num(e.fitRefHz),
        "passStats": .object(["measured": num(e.passStats.measured), "ok": num(e.passStats.ok)]),
        "recheckKeys": ints(e.recheckKeys()),
        "stats": .object(["frames": num(stats.frames), "readings": num(stats.readings),
                          "idle": .object(stats.idle.mapValues(num)), "savedKey": num(stats.savedKey),
                          "savedAt": num(stats.savedAt)]),
        "history": num(e.piano.history.count), "lastPass": opt(e.piano.history.last) { json($0.json) },
        "passStartedAt": .string(e.piano.passStartedAt),
    ]
    return s
}

// MARK: - Comparing

/// Differences between what the engine gave and the fixture, and the
/// largest numeric difference (relative, absolute below 1).
private struct Diff {
    var problems: [String] = []
    var worst = 0.0

    mutating func compare(_ got: JSON, _ want: JSON, _ path: String) {
        if let a = got.double, let b = want.double {
            if a.isNaN || b.isNaN || a.isInfinite || b.isInfinite {
                if !(a.isNaN && b.isNaN) && a != b { problems.append("\(path): \(a) ≠ \(b)") }
                return
            }
            let err = abs(a - b) / Swift.max(1, abs(a), abs(b))
            worst = Swift.max(worst, err)
            if err > tolerance { problems.append("\(path): \(a) ≠ \(b)") }
            return
        }
        switch (got, want) {
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return problems.append("\(path): \(a.count) elements ≠ \(b.count): \(got) ≠ \(want)") }
            for i in a.indices { compare(a[i], b[i], "\(path)[\(i)]") }
        case (.object(let a), .object(let b)):
            guard Set(a.keys) == Set(b.keys) else {
                return problems.append("\(path): keys \(a.keys.sorted()) ≠ \(b.keys.sorted())")
            }
            for key in b.keys.sorted() { compare(a[key]!, b[key]!, "\(path).\(key)") }
        default:
            if got != want { problems.append("\(path): \(got) ≠ \(want)") }
        }
    }
}

// MARK: - Replaying

/// Collects every event the engine emits.
private final class EventLog {
    var events: [Engine.Event] = []
}

private struct Replay {
    let engine: Engine
    let log: EventLog
    var diff = Diff()
    var expected: [String: JSON] = [:]
    var takes: [String: [Float]] = [:]
    let frameSize: Int

    init(_ fixture: JSON) throws {
        let log = EventLog()
        self.log = log
        engine = Engine(piano: try piano(fixture["piano"]), onEvent: { log.events.append($0) })
        frameSize = try #require(fixture["frameSize"].int)
    }

    /// The frameSize samples of a take ending at `end`, zeros before it starts.
    mutating func window(_ take: String, _ end: Int) throws -> [Float] {
        if takes[take] == nil { takes[take] = try Fixtures.f32("engine/" + take) }
        let x = takes[take]!
        var b = [Float](repeating: 0, count: frameSize)
        let from = end - frameSize
        for i in Swift.max(0, from)..<end { b[i - from] = x[i] }
        return b
    }

    /// Runs one step; returns its frame result for a frame.
    mutating func perform(_ step: JSON, _ label: String) throws -> Engine.FrameResult? {
        let e = engine
        let args = step["args"].array ?? []
        func int(_ i: Int) throws -> Int { try #require(args[i].int, "\(label): argument \(i)") }
        func double(_ i: Int) throws -> Double { try #require(args[i].double, "\(label): argument \(i)") }
        func string(_ i: Int) throws -> String { try #require(args[i].string, "\(label): argument \(i)") }
        func ret(_ got: JSON) { diff.compare(got, step["ret"], "\(label).ret") }
        switch try #require(step["do"].string) {
        case "open" where args.isEmpty: break // done by init
        case "open": e.open(try piano(args[0]))
        case "startAudio": e.startAudio(sampleRate: try double(0))
        case "stopAudio": e.stopAudio()
        case "recompute": e.recompute()
        case "selectKey": e.selectKey(try int(0), manual: args.count < 2 || args[1].bool == true)
        case "setMode": e.setMode(try #require(Engine.Mode(rawValue: try string(0))))
        case "setSurveyPlan": e.setSurveyPlan(try #require(Survey.Scope(rawValue: try string(0))))
        case "skipSurveyKey": e.skipSurveyKey()
        case "redoSurveyKey": e.redoSurveyKey()
        case "setOrderOn": e.setOrderOn(args.first?.bool == true)
        case "goOrder":
            e.goOrder(TuningOrder.Position(step: try #require(args[0]["step"].int), index: try #require(args[0]["i"].int)))
        case "orderNext": e.orderNext()
        case "orderPrev": e.orderPrev()
        case "orderSkip": e.orderSkip()
        case "orderBack": e.orderBack()
        case "setUnisons": e.setUnisons(try string(0))
        case "setPartial": e.setPartial(try int(0))
        case "setStrings":
            let r = e.setStrings(two: try double(0), one: try double(1))
            ret(.object(["two": num(r.two), "one": num(r.one)]))
        case "startMeasureB":
            let r = e.startMeasureB(now: try double(0))
            ret(.object(["k": num(r.key), "until": num(r.until)]))
        case "finishMeasureB": e.finishMeasureB()
        case "newPass": e.newPass(wall: try double(0))
        case "frame":
            let buf = try window(try #require(step["take"].string), try #require(step["end"].int))
            #expect(buf.count >= Engine.bufferSize)
            return e.frame(buf, time: try #require(step["time"].double), now: try #require(step["now"].double),
                           wall: try #require(step["wall"].double), ref: step["ref"].bool ?? false)
        case let other:
            Issue.record("\(label): unknown step \(other)")
        }
        return nil
    }

    /// Runs one step and compares its events and the snapshot after it.
    /// (The events of the first step, the open in init, are in the log already.)
    mutating func step(_ step: JSON, _ label: String) throws {
        defer { log.events = [] }
        let result = try perform(step, label)
        if let result {
            diff.compare(.string(result.idle?.description ?? ""), step["idle"], "\(label).idle")
            if result.events != log.events { diff.problems.append("\(label): returned events differ from emitted") }
        }
        diff.compare(.array(log.events.map(eventJSON)), step["events"], "\(label).events")
        for (key, value) in step["state"].object ?? [:] { expected[key] = value }
        let got = snapshot(engine)
        diff.compare(.object(got), .object(expected), "\(label).state")
    }
}

private func scenario(_ name: String) throws -> JSON { try Fixtures.json("engine/\(name).json") }

/// Replays a scenario; `each` runs after every step.
@discardableResult
private func replay(_ name: String, each: (inout Replay, JSON) throws -> Void = { _, _ in }) throws -> Replay {
    let fixture = try scenario(name)
    var r = try Replay(fixture)
    for (i, step) in try #require(fixture["steps"].array).enumerated() {
        try r.step(step, "\(name) step \(i) (\(step["do"].string ?? "?"))")
        try each(&r, step)
        if r.diff.problems.count > 20 { break }
    }
    return r
}

// MARK: - Scenarios

@Test func everyScenarioIsTested() throws {
    let index = try Fixtures.json("engine/index.json")
    #expect(index["scenarios"].array?.compactMap(\.string) == scenarioNames)
    #expect(index["frameSize"].int == Engine.bufferSize)
    #expect(index["frameMs"].double == Engine.frameMs)
}

@Test(arguments: scenarioNames)
func scenarioMatchesTheWeb(_ name: String) throws {
    let fixture = try scenario(name)
    var r = try replay(name)
    let want = fixture["tuning"]
    let doc = json(r.engine.piano.normalizedJSON)
    var got: [String: JSON] = [:]
    for key in want.object?.keys.sorted() ?? [] { got[key] = doc[key] }
    r.diff.compare(.object(got), want, "\(name).tuning")
    for p in r.diff.problems.prefix(20) { Issue.record("\(p)") }
    print("engine \(name): \(fixture["steps"].array?.count ?? 0) steps, max error \(r.diff.worst)")
}

// MARK: - Requirements from the DSP port

@Test func bufferIsLongEnoughForRefineAndZoom() throws {
    // refine needs 16384 + 8192 samples below 150 Hz, zoom 32768 below 600 Hz.
    #expect(Engine.bufferSize >= 16384 + 8192)
    #expect(Engine.bufferSize >= 32768)
    #expect(try scenario("lock-save")["frameSize"].int == Engine.bufferSize)
    // With fewer, refine gives up below 150 Hz: the reading is the FFT's.
    let sr = 44100.0
    let f = 110.3
    let tone = (0..<Engine.bufferSize).map { Float(sin(2 * Double.pi * f * Double($0) / sr)) }
    let a = Analyzer(sampleRate: sr)
    a.load(tone)
    let full = a.refine(110)
    a.load(Array(tone.suffix(16384 + 8191)))
    #expect(a.refine(110) == 110)
    #expect(abs(full - f) < 0.01)
}

@Test func aShortBufferIsAnIdleFrame() throws {
    var p = Piano(name: "short", now: Date(timeIntervalSince1970: 0), makeID: { "short" })
    p.settings = .defaults
    let e = Engine(piano: p)
    // Before the audio starts there is no analyzer.
    #expect(e.frame([Float](repeating: 0.1, count: Engine.bufferSize), time: 0.09).idle == .shortBuffer)
    e.startAudio(sampleRate: 48000)
    let size = try #require(e.analyzer?.size)
    for n in [0, 1, 2047, 2048, size - 1] {
        let r = e.frame([Float](repeating: 0.1, count: n), time: 0.18)
        #expect(r.idle == .shortBuffer, "\(n) samples")
        #expect(r.events.isEmpty)
    }
    // Nothing but the clocks moved: the level, noise floor and attacks are as before.
    let unchanged = e.level == -100 && e.levels.isEmpty && e.noise == -70 && e.attacks == 0
    #expect(unchanged)
    let idle = !e.signal && e.spectrogram.count == 6 && e.stats.frames == 6
    #expect(idle)
    #expect(e.stats.idle == ["short buffer": 6])
    // A full buffer is analysed again; shorter than bufferSize is counted.
    #expect(e.frame([Float](repeating: 0, count: size), time: 0.27).idle == .quiet)
    #expect(e.levels.count == 1)
    #expect(e.stats.undersized == 1)
    _ = e.frame([Float](repeating: 0, count: Engine.bufferSize), time: 0.36)
    #expect(e.stats.undersized == 1)
}

@Test func aShortBufferInTheMiddleOfANoteChangesNothing() throws {
    var p = Piano(name: "glitch", now: Date(timeIntervalSince1970: 0), makeID: { "glitch" })
    p.settings = .defaults
    let e = Engine(piano: p)
    e.startAudio(sampleRate: 48000)
    e.setMode(.survey)
    // As in the middle of a note: the gate open and readings collected.
    e.signal = true
    var sk = try #require(e.survey)
    sk.waitAttack = false
    sk.pitch = [440.1, 440.2]
    e.survey = sk
    let before = (e.key, e.mode, e.level, e.noise, e.attacks)
    let r = e.frame([Float](repeating: 0.1, count: 100), time: 1.0)
    #expect(r.idle == .shortBuffer && r.events.isEmpty)
    #expect(e.signal)
    let after = try #require(e.survey)
    #expect(!after.lost && after.pitch == [440.1, 440.2] && !after.waitAttack)
    #expect(before == (e.key, e.mode, e.level, e.noise, e.attacks))
}

@Test func theBeatVerdictIsTakenOncePerAdd() throws {
    // A shadow meter takes each add the engine makes with one pulse and one
    // verdict; the engine's meter must agree after every frame, so hits and
    // misses were counted once per add.
    var adds = 0
    var before = BeatMeter()
    var lastHits = 0
    var heardBeating = false
    let r = try replay("beats") { r, step in
        let m = r.engine.beatMeter
        heardBeating = heardBeating || r.engine.beating
        defer { before = m }
        guard step["do"].string == "frame", m.times != before.times, !m.times.isEmpty, !r.engine.inAttack else { return }
        var shadow = before
        let buf = try r.window(try #require(step["take"].string), try #require(step["end"].int))
        shadow.add(buf, sampleRate: 44100, frequency: try #require(r.engine.readings.last?.hz), time: r.engine.frameTime)
        _ = shadow.beats(given: shadow.pulse())
        let agree = shadow.times == m.times && shadow.levels == m.levels && shadow.hits == m.hits
            && shadow.misses == m.misses && shadow.on == m.on
        #expect(agree, "\(step["time"])")
        let oneStep = m.hits <= lastHits + 1
        #expect(oneStep, "\(step["time"])")
        lastHits = m.hits
        adds += 1
    }
    #expect(r.diff.problems.isEmpty)
    #expect(adds >= 15, "\(adds) adds")
    #expect(heardBeating)
}

@Test func theSpectrogramHasAFixedBinCount() throws {
    #expect(Engine.spectrogramBins >= 2)
    var columns = 0
    try replay("lock-save") { r, _ in
        if let c = r.engine.frameColumn {
            #expect(c.magnitudes.count == Engine.spectrogramBins && c.magnitudes.allSatisfy(\.isFinite))
            columns += 1
        }
    }
    #expect(columns > 20)
}

// MARK: - Clamping rules

@Test func clampsMatchTheWeb() throws {
    let c = try Fixtures.json("engine/clamps.json")
    var d = Diff()
    for x in c["clampRef"].array ?? [] {
        d.compare(num(Engine.clampRef(try #require(x["x"].double))), x["out"], "clampRef \(x["x"])")
    }
    for x in c["clampSize"].array ?? [] {
        d.compare(num(Engine.clampSize(try #require(x["kind"].string), try #require(x["v"].double))), x["out"], "clampSize")
    }
    for x in c["clampStrings"].array ?? [] {
        let r = Engine.clampStrings(top: try #require(x["top"].int), two: try #require(x["two"].double),
                                    one: try #require(x["one"].double))
        d.compare(.object(["two": num(r.two), "one": num(r.one)]), x["out"], "clampStrings")
    }
    for x in c["clampPartial"].array ?? [] {
        d.compare(num(Engine.clampPartial(try #require(x["n"].int))), x["out"], "clampPartial")
    }
    for x in c["stepRange"].array ?? [] {
        let id = try #require(x["id"].string.flatMap(TuningOrder.StepID.init(rawValue:)))
        let r = Engine.stepRange(id, top: try #require(x["top"].int))
        d.compare(opt(r) { ints([$0.from, $0.to]) }, x["out"], "stepRange \(id)")
    }
    #expect(d.problems.isEmpty, "\(d.problems)")
    #expect((c["stepRange"].array ?? []).count == 20)
}
