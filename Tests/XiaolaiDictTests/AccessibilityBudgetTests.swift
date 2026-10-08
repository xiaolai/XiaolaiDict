import ApplicationServices
@testable import MacCapture
import Synchronization
import Testing
import XiaolaiDictBase

/// **Hover's Accessibility read is bounded, and stops at the first failure.**
///
/// It had a quarter-second timeout per request and nothing over the whole read, and it classified
/// no failure — a value it could not read was a value it did not have — so an app that stopped
/// answering was asked every remaining question: the web-area walk's forty parents twice and the
/// bounds scan's hundred and twenty words, a quarter second each. These count requests rather
/// than time them.
struct AccessibilityBudgetTests {
    /// Counts requests, answers each with `status`, and advances a fake clock by `step` per request.
    private final class Requests: Sendable {
        let made = Mutex(0)
        let status: AXError
        let step: Duration
        let origin = ContinuousClock.now
        let onRequest: @Sendable (Int) -> Void

        init(status: AXError = .noValue, step: Duration = .zero, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.status = status
            self.step = step
            self.onRequest = onRequest
        }

        var count: Int { made.withLock { $0 } }

        func now() -> ContinuousClock.Instant { origin + step * made.withLock { $0 } }

        /// How many times the app was asked to build its tree for an assistive client.
        let enhanced = Mutex(0)

        var client: AccessibilityRequests {
            AccessibilityRequests(
                attribute: { _, _ in self.answer() },
                parameterized: { _, _, _ in self.answer() },
                // Chrome's own answer, measured: "not implemented" — while building the tree anyway.
                enhance: { _ in self.enhanced.withLock { $0 += 1 }; return .notImplemented })
        }

        private func answer() -> (AXError, CFTypeRef?) {
            let made = made.withLock { $0 += 1; return $0 }
            onRequest(made)
            return (status, nil)
        }

        func session(budget: Duration) -> AccessibilitySession {
            AccessibilitySession(budget: budget, now: { self.now() }, requests: client)
        }
    }

    private static let target = HoverFixtures.target()
    private static let point = CGPoint(x: 10, y: 10)

    /// **The request after the budget is never made.** Each request costs 200 ms on the fake
    /// clock; against 500 ms the fourth is refused before it is sent. Red if `checkStillWanted`
    /// stops comparing against the deadline.
    @Test func theRequestAfterTheBudgetIsNeverMade() {
        let requests = Requests(step: .milliseconds(200))
        let outcome = ScreenWordReader.read(
            at: Self.point, in: Self.target, with: requests.session(budget: .milliseconds(500)))
        #expect(requests.count == 3, "made \(requests.count) requests against a three-request budget")
        guard case .miss(let why) = outcome, why.contains("deadlineExceeded") else {
            Issue.record("expected a miss for the budget, got \(outcome)")
            return
        }
    }

    /// **Nothing is asked after `.notResponding`.** One unanswered request ends the hover read —
    /// where the old reader went on to every dialect and every word. Red if a dialect catches the
    /// failure and moves on.
    @Test func nothingIsAskedAfterAnAppStopsAnswering() {
        let requests = Requests(status: .cannotComplete)
        let outcome = ScreenWordReader.read(
            at: Self.point, in: Self.target, with: requests.session(budget: .seconds(60)))
        #expect(requests.count == 1, "asked \(requests.count) times after the app stopped answering")
        guard case .miss(let why) = outcome, why.contains("notResponding") else {
            Issue.record("expected a miss naming the app, got \(outcome)")
            return
        }
    }

    /// **An absent value moves on; it does not end the read.** The control for the test above:
    /// without it a reader that stopped after one request for any reason would pass.
    @Test func anAbsentValueTriesTheNextDialect() {
        let requests = Requests(status: .noValue)
        _ = ScreenWordReader.read(at: Self.point, in: Self.target, with: requests.session(budget: .seconds(60)))
        #expect(requests.count > 3, "an absent value ended the read after \(requests.count) requests")
    }

    /// **An app that does not answer the wake-up is asked nothing else**, and is woken again next
    /// time rather than remembered as woken. Red if the wake-up's failure is ignored, or it is
    /// cached before it went through.
    @Test func anUnansweredWakeUpEndsTheReadAndIsTriedAgain() {
        let requests = Requests(status: .noValue)
        let wakes = Mutex(0)
        var client = requests.client
        client.wake = { _ in wakes.withLock { $0 += 1 }; return .cannotComplete }
        let target = ScreenWordReader.Target(element: AXUIElementCreateApplication(70_001), appName: "Hung", bundleID: "hung")
        let session = AccessibilitySession(budget: .seconds(60), now: { requests.now() }, requests: client)
        guard case .miss(let why) = ScreenWordReader.read(at: Self.point, in: target, with: session), why.contains("notResponding") else {
            Issue.record("a hung app's wake-up did not end the read")
            return
        }
        #expect(requests.count == 0, "a hung app was asked \(requests.count) more questions")
        _ = ScreenWordReader.read(at: Self.point, in: target, with: session)
        #expect(wakes.withLock { $0 } == 2, "a wake-up that never went through was remembered")
    }

    /// **Every terminal wake-up answer ends the read, not only a timeout** — Accessibility off, the
    /// app gone — and none is remembered as a wake. Red if only `.cannotComplete` is classified.
    @Test func aWakeUpRefusedForAnyReasonEndsTheRead() {
        for (status, named) in [(AXError.apiDisabled, "accessibilityDisabled"), (.invalidUIElement, "appUnavailable")] {
            let requests = Requests(status: .noValue)
            var client = requests.client
            client.wake = { _ in status }
            let target = ScreenWordReader.Target(element: AXUIElementCreateApplication(70_003), appName: "Gone", bundleID: "gone")
            let session = AccessibilitySession(budget: .seconds(60), now: { requests.now() }, requests: client)
            guard case .miss(let why) = ScreenWordReader.read(at: Self.point, in: target, with: session), why.contains(named) else {
                Issue.record("a wake-up answered \(status.rawValue) did not end the read")
                continue
            }
            #expect(requests.count == 0)
        }
    }

    /// **Cancellation stops the read between requests.** The first request cancels the task
    /// making it; no second is sent, and the outcome says cancelled rather than missed.
    @Test func cancellationStopsBetweenRequests() async {
        let requests = Requests(status: .noValue) { made in
            if made == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let session = requests.session(budget: .seconds(60))
        let outcome = await Task.detached { ScreenWordReader.read(at: Self.point, in: Self.target, with: session) }.value
        #expect(requests.count == 1)
        guard case .cancelled = outcome else {
            Issue.record("a cancelled read answered \(outcome)")
            return
        }
    }
}

/// **One out-of-process Accessibility read at a time, each under its own timeout.**
struct AccessibilityLaneTests {
    /// Reads started together never overlap. Red if the lane stops awaiting the previous read.
    @Test func readsNeverOverlap() async {
        let lane = AccessibilityLane { _ in }
        let running = Mutex((now: 0, most: 0))
        await withTaskGroup(of: Int.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await lane.run(timeout: 1, {
                        running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                        Thread.sleep(forTimeInterval: 0.02)  // a request nothing can interrupt
                        running.withLock { $0.now -= 1 }
                        return index
                    }, cancelled: { -1 })
                }
            }
            for await _ in group {}
        }
        #expect(running.withLock { $0.most } == 1, "two Accessibility reads ran side by side")
    }

    /// **Each read sees its own timeout.** Hover's quarter second and a selection read's full
    /// second are set on entry, so neither changes the other's mid-read. The fake setter stands for
    /// the process-wide value; each read records what it saw while it ran.
    @Test func eachReadSeesItsOwnTimeout() async {
        let current = Mutex<Float>(0)
        let lane = AccessibilityLane { value in current.withLock { $0 = value } }
        let seen = await withTaskGroup(of: (Float, Float).self) { group in
            for timeout: Float in [0.25, 1.0, 0.25, 1.0] {
                group.addTask {
                    await lane.run(timeout: timeout, {
                        Thread.sleep(forTimeInterval: 0.01)
                        return (timeout, current.withLock { $0 })
                    }, cancelled: { (timeout, -1) })
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(seen.count == 4)
        for (asked, saw) in seen { #expect(asked == saw, "a read asked for \(asked) ran under \(saw)") }
    }

    /// A read whose caller gave up before its turn does no work.
    @Test func aReadCancelledBeforeItsTurnDoesNoWork() async {
        let lane = AccessibilityLane { _ in }
        let worked = Mutex(0)
        let started = Mutex(false)
        let blocker = Task {
            await lane.run(timeout: 1, {
                started.withLock { $0 = true }
                Thread.sleep(forTimeInterval: 0.05)
                return 0
            }, cancelled: { -1 })
        }
        // The blocker is inside the lane before the waiter queues behind it.
        while !started.withLock({ $0 }) { await Task.yield() }
        let waiting = Task { await lane.run(timeout: 1, { worked.withLock { $0 += 1 }; return 1 }, cancelled: { -1 }) }
        waiting.cancel()
        #expect(await waiting.value == -1)
        _ = await blocker.value
        #expect(worked.withLock { $0 } == 0)
    }
}

extension AccessibilityLaneTests {
    /// **A cancelled caller is let go at once**, not after the read ahead of it. Red if the lane
    /// answers a cancelled caller only when its turn comes.
    @Test func aCancelledWaiterIsAnsweredBeforeTheReadAheadEnds() async {
        let lane = AccessibilityLane { _ in }
        let started = Mutex(false)
        let release = Mutex(false)
        let blocker = Task {
            await lane.run(timeout: 1, {
                started.withLock { $0 = true }
                while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
                return 0
            }, cancelled: { -1 })
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        let waiting = Task { await lane.run(timeout: 1, { 1 }, cancelled: { -1 }) }
        waiting.cancel()
        // **Bounded, so a regression fails rather than hangs**: the read ahead is released only
        // after this, and a lane that made the caller wait for it would wait for ever.
        let answered = try? await withDeadline(.seconds(10)) { await waiting.value }
        #expect(answered == -1, "a cancelled caller waited for the read ahead of it")
        release.withLock { $0 = true }
        _ = await blocker.value
    }
}


extension AccessibilityLaneTests {
    /// **A caller cancelled before it asks does no work**, even on an idle lane. Red if the lane
    /// starts the read before the cancellation can reach it.
    @Test func aCallerCancelledBeforeAskingDoesNoWork() async {
        let lane = AccessibilityLane { _ in }
        let worked = Mutex(0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await lane.run(timeout: 1, { worked.withLock { $0 += 1 }; return 1 }, cancelled: { -1 })
        }
        #expect(await task.value == -1)
        await HoverFixtures.drain()
        #expect(worked.withLock { $0 } == 0, "a cancelled caller's read ran")
    }
}

/// **The lane's gate closes before it can open for a caller already gone** (audit round 3, #5). The
/// work waits for `watching` (open) or the fallback (closed), whichever comes first; this pins the
/// order that makes "first" mean "closed" for a cancelled caller.
struct CancellationWatchOrderTests {
    @Test func aCancelledCallersFallbackComesBeforeWatching() async {
        let order = Mutex<[String]>([])
        // Ends when cancelled, which `value(of:)` does — so nothing is left running behind the test.
        let never = Task<Int, Never> { try? await Task.sleep(for: .seconds(60)); return 1 }
        let caller = Task {
            await value(of: never, orOnCancel: { order.withLock { $0.append("fallback") }; return 0 },
                        watching: { order.withLock { $0.append("watching") } })
        }
        caller.cancel()
        #expect(await caller.value == 0)
        #expect(order.withLock { $0 } == ["fallback", "watching"], "the gate could open for a caller already gone")
    }
}

/// **Chrome builds its page tree only for `AXEnhancedUserInterface`** (measured 2026-10-03 on the E2E
/// Mac: `AXManualAccessibility` is refused as unsupported, and with the page open and five seconds of
/// queries no web area appears; with the enhanced attribute set, five appear within two seconds). So a
/// read that found nothing asks once — never for an app that answers, never twice in one launch.
struct ChromiumEscalationTests {
    private final class Requests: Sendable {
        let enhanced = Mutex(0)
        let status: AXError
        init(status: AXError) { self.status = status }
        var client: AccessibilityRequests {
            AccessibilityRequests(
                attribute: { _, _ in (self.status, nil) },
                parameterized: { _, _, _ in (self.status, nil) },
                enhance: { _ in self.enhanced.withLock { $0 += 1 }; return .notImplemented })
        }
        func session() -> AccessibilitySession {
            AccessibilitySession(budget: HoverFixtures.patient, requests: client)
        }
    }

    /// A pid nothing else in the suite uses, so the once-per-launch memory is this test's own.
    private static func target() -> ScreenWordReader.Target {
        ScreenWordReader.Target(
            element: AXUIElementCreateApplication(pid_t(4_000_000 + Int32.random(in: 0..<1_000_000))),
            appName: "Google Chrome", bundleID: "com.google.Chrome")
    }

    @Test func aFullMissAsksTheAppToBuildItsTreeOncePerLaunch() {
        let requests = Requests(status: .noValue)
        let target = Self.target()
        guard case .miss = ScreenWordReader.read(at: CGPoint(x: 10, y: 10), in: target, with: requests.session()) else {
            Issue.record("a read of an empty tree did not miss"); return
        }
        #expect(requests.enhanced.withLock { $0 } == 1, "a miss did not ask for the tree")
        _ = ScreenWordReader.read(at: CGPoint(x: 10, y: 10), in: target, with: requests.session())
        #expect(requests.enhanced.withLock { $0 } == 1, "the app was asked again in the same launch")
    }

    /// An app that stopped answering is not asked for more work.
    @Test func aReadThatFailedAsksNothingMore() {
        let requests = Requests(status: .cannotComplete)
        _ = ScreenWordReader.read(at: CGPoint(x: 10, y: 10), in: Self.target(), with: requests.session())
        #expect(requests.enhanced.withLock { $0 } == 0)
    }
}

