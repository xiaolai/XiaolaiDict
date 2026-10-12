import Foundation
import XiaolaiDictBase
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// Synchronous work that nothing can interrupt — a private API that deadlocked — is bounded by
/// acting from outside it.
struct WatchdogTests {
    /// **Read only where the work did finish in time.** The limit is the subject, so it is short — and a run of
    /// `{ 42 }` held off its thread past it, as a loaded Mac can, *is* work that overran: the alarm firing then is the
    /// watchdog working. So the run is timed from outside, which can only over-count, and one that took the limit or
    /// more is run again, within `Patience`. Only a run that kept to it is read, and its alarm must stay silent.
    @Test func workThatFinishesInTimeNeverTriggersIt() async throws {
        var fired = true
        let measured = await Patience.until {
            let alarm = Mutex(false)
            let watchdog = Watchdog(limit: .milliseconds(100)) { alarm.withLock { $0 = true } }
            let started = ContinuousClock.now
            #expect(watchdog.run { 42 } == 42)
            let took = ContinuousClock.now - started
            try? await Task.sleep(for: watchdog.limit * 3)
            guard took < watchdog.limit else { return false }
            fired = alarm.withLock { $0 }
            return true
        }
        #expect(measured, "no run of the work kept to the limit, so nothing was measured")
        #expect(!fired, "the alarm outlived the work it guarded")
    }

    /// **The stuck work waits on the alarm rather than polling for it**, and the wait is long.
    ///
    /// The alarm is scheduled with `DispatchQueue.global(qos: .utility).asyncAfter`, so it runs on
    /// the global pool — and this test blocks a pooled thread on purpose, because being stuck is
    /// the condition under test. Polling for the flag in a `Thread.sleep(0.01)` loop made that
    /// worse twice over: it held the thread *and* woke a hundred times a second, and under a
    /// parallel run on a loaded machine the pool was saturated enough that a 100 ms alarm did not
    /// run inside the 5 s the loop allowed. Observed 2026-09-27 in a full run whose last target
    /// took 102 s; the same test passes in 0.1 s alone.
    ///
    /// A semaphore removes the spin, and the bound is wide because it is guarding against the test
    /// hanging for ever, not measuring the watchdog's latency — this project's rule is that a unit
    /// test may not assert wall-clock time against an absolute bound, since an upper bound
    /// measures how many other tests the runner is executing.
    @Test func workThatOverrunsTriggersItWhileStillStuck() {
        let fired = Mutex(false)
        let alarm = DispatchSemaphore(value: 0)
        let watchdog = Watchdog(limit: .milliseconds(100)) {
            fired.withLock { $0 = true }
            alarm.signal()
        }
        watchdog.run {
            // Stuck until the alarm has gone off — as a deadlocked call would stay stuck.
            _ = alarm.wait(timeout: .now() + Patience.wait / .seconds(1))
        }
        #expect(fired.withLock { $0 })
    }

    @Test func anErrorPassesThrough() {
        struct Boom: Error, Equatable {}
        let watchdog = Watchdog(limit: Patience.wait) {}
        #expect(throws: Boom()) { try watchdog.run { throw Boom() } }
    }
}
