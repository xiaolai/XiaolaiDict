import Foundation

/// What the queue has, split by whether the reader may be asked it today.
public struct QueueCounts: Sendable, Equatable {
    /// Askable now, with the allowance already applied.
    public let due: Int
    /// New cards the daily allowance is holding for a later day. **Not a backlog** — nothing is late
    /// — but not nothing either, and a surface that reports zero over eight of them is why a reader
    /// would conclude their saved words went missing.
    public let heldBack: Int

    public init(due: Int, heldBack: Int) {
        self.due = due
        self.heldBack = heldBack
    }
}
