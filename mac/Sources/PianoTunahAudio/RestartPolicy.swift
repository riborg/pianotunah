/// When to start the input again after something changed or stopped it.
///
/// - The user's restart (a new device choice, a retry button) happens at
///   once and gives a fresh budget.
/// - Any other trigger waits ``debounce`` s, and the triggers that arrive
///   meanwhile join it: one restart for a burst of notifications.
/// - The engine's own configuration change can be caused by its start (a
///   Bluetooth headset switching to its hands-free profile when the
///   microphone opens), so the automatic restarts are capped: at most
///   ``maxRestarts`` in ``window`` s. Past that the policy gives up
///   (``isExhausted``) and the input stays failed until the inputs change,
///   the Mac wakes, or the user restarts. A wake or the user gives a fresh
///   budget; a change of inputs tries again within the same one, as a
///   headset switching profiles may change the inputs too, so the restarts
///   never exceed the cap without a person or a wake behind them.
///
/// Which triggers apply in which state is the owner's call (see
/// `AudioSession`). Pure and a value type; times are in s of one steady
/// clock.
public struct RestartPolicy: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        /// The engine's configuration changed and it stopped.
        case configurationChange
        /// Inputs came or went, or the default input changed.
        case inputsChanged
        /// The Mac woke from sleep.
        case wake
        /// The user asked for it.
        case user
    }

    public enum Action: Sendable, Equatable {
        /// Restart now.
        case now
        /// Call ``due(at:)`` at this time.
        case at(Double)
    }

    public let debounce: Double
    public let maxRestarts: Int
    public let window: Double

    /// When the pending restart is due, or nil if none is.
    public private(set) var pending: Double?
    /// Too many restarts: only `inputsChanged`, `wake` or `user` try again,
    /// and `configurationChange` is ignored.
    public private(set) var isExhausted = false
    /// The automatic restarts within the last ``window``, oldest first.
    private var restarts: [Double] = []
    /// A change of inputs is among the triggers of the pending restart. If
    /// the budget refuses it, it waits for room instead of being dropped: a
    /// microphone plugged in just after a headset gave up still starts.
    private var inputsPending = false

    public init(debounce: Double = 0.5, maxRestarts: Int = 3, window: Double = 10) {
        precondition(debounce >= 0 && maxRestarts > 0 && window > 0)
        self.debounce = debounce
        self.maxRestarts = maxRestarts
        self.window = window
    }

    /// A trigger at `now`. Returns what to do, or nil: nothing (a restart
    /// is already pending, or the policy gave up).
    public mutating func request(_ trigger: Trigger, at now: Double) -> Action? {
        switch trigger {
        case .user:
            reset()
            return .now
        case .wake:
            restarts.removeAll()
            isExhausted = false
            // A restart waiting for room in the budget can go sooner now.
            if let p = pending, p > now + debounce {
                pending = now + debounce
                return .at(now + debounce)
            }
        case .inputsChanged:
            // Tries again, but within the same budget: a headset switching
            // profiles may change the inputs too, and must not loop.
            isExhausted = false
            inputsPending = true
        case .configurationChange:
            if isExhausted { return nil }
        }
        if pending != nil { return nil }
        let due = now + debounce
        pending = due
        return .at(due)
    }

    /// The pending restart's time has come, at `now`. True: restart now.
    /// False: none was pending, or there were too many. Then, if a change of
    /// inputs is waiting, ``pending`` is the time the oldest restart leaves
    /// the window, to call this again; otherwise the policy gives up
    /// (``isExhausted``).
    public mutating func due(at now: Double) -> Bool {
        guard pending != nil else { return false }
        pending = nil
        restarts.removeAll { now - $0 >= window }
        guard restarts.count < maxRestarts else {
            if inputsPending, let oldest = restarts.first {
                pending = oldest + window
            } else {
                isExhausted = true
            }
            return false
        }
        restarts.append(now)
        inputsPending = false
        return true
    }

    /// Forgets the pending restart, the count and the giving up: for a stop
    /// or a fresh start.
    public mutating func reset() {
        pending = nil
        inputsPending = false
        isExhausted = false
        restarts.removeAll()
    }
}
