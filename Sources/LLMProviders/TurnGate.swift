import os

/// **One question at a time, first come first served, and a caller who gives up leaves the queue.**
///
/// A resident CLI answers one turn at a time, and a second question written before the first's answer is read would
/// be answered as the first. An actor does not serialise this by itself: it is re-entered at every `await`, and a turn
/// is nothing but awaits. So the session holds this gate for a whole turn.
///
/// A waiter that is cancelled is resumed at once and taken out of the queue — hover makes cancellations constantly,
/// and a reader who moved on must not wait behind a slow answer to learn that their question was dropped.
final class TurnGate: Sendable {
    private struct State {
        var held = false
        var waiters: [(id: UInt64, admit: CheckedContinuation<Bool, Never>)] = []
        var issued: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Waits for the gate, and holds it. **Throws `.cancelled`** for a caller that gives up first, which then holds
    /// nothing and must not `leave()`.
    func enter() async throws(ProviderFailure) {
        let id = state.withLock { state -> UInt64 in
            state.issued += 1
            return state.issued
        }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (admit: CheckedContinuation<Bool, Never>) in
                let now: Bool? = state.withLock { state in
                    // Asked under the lock: a cancellation that came before this, whose handler found no waiter to
                    // remove, is seen here instead — so a cancelled caller is never queued.
                    if Task.isCancelled { return false }
                    if !state.held {
                        state.held = true
                        return true
                    }
                    state.waiters.append((id, admit))
                    return nil
                }
                if let now { admit.resume(returning: now) }
            }
        } onCancel: {
            let removed = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).admit
            }
            removed?.resume(returning: false)
        }
        guard admitted else { throw .cancelled }
    }

    /// Lets the gate go: to the next waiter, which then holds it, or open.
    func leave() {
        let next = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst().admit
        }
        next?.resume(returning: true)
    }
}
