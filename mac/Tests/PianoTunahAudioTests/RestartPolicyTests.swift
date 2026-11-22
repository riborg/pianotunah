import Testing
@testable import PianoTunahAudio

@Test func restartsWaitAndABurstIsOne() {
    let p = Policy()
    #expect(p.request(.configurationChange, at: 100) == .at(100.5))
    #expect(p.request(.configurationChange, at: 100.1) == nil) // joins the pending one
    #expect(p.request(.wake, at: 100.2) == nil)
    #expect(p.pending == 100.5)
    #expect(p.due(at: 100.5))
    #expect(p.pending == nil)
    #expect(!p.due(at: 100.6)) // none pending
    #expect(!p.isExhausted)
    #expect(p.request(.configurationChange, at: 101) == .at(101.5))
}

/// A Bluetooth headset that switches profile each time the engine starts:
/// three restarts in 10 s, then the policy gives up and the engine's
/// changes no longer count.
@Test func aSelfInducedLoopStopsAtTheCap() {
    let p = Policy()
    var t = 0.0
    for _ in 0..<3 {
        #expect(p.request(.configurationChange, at: t) == .at(t + 0.5))
        t += 0.5
        #expect(p.due(at: t))
        t += 0.1 // the start causes the next change
    }
    #expect(p.request(.configurationChange, at: t) == .at(t + 0.5))
    #expect(!p.due(at: t + 0.5))
    #expect(p.isExhausted)
    #expect(p.request(.configurationChange, at: t + 1) == nil)
    #expect(p.request(.configurationChange, at: t + 60) == nil)
}

@Test func restartsOutsideTheWindowDoNotCount() {
    let p = Policy(RestartPolicy(debounce: 0.5, maxRestarts: 3, window: 10))
    for start in [0.0, 4, 8, 12, 16, 20] {
        #expect(p.request(.configurationChange, at: start) == .at(start + 0.5))
        #expect(p.due(at: start + 0.5), "at \(start)")
    }
    #expect(!p.isExhausted)
}

@Test func wakeAndTheUserGiveAFreshBudget() {
    var p = exhausted()
    #expect(p.request(.wake, at: 20) == .at(20.5))
    #expect(!p.isExhausted)
    #expect(p.due(at: 20.5))

    p = exhausted()
    #expect(p.request(.user, at: 3) == .now) // at once, even within the window
    #expect(!p.isExhausted && p.pending == nil)
    for i in 0..<3 {
        let t = 3.1 + Double(i)
        #expect(p.request(.configurationChange, at: t) == .at(t + 0.5))
        #expect(p.due(at: t + 0.5))
    }
}

@Test func theUserCancelsAPendingRestart() {
    let p = Policy()
    #expect(p.request(.configurationChange, at: 0) == .at(0.5))
    #expect(p.request(.user, at: 0.2) == .now)
    #expect(p.pending == nil)
    #expect(!p.due(at: 0.5)) // the stale timer finds nothing
}

/// A change of inputs retries after giving up, within the same budget: it
/// may come from the same headset.
@Test func inputsChangedRetriesWithinTheBudget() {
    let p = exhausted()
    #expect(p.request(.inputsChanged, at: 3) == .at(3.5))
    #expect(!p.isExhausted)
    #expect(!p.due(at: 3.5)) // still three in the last 10 s
    #expect(p.isExhausted)
    #expect(p.request(.inputsChanged, at: 12) == .at(12.5))
    #expect(p.due(at: 12.5)) // the first ones have left the window
}

@Test func resetForgetsEverything() {
    let p = exhausted()
    _ = p.request(.inputsChanged, at: 3)
    p.policy.reset()
    #expect(p.policy == RestartPolicy())
}

/// Three restarts at 0.5, 1 and 1.5 s and a refused fourth at 2 s.
private func exhausted() -> Policy {
    let p = Policy()
    for t in [0.0, 0.5, 1.0, 1.5] {
        _ = p.request(.configurationChange, at: t)
        _ = p.due(at: t + 0.5)
    }
    #expect(p.isExhausted)
    return p
}

/// The policy behind a reference, so `#expect` can call its mutating
/// methods.
private final class Policy {
    var policy: RestartPolicy
    init(_ policy: RestartPolicy = RestartPolicy()) { self.policy = policy }
    var pending: Double? { policy.pending }
    var isExhausted: Bool { policy.isExhausted }
    func request(_ trigger: RestartPolicy.Trigger, at now: Double) -> RestartPolicy.Action? {
        policy.request(trigger, at: now)
    }
    func due(at now: Double) -> Bool { policy.due(at: now) }
}
