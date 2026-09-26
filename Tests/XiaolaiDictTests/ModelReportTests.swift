import Foundation
import ModelKit
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictCore
import XiaolaiDictTestSupport

/// `--model-report`'s idle watch, on a clock its own polls move.
///
/// The watch has six outcomes, and every one of them was reachable only by running the instrument
/// inside the signed bundle on the end-to-end Mac against a service whose interval had been
/// shortened to 20 s — one outcome per run, minutes each, and the four failure branches never
/// taken at all. Nothing here opens a service or waits for a second: the fake sleep advances the
/// fake clock, which is what makes a 50-second wait a few hundred iterations of arithmetic.
@MainActor
struct ModelReportIdleWatchTests {
    /// What the watch sees of the world: a clock that only moves when the watch sleeps, a service
    /// process that disappears at a chosen point on that clock, and a script of status answers.
    @MainActor
    final class World {
        var idleSeconds = 20
        /// How far the watch's own polls have moved the clock.
        var elapsed: Duration = .zero
        /// When the service's process goes, on that same clock. Where this is nil it never goes.
        var goesAfter: Duration?
        /// When the process scan stops being readable, on that same clock — `proc_listallpids`
        /// answering nothing, which is a reading the watch could not take rather than a process it
        /// saw go. Where this is nil every scan answers.
        var scanStopsAnsweringAfter: Duration?
        /// One answer per status question, in order. A question past the end of the script comes
        /// back empty, which is how a service that never answers again is written.
        var statuses: [ModelServiceStatus?] = []
        var statusQuestions = 0
        /// Run just before each status answer, given that question's number — where a test needs
        /// the caller to give up in the middle of one.
        var beforeAnswering: @MainActor (Int) -> Void = { _ in }
        /// Thrown by every sleep: the run that was stopped rather than finished.
        var sleepThrows: (any Error)?

        private let base = ContinuousClock.now

        var watch: ModelReport.IdleWatch {
            ModelReport.IdleWatch(
                idleSeconds: { self.idleSeconds },
                servicePresence: {
                    if let blind = self.scanStopsAnsweringAfter, self.elapsed >= blind { return .couldNotTell }
                    guard let goesAfter = self.goesAfter else { return .running }
                    return self.elapsed < goesAfter ? .running : .gone
                },
                now: { self.base.advanced(by: self.elapsed) },
                sleep: { duration in
                    if let error = self.sleepThrows { throw error }
                    self.elapsed += duration
                },
                status: {
                    self.statusQuestions += 1
                    self.beforeAnswering(self.statusQuestions)
                    return self.statuses.isEmpty ? nil : self.statuses.removeFirst()
                })
        }
    }

    private static let footprintMB: UInt64 = 180

    private static func status(loaded: Bool) -> ModelServiceStatus {
        ModelServiceStatus(
            installed: .standard, loaded: loaded, gpu: "one op evaluated",
            footprint: footprintMB * 1_048_576, availableMemory: 24 * 1_073_741_824)
    }

    /// A service that goes fractionally before its own interval — the poll and the service's own
    /// timer land on either side of the same boundary, which is why the crash test below is a
    /// share of the interval and not equality with it.
    private static let wentAfter = Duration.seconds(19.75)

    /// The shipped ten minutes is longer than a report is held open for, so the watch says it did
    /// not watch one. **Skipped is not a pass** — the end-to-end gate asks for `observed` — and a
    /// watch that skipped must not have asked the service anything either, or the report carries
    /// answers from questions it never counted.
    @Test func theShippedIntervalIsSkippedRatherThanQuietlyPassed() async throws {
        let world = World()
        world.idleSeconds = ModelIdle.defaultSeconds
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .skipped)
        #expect(report["unloadWatch"] as? String == "skipped")
        #expect(report["idleSeconds"] as? Int == ModelIdle.defaultSeconds)
        #expect(world.statusQuestions == 0, "a skipped watch still asked the service something")
    }

    /// The one outcome the gate accepts: the process went on its own interval, and the next
    /// question brought back a service holding nothing.
    @Test func aServiceThatGoesOnItsOwnIntervalAndComesBackEmptyIsObserved() async throws {
        let world = World()
        world.goesAfter = Self.wentAfter
        world.statuses = [Self.status(loaded: false)]
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .observed)
        #expect(report["unloadWatch"] as? String == "observed")
        #expect(report["relaunched"] as? Bool == true)
        let waited: Double = 19.75
        #expect(report["unloadedAfterSeconds"] as? Double == waited)
        #expect(report["footprintAfterUnloadMB"] as? UInt64 == Self.footprintMB)
    }

    /// Still there after the interval *and* the grace: the idle timer did not fire, which is the
    /// failure the instrument exists to catch. It must say so in words, because the harness reads
    /// the line and a bare `failed` would not distinguish this from the three below.
    @Test func aServiceStillRunningPastTheIntervalAndTheGraceIsAFailure() async throws {
        let world = World()
        world.goesAfter = nil
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .failed)
        #expect(report["unloadWatch"] as? String == "failed")
        #expect((report["unload"] as? String)?.contains("still running") == true)
        // It waited the whole interval and the whole grace before saying so.
        let atLeast: Duration = .seconds(world.idleSeconds) + ModelReport.unloadGrace
        #expect(world.elapsed >= atLeast)
        #expect(world.statusQuestions == 0, "a service that never went was asked to prove it came back")
    }

    /// **A scan that could not tell is not a process that went.** The service here is running the
    /// whole time; the only thing that changes at 19.75 s is that the scan stops answering — which
    /// read as "not running" ended the wait, looked like an interval fully served, and filed an
    /// unload nobody had seen. It is a failure, it waits the whole interval and grace first in
    /// case the scan comes back, and it says which failure it is: the watch made no claim about
    /// the process, so it must not print one.
    @Test func aScanThatCouldNotTellIsNotFiledAsAnUnload() async throws {
        let world = World()
        world.goesAfter = nil
        world.scanStopsAnsweringAfter = Self.wentAfter
        world.statuses = [Self.status(loaded: false)]
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .failed)
        #expect(report["unloadWatch"] as? String == "failed")
        #expect((report["unload"] as? String)?.contains("could not tell") == true,
                "the report does not say the scan failed: \(report["unload"] ?? "nothing")")
        #expect(!report.keys.contains("unloadedAfterSeconds"),
                "a wait was timed against a process nothing had seen go")
        #expect(world.statusQuestions == 0, "an unreadable scan was asked whether the service came back")
        let atLeast: Duration = .seconds(world.idleSeconds) + ModelReport.unloadGrace
        #expect(world.elapsed >= atLeast, "the watch gave up on the first scan that would not answer")
    }

    /// **A service that went early did not idle out — it died.** Read as an unload, a crash on the
    /// first question reads as the feature working, which is the reading this share of the interval
    /// was added to refuse.
    @Test func aServiceThatGoesFarTooEarlyIsNamedACrashRatherThanAnUnload() async throws {
        let world = World()
        world.goesAfter = .seconds(1)
        world.statuses = [Self.status(loaded: false)]
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .failed)
        #expect((report["unload"] as? String)?.contains("crash") == true)
        let waited: Double = 1
        #expect(report["unloadedAfterSeconds"] as? Double == waited)
        #expect(world.statusQuestions == 0, "a crash was asked whether it had relaunched")
    }

    /// Nothing came back. Asked more than once on purpose — the session to the process that has
    /// gone may not have been invalidated yet, so the first question can fail on the stale one —
    /// but a bounded number of times, and then reported as no relaunch.
    @Test func aServiceThatNeverAnswersAgainIsFiledAsNoRelaunch() async throws {
        let world = World()
        world.goesAfter = Self.wentAfter
        world.statuses = []
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .failed)
        #expect(report["relaunched"] as? Bool == false)
        #expect(world.statusQuestions == ModelReport.relaunchTries)
    }

    /// A service came back **holding the model**. That is not an unload: the process that answered
    /// is either the one that was supposed to go or a new one that loaded on sight, and either way
    /// the memory the watch is here to see released was not released.
    @Test func aServiceThatComesBackStillHoldingTheModelIsAFailure() async throws {
        let world = World()
        world.goesAfter = Self.wentAfter
        world.statuses = [Self.status(loaded: true)]
        var report: [String: Any] = [:]
        let outcome = try await ModelReport.watchIdleUnload(world.watch, into: &report)
        #expect(outcome == .failed)
        #expect(report["unloadWatch"] as? String == "failed")
        #expect(!report.keys.contains("footprintAfterUnloadMB"),
                "a footprint was reported after an unload that was never seen")
        // **And it is not the same failure as nothing coming back.** A service that answered and
        // still held the model did relaunch; filed as `relaunched: false` it read as one launchd
        // never started, which is a different defect with a different cause.
        #expect(report["relaunched"] as? Bool == true,
                "a service that answered was reported as never having relaunched")
        #expect((report["unload"] as? String)?.contains("still holding the model") == true,
                "the report does not say what went wrong: \(report["unload"] ?? "nothing")")
    }

    /// **A run somebody stopped measured nothing, and is not a service that failed to unload.**
    /// The error goes up, so `run` maps it to `.interrupted`; swallowed, the wait ends early, the
    /// process is still there, and the watch files a failure against a service that was doing
    /// exactly what it was asked.
    @Test func aStoppedWaitGoesUpRatherThanBeingFiledAsAFailedUnload() async throws {
        let world = World()
        world.goesAfter = nil
        world.sleepThrows = CancellationError()
        var report: [String: Any] = [:]
        var thrown: (any Error)?
        do { _ = try await ModelReport.watchIdleUnload(world.watch, into: &report) } catch { thrown = error }
        #expect(thrown is CancellationError)
        #expect(!report.keys.contains("unloadWatch"), "a stopped run was still filed as a watch")
    }

    /// **`ModelClient.ask` answers nil when the *caller* was cancelled**, not only when the service
    /// was unreachable — so a stopped run made every try here come back empty, the tries ran out,
    /// and the watch reported a service that never relaunched: a failure recorded for a measurement
    /// nobody took. Cancelled on the last try, which is the one a check at the head of the loop
    /// cannot reach.
    @Test func aRunStoppedWhileAskingForTheFreshStatusIsNotFiledAsNoRelaunch() async throws {
        let world = World()
        world.goesAfter = Self.wentAfter
        world.statuses = []
        let running = Recorder<Task<ModelReport.UnloadWatch, any Error>?>(nil)
        world.beforeAnswering = { question in
            guard question == ModelReport.relaunchTries else { return }
            running.withLock { $0 }?.cancel()
        }
        let watching = Task { @MainActor () async throws -> ModelReport.UnloadWatch in
            var report: [String: Any] = [:]
            return try await ModelReport.watchIdleUnload(world.watch, into: &report)
        }
        running.withLock { $0 = watching }

        var thrown: (any Error)?
        do { _ = try await watching.value } catch { thrown = error }
        #expect(thrown is CancellationError)
    }
}
