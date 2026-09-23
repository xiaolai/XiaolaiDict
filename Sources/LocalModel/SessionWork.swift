import Foundation
import Synchronization

/// The requests of **one** XPC session, and whether that session has gone.
///
/// Per session, not per process: a cancellation says the client on the other end of *that* session
/// has gone, and cancelling everything running for every other one would take work away from callers
/// still waiting for it.
///
/// **The work is made here, under the lock that records it.** A task created by the caller and handed
/// over afterwards can run — or finish — in the gap between, which is how work outlived a closed
/// session and how a registry came to hold entries nothing would ever remove.
public final class SessionWork: Sendable {
    private struct State {
        var running: [Int: Task<Void, Never>] = [:]
        var next = 0
        var closed = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Runs one request's work, tracked for as long as it runs. Answers false — and starts nothing —
    /// when the client has already gone.
    @discardableResult
    public func run(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.next += 1
            let id = state.next
            state.running[id] = Task { [weak self] in
                await operation()
                self?.state.withLock { $0.running[id] = nil }
            }
            return true
        }
    }

    /// The client has gone: everything running for it is running for nobody.
    public func close() {
        let running = state.withLock { state -> [Task<Void, Never>] in
            state.closed = true
            defer { state.running.removeAll() }
            return Array(state.running.values)
        }
        for task in running { task.cancel() }
    }

    public var isClosed: Bool { state.withLock { $0.closed } }
    /// How many of this session's requests are still running. For tests.
    var runningCount: Int { state.withLock { $0.running.count } }
}
