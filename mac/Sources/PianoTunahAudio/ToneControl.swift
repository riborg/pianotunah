import Synchronization

/// What the reference tone's render callback owns, and how the UI reaches
/// it: a ``ToneSynth``, an ``SPSCQueue`` for plucks, and the sine's state.
///
/// The sine is not a queued command but a value the render side reads at
/// the start of every block: on at a frequency, or off. Setting it cannot
/// fail, so a stop is never lost to a full queue and the tone never goes on
/// while the player says it stopped (and the ``ReferenceGate`` opens).
/// Plucks may be dropped when the queue is full; ``pluck(f1:b:)`` says so.
///
/// Threads: one producer calls ``pluck(f1:b:)`` and ``setSine(_:)`` (the
/// main actor), one consumer calls ``render(into:)`` (the audio thread).
/// Neither allocates or locks.
final class ToneControl: @unchecked Sendable {
    let synth: ToneSynth
    private let commands: SPSCQueue<ToneSynth.Command>
    // The sine's frequency as Double bits, 0 when off: stored by the
    // producer, read by the consumer.
    private let sine = Atomic<UInt64>(0)
    // What the synth was last told, in the same encoding. Consumer only; an
    // atomic so the audio thread does no exclusivity checks.
    private let applied = Atomic<UInt64>(0)

    init(sampleRate: Double, queueCapacity: Int = 64) {
        synth = ToneSynth(sampleRate: sampleRate)
        commands = SPSCQueue(capacity: queueCapacity)
    }

    // MARK: Producer

    /// Queues a pluck; false when the queue is full and it was dropped.
    @discardableResult
    func pluck(f1: Double, b: Double) -> Bool {
        commands.push(.pluck(f1: f1, b: b))
    }

    /// The sine at `hz`, or off for nil. A new frequency while it is on is
    /// approached with τ = 10 ms. A frequency that is not positive and
    /// finite counts as off.
    func setSine(_ hz: Double?) {
        let bits = hz.map { $0 > 0 && $0.isFinite ? $0.bitPattern : 0 } ?? 0
        sine.store(bits, ordering: .releasing)
    }

    // MARK: Consumer

    /// Brings the synth up to date (the sine's state, then the queued
    /// plucks) and renders `out`. Returns false if it is all silence.
    @discardableResult
    func render(into out: UnsafeMutableBufferPointer<Float>) -> Bool {
        let want = sine.load(ordering: .acquiring)
        let had = applied.load(ordering: .relaxed)
        if want != had {
            if want == 0 {
                synth.apply(.stopSine)
            } else if had == 0 {
                synth.apply(.startSine(Double(bitPattern: want)))
            } else {
                synth.apply(.setSine(Double(bitPattern: want)))
            }
            applied.store(want, ordering: .relaxed)
        }
        while let command = commands.pop() { synth.apply(command) }
        return synth.render(into: out)
    }
}
