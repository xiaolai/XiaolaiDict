import XiaolaiDictBase
import Synchronization
import Testing
import XiaolaiDictTestSupport

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

    /// **No clock is read here.** The work **never finishes**, so a guard that waited for it would
    /// hang for ever; that hang is the failure, and the framework's own time limit (minute
    /// granularity, far beyond any scheduling stall) is what turns it into one. This asserted
    /// `clock.now - started < .seconds(10)` before, and failed twice while other builds loaded the
    /// machine (load average 14–17): a unit test may not assert elapsed wall-clock time against an
    /// absolute bound (AGENTS.md), and a ten-second bound measures how busy the machine is.
    @Test(.timeLimit(.minutes(1)))
    func workThatNeverAnswersIsAbandonedAtTheDeadline() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(200)) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
    }

    /// A caller that gives up must get its answer now — not when the work or the deadline, which
    /// may be minutes away, finally settles. The deadline is **`Patience.never`**, longer than the time limit:
    /// a guard that answered a cancelled caller only at the deadline would still be waiting when the
    /// framework ends the test, so the failure is structural and no stopwatch is involved.
    @Test(.timeLimit(.minutes(2)))
    func aCancelledCallerIsAnsweredAtOnce() async {
        let caller = Task {
            try await withDeadline(Patience.never) { () async -> Int in
                await withUnsafeContinuation { _ in }  // never resumed
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    @Test func aCallerCancelledBeforeItStartsIsAnsweredAtOnce() async {
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(Patience.never) { () async -> Int in
                await withUnsafeContinuation { _ in }
            }
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
    }

    /// Work that honours cancellation is told to stop once the deadline has passed, rather than
    /// being left to run on unobserved.
    ///
    /// **The test waits for the work to say what happened, never for a duration.** It polled for
    /// one second (`for _ in 0..<100 … sleep(10 ms)`) and failed under load, the same defect as the
    /// stopwatch asserts above: a poll bound measures how busy the machine is. Now the work closes a
    /// stream on every exit (cancelled, or finished if nobody cancelled it), and the test reads the
    /// stream to its end, so it ends when the work has *answered* and the verdict is only whether it
    /// was cancelled.
    ///
    /// **And the work runs for `Patience.never`, longer than the test's limit, not for ten seconds.** Ten
    /// seconds was itself a stopwatch: on 2026-10-10, in a full suite whose every test in this target
    /// reported 13.7 s, the guard threw `DeadlineExceeded` as it should and yet the work ran out its
    /// ten seconds uncancelled — which only a timer starved of its thread for that long explains
    /// (inferred; nothing measured the timer). Now work nobody cancels outlives the test, and the
    /// framework's limit is the failure.
    @Test(.timeLimit(.minutes(2)))
    func workThatOverrunsIsCancelled() async throws {
        let stopped = Mutex(false)
        let (exits, exit) = AsyncStream<Void>.makeStream()
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(100)) { () async throws -> Int in
                do {
                    try await Task.sleep(for: Patience.never)
                } catch {
                    stopped.withLock { $0 = true }
                    exit.finish()
                    throw error
                }
                exit.finish()
                return 0
            }
        }
        for await _ in exits {}  // ends when the work has exited, by cancellation or by finishing
        #expect(stopped.withLock { $0 }, "the overrunning work was never cancelled")
    }
}
