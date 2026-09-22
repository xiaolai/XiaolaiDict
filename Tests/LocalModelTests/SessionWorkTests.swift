import Foundation
@testable import LocalModel
import Testing
import XiaolaiDictTestSupport

/// One session's work, made and tracked under the same lock — so there is no moment where work is
/// running that the session does not know about.
struct SessionWorkTests {
    private func waiting(_ cancelled: Recorder<Bool>) -> @Sendable () async -> Void {
        { await withTaskCancellationHandler {
            try? await Task.sleep(for: .seconds(10))
        } onCancel: { cancelled.withLock { $0 = true } } }
    }

    /// Work asked for after the client has gone never starts.
    @Test func nothingStartsAfterTheSessionCloses() async {
        let session = SessionWork()
        session.close()
        let started = Recorder(false)
        #expect(!session.run { started.withLock { $0 = true } })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!started.withLock { $0 }, "work started for a client that had gone")
        #expect(session.isClosed)
    }

    /// Work running when the client goes is cancelled with it, and the session keeps nothing.
    @Test func closingCancelsWhatIsRunning() async {
        let session = SessionWork()
        let cancelled = Recorder(false)
        #expect(session.run(waiting(cancelled)))
        session.close()
        for _ in 0..<100 where !cancelled.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(cancelled.withLock { $0 })
        #expect(session.runningCount == 0)
    }

    /// **One session's cancellation is not another's.** A client that quits takes its own
    /// generations with it and leaves everyone else's alone.
    @Test func closingOneSessionLeavesAnothersWorkRunning() async {
        let mine = SessionWork(), theirs = SessionWork()
        let mineCancelled = Recorder(false), theirsCancelled = Recorder(false)
        #expect(mine.run(waiting(mineCancelled)))
        #expect(theirs.run(waiting(theirsCancelled)))

        mine.close()
        for _ in 0..<100 where !mineCancelled.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(mineCancelled.withLock { $0 })
        #expect(!theirsCancelled.withLock { $0 }, "another client's work was cancelled with this one")
        #expect(!theirs.isClosed)
        theirs.close()
    }

    /// Finished work is forgotten: a long session must not accumulate a record per request.
    @Test func finishedWorkIsNotKept() async throws {
        let session = SessionWork()
        for _ in 0..<5 { #expect(session.run {}) }
        for _ in 0..<200 where session.runningCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.runningCount == 0)
    }
}
