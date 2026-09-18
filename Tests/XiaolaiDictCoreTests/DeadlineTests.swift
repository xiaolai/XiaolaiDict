import XiaolaiDictCore
import Synchronization
import Testing

/// A deadline that gives up on work that never answers. The spike found the case that matters: a
/// continuation that is never resumed. A task group cannot bound that — it waits for every child
/// before returning — so the guard must not be one.
struct DeadlineTests {
    @Test func workThatFinishesInTimeReturnsItsValue() async throws {
        #expect(try await withDeadline(.seconds(2)) { 42 } == 42)
    }

    @Test func workThatThrowsPassesItsErrorThrough() async {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) { try await withDeadline(.seconds(2)) { () async throws -> Int in throw Boom() } }
    }

    @Test func workThatNeverAnswersIsAbandonedAtTheDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(200)) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
        #expect(clock.now - started < .seconds(2), "the guard waited for the abandoned work")
    }

    /// A caller that gives up must get its answer now — not when the work or the deadline, which
    /// may be seconds away, finally settles.
    @Test func aCancelledCallerIsAnsweredAtOnce() async {
        let clock = ContinuousClock()
        let started = clock.now
        let caller = Task {
            try await withDeadline(.seconds(10)) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(clock.now - started < .seconds(2), "cancellation waited for the deadline")
    }

    @Test func aCallerCancelledBeforeItStartsIsAnsweredAtOnce() async {
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(.seconds(10)) { () async -> Int in
                await withUnsafeContinuation { _ in }
            }
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    /// Work that honours cancellation is told to stop once the deadline has passed, rather than
    /// being left to run on unobserved.
    @Test func workThatOverrunsIsCancelled() async throws {
        let stopped = Mutex(false)
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(100)) { () async throws -> Int in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    stopped.withLock { $0 = true }
                    throw error
                }
                return 0
            }
        }
        for _ in 0..<100 where !stopped.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped.withLock { $0 }, "the overrunning work was never cancelled")
    }
}
