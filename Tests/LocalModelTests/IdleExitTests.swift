@testable import LocalModel
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// Unloading is ending the service, so when it ends is the whole of the lifecycle.
struct IdleExitTests {
    @Test func itFiresOnceTheIntervalHasPassedWithNothingInFlight() {
        let fired = Recorder(0)
        let idle = IdleExit(after: .seconds(60)) { fired.withLock { $0 += 1 } }
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(59))))
        #expect(idle.fireIfIdle(at: .now.advanced(by: .seconds(61))))
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(120))), "fired twice")
        #expect(fired.withLock { $0 } == 1)
    }

    /// A long answer is not idleness: nothing fires while a request is in flight, however long it
    /// has been since it began — and the interval starts again when it ends.
    @Test func itNeverFiresWhileARequestIsInFlight() throws {
        let fired = Recorder(0)
        let idle = IdleExit(after: .seconds(60)) { fired.withLock { $0 += 1 } }
        let lease = try #require(idle.admit())
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(600))))
        lease.release()
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(59))), "the interval did not restart at the end")
        #expect(idle.fireIfIdle(at: .now.advanced(by: .seconds(61))))
    }

    /// **Once it has decided to end, it admits nothing.** A request let in between the decision and
    /// the exit is one the process will not live to answer.
    @Test func nothingIsAdmittedAfterItDecidesToEnd() {
        let idle = IdleExit(after: .seconds(60)) {}
        #expect(idle.fireIfIdle(at: .now.advanced(by: .seconds(61))))
        #expect(idle.isDraining)
        #expect(idle.admit() == nil, "a request was admitted into a service that was ending")
    }

    /// Draining closes admission **first**, then waits: a request admitted while it waited would be
    /// killed by the exit that follows, with its caller left waiting out a deadline.
    @Test func drainingStopsAdmittingBeforeItWaits() async throws {
        let idle = IdleExit(after: .seconds(60)) {}
        let lease = try #require(idle.admit())
        async let drained = idle.drain(within: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(idle.admit() == nil, "a request was admitted while the service was draining")
        lease.release()
        #expect(await drained)
    }

    /// While a request is in flight the watch sleeps a whole interval rather than polling: the
    /// earliest the process can end is that long after the request finishes.
    @Test func theWatchDoesNotPollWhileARequestRuns() throws {
        let idle = IdleExit(after: .seconds(60)) {}
        let now = ContinuousClock.now
        let lease = try #require(idle.admit())
        #expect(idle.nextCheck(from: now) == now.advanced(by: .seconds(60)))
        lease.release()
    }

    /// The watch itself, on a real clock: a short interval with nothing asked ends it — and starting
    /// it twice is one watch, not two.
    @Test func theWatchFiresOnItsOwnAndStartsOnce() async throws {
        let fired = Recorder(0)
        let idle = IdleExit(after: .milliseconds(100)) { fired.withLock { $0 += 1 } }
        idle.start()
        idle.start()
        for _ in 0..<50 where fired.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fired.withLock { $0 } == 1)
    }

    /// A request is counted in before its work is scheduled, and released once however it ends —
    /// the gap between the two is a gap the watch could exit in.
    @Test func aLeaseCountsFromAdmissionAndReleasesOnce() throws {
        let fired = Recorder(0)
        let idle = IdleExit(after: .seconds(60)) { fired.withLock { $0 += 1 } }
        let lease = try #require(idle.admit())
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(600))))
        lease.release()
        lease.release()
        #expect(!idle.fireIfIdle(at: .now.advanced(by: .seconds(59))))
        #expect(idle.fireIfIdle(at: .now.advanced(by: .seconds(61))))
        #expect(fired.withLock { $0 } == 1)
    }

    /// Unloading waits for what is in flight: exiting over a running generation kills it without an
    /// answer, and its caller waits out a deadline for a reply that never comes.
    @Test func drainingWaitsForWhatIsRunning() async throws {
        let idle = IdleExit(after: .seconds(60)) {}
        let lease = try #require(idle.admit())
        #expect(await idle.drain(within: .milliseconds(100)) == false)
        lease.release()
        #expect(await idle.drain(within: .seconds(1)))
    }

    @Test func theIntervalDefaultsToTenMinutesAndIsClamped() {
        #expect(IdleExit.interval(appDomain: "xiaolaidict.test.no-such-domain") == .seconds(600))
        #expect(ModelIdle.seconds(configured: nil) == 600)
        #expect(ModelIdle.seconds(configured: 20) == 20)
        #expect(ModelIdle.seconds(configured: 1) == 10, "an interval that would unload between two questions")
        #expect(ModelIdle.seconds(configured: 86_400) == 3_600, "an interval that would keep gigabytes all day")
    }
}
