import Synchronization

/// One continuation, resumed by whichever answer comes first — the work's or the cancellation's.
/// Either may arrive before the continuation is installed.
public final class FirstAnswer<T: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<T, Never>?, answer: T?, resumed: Bool)>((nil, nil, false))

    public init() {}

    public func install(_ continuation: CheckedContinuation<T, Never>) {
        let early = state.withLock { state -> T? in
            guard let answer = state.answer, !state.resumed else { state.continuation = continuation; return nil }
            state.resumed = true
            return answer
        }
        if let early { continuation.resume(returning: early) }
    }

    public func give(_ value: T) {
        let waiting = state.withLock { state -> CheckedContinuation<T, Never>? in
            guard !state.resumed, state.answer == nil else { return nil }
            guard let continuation = state.continuation else { state.answer = value; return nil }
            state.resumed = true
            state.continuation = nil
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

/// `task`'s value — **or `fallback` the moment the caller is cancelled**. `await task.value` cannot be
/// given up on: cancelling the caller does not reach an unstructured task, and the caller waited for
/// it anyway. The task is cancelled and left to finish on its own.
///
/// `watching` runs once the cancellation handler is in place — the moment from which a cancellation is
/// certain to reach `fallback`. Work that must not start before then waits for it.
public func value<T: Sendable>(
    of task: Task<T, Never>, orOnCancel fallback: @escaping @Sendable () -> T,
    watching: @Sendable () -> Void = {}
) async -> T {
    let answer = FirstAnswer<T>()
    return await withTaskCancellationHandler {
        watching()
        return await withCheckedContinuation { continuation in
            answer.install(continuation)
            Task.detached { answer.give(await task.value) }
        }
    } onCancel: {
        // The caller's answer first: cancelling the task can run its own handlers synchronously,
        // and they must not get to answer — or delay the answer — before the caller is let go.
        answer.give(fallback())
        task.cancel()
    }
}
