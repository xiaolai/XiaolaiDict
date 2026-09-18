import Foundation
import XiaolaiDictCore
import Synchronization
import Testing

/// Synchronous work that nothing can interrupt — a private API that deadlocked — is bounded by
/// acting from outside it.
struct WatchdogTests {
    @Test func workThatFinishesInTimeNeverTriggersIt() async throws {
        let fired = Mutex(false)
        let watchdog = Watchdog(limit: .milliseconds(100)) { fired.withLock { $0 = true } }
        #expect(watchdog.run { 42 } == 42)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fired.withLock { $0 }, "the alarm outlived the work it guarded")
    }

    @Test func workThatOverrunsTriggersItWhileStillStuck() {
        let fired = Mutex(false)
        let watchdog = Watchdog(limit: .milliseconds(100)) { fired.withLock { $0 = true } }
        watchdog.run {
            // Stuck until the alarm has gone off — as a deadlocked call would stay stuck.
            let deadline = Date.now.addingTimeInterval(5)
            while !fired.withLock({ $0 }), Date.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(fired.withLock { $0 })
    }

    @Test func anErrorPassesThrough() {
        struct Boom: Error, Equatable {}
        let watchdog = Watchdog(limit: .seconds(5)) {}
        #expect(throws: Boom()) { try watchdog.run { throw Boom() } }
    }
}
