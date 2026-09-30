import Synchronization

/// One continuation, resumed **exactly once** however many paths reach it.
///
/// A `CheckedContinuation` resumed twice is an unconditional crash — "SWIFT TASK CONTINUATION MISUSE",
/// and it ends the process rather than throwing — and one never resumed is a hang. So anywhere two paths
/// can answer, the first has to win and the second has to be a no-op, in a way that does not depend on
/// reading someone else's documentation correctly.
///
/// `DeadlineRace` keeps the same rule, and `ModelStore`'s `RangeWriter` a third time. Both have extra
/// duties settled under the same lock — tasks to cancel, a file handle to close — which is why they are
/// not this and are left alone. This is the bare rule, for a caller with nothing else to tidy.
public final class OneShot<T: Sendable, Failure: Error>: Sendable {
    private let held: Mutex<CheckedContinuation<T, Failure>?>

    public init(_ continuation: CheckedContinuation<T, Failure>) {
        held = Mutex(continuation)
    }

    /// The first call answers the caller; every later one is dropped.
    public func resume(with result: Result<T, Failure>) {
        // Taken out under the lock and resumed outside it. Resuming runs the caller's continuation, and
        // doing that while holding a lock is how a caller that comes straight back deadlocks.
        let taken = held.withLock { continuation -> CheckedContinuation<T, Failure>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(with: result)
    }

    /// Whether the caller has been answered. For a test; nothing in the app needs to ask.
    public var hasResumed: Bool { held.withLock { $0 == nil } }
}
