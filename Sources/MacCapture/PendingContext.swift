import XiaolaiDictBase

/// **The rest of a reading that is still being read.** A pixel read answers with the first strip's word at once, so the
/// card need not wait up to `ContextStrip.growthBudget` for the sentence around it; where that sentence ran into the
/// strip's edge, a taller strip goes on being read, and this is what it settles to.
///
/// `settled()` is the selection the taller strip read — the same word, a longer sentence — or nil where the first
/// reading stands: nothing grew, a taller read failed, the budget ran out, or the wait was given up. **Cancelling the
/// caller cancels the reading**, so a lookup the reader moved on from stops being read for, and the capture it holds is
/// let go as soon as the read in flight ends.
public final class PendingContext: Sendable {
    private let reading: Task<Selection?, Never>

    /// A context settled by `work`, started now.
    public init(_ work: @escaping @Sendable () async -> Selection?) {
        reading = Task { await work() }
    }

    /// The selection the context settled on, or nil where the first reading stands. Answers nil at once if the caller
    /// is cancelled, and cancels the reading.
    public func settled() async -> Selection? {
        await value(of: reading, orOnCancel: { nil })
    }

    /// Stops reading: a lookup nobody will show this context for.
    public func cancel() { reading.cancel() }
}
