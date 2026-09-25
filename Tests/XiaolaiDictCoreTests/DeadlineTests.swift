import XiaolaiDictBase
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

    /// The bound is deliberately loose, and loosening it costs nothing. The work here **never
    /// finishes**, so a guard that waited for it would hang for ever and this test would time out
    /// rather than fail an assertion — the bound only rules out "absurdly slow". A tight bound
    /// measures how busy the machine is instead, which is how this failed while a build and a
    /// nine-minute suite were running beside it.
    @Test func workThatNeverAnswersIsAbandonedAtTheDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(200)) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
        #expect(clock.now - started < .seconds(10), "the guard waited for the abandoned work")
    }

    /// A caller that gives up must get its answer now — not when the work or the deadline, which
    /// may be seconds away, finally settles.
    /// The deadline is a minute and the bound ten seconds, so the gap between "answered on
    /// cancellation" and "waited for the deadline" is six-fold rather than five-fold — sharper than
    /// a 10 s deadline against a 2 s bound, *and* far harder for a loaded machine to blur.
    @Test func aCancelledCallerIsAnsweredAtOnce() async {
        let clock = ContinuousClock()
        let started = clock.now
        let caller = Task {
            try await withDeadline(.seconds(60)) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(clock.now - started < .seconds(10), "cancellation waited for the deadline")
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
