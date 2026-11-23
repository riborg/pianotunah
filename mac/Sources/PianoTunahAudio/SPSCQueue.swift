import Synchronization

/// A fixed-size single-producer, single-consumer queue without locks, for
/// plain values such as ``ToneSynth/Command``: the UI pushes, the render
/// callback pops.
///
/// Threads: one producer calls ``push(_:)``, one consumer calls ``pop()``.
/// Neither allocates or blocks. `Element` is `BitwiseCopyable`, so moving
/// one in or out does no reference counting on the audio thread.
public final class SPSCQueue<Element: BitwiseCopyable>: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Element>
    // Monotonic counts; slot = count % capacity.
    private let head = Atomic<Int>(0) // next to pop, stored by the consumer
    private let tail = Atomic<Int>(0) // next to push, stored by the producer

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Adds a value; false (and nothing added) when the queue is full.
    /// Producer only.
    @discardableResult
    public func push(_ value: Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        guard t - head.load(ordering: .acquiring) < capacity else { return false }
        (storage + t % capacity).initialize(to: value)
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// The oldest value, or nil when the queue is empty. Consumer only.
    public func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        guard h < tail.load(ordering: .acquiring) else { return nil }
        let value = (storage + h % capacity).move()
        head.store(h + 1, ordering: .releasing)
        return value
    }
}
