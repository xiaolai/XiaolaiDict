import Synchronization

public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let duration: Duration
    public var description: String { "no answer within \(duration)" }
}

/// Runs `work`, and gives up on it if it has not answered within `duration` of this call — or at
/// once, with `CancellationError`, if the caller is cancelled.
///
/// Deliberately not a task group: a group waits for every child before it returns, so work that
/// never answers — a continuation that is never resumed, which is how a wedged system call looks
/// from Swift — would hang the guard as well. Here the loser is cancelled but not awaited: work
/// that honours cancellation stops, and work that cannot is left behind while the caller still
/// gets its answer on time.
public func withDeadline<T: Sendable>(
    _ duration: Duration, _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    // Taken before either task exists, so scheduling delay cannot stretch the deadline.
    let deadline = ContinuousClock.now.advanced(by: duration)
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.adopt([
                Task {
                    do { race.settle(.success(try await work())) } catch { race.settle(.failure(error)) }
                },
                Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }  // work won
                    race.settle(.failure(DeadlineExceeded(duration: duration)))
                },
            ])
        }
    } onCancel: {
        race.settle(.failure(CancellationError()))
    }
}

/// The work, the timer and caller cancellation race to settle one continuation. The first outcome
/// wins; whatever arrives later finds it taken. Every path is safe in any order — cancellation can
/// arrive before the continuation is installed, and a task can finish before it is adopted.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var outcome: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let settled: Result<T, any Error>? = state.withLock { state in
            if state.outcome == nil { state.continuation = continuation }
            return state.outcome
        }
        if let settled { continuation.resume(with: settled) }
    }

    func adopt(_ tasks: [Task<Void, Never>]) {
        let late: Bool = state.withLock { state in
            if state.outcome == nil { state.tasks = tasks }
            return state.outcome != nil
        }
        if late { tasks.forEach { $0.cancel() } }
    }

    func settle(_ result: Result<T, any Error>) {
        let won: (CheckedContinuation<T, any Error>?, [Task<Void, Never>])? = state.withLock { state in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        guard let (continuation, tasks) = won else { return }
        continuation?.resume(with: result)
        // The losers: the timer when the work answered, the work when the timer or the caller won.
        tasks.forEach { $0.cancel() }
    }
}
