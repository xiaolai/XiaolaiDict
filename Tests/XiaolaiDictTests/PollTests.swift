import Testing
@testable import XiaolaiDict

/// One poll for every "wait until this is true" in the app (audit round 3, #19): the panel's
/// visibility check and the instruments' `settle` were two copies of the same loop that had already
/// drifted in how they treated cancellation.
@MainActor
struct PollTests {
    final class Counter { var value = 0 }

    // **A liveness bound, not a performance assertion.** Five seconds ran out under the full suite's
    // load before the third check: a main-actor test can be starved that long. `patient` is what every
    // deadline-bound test here uses; a healthy run still finishes in milliseconds.
    private static let patient = HoverFixtures.patient

    @Test func aConditionAlreadyTrueIsMetWithoutWaiting() async {
        #expect(await Poll.until(within: Self.patient) { true } == .met)
    }

    @Test func aConditionThatBecomesTrueIsMet() async {
        let checks = Counter()
        let outcome = await Poll.until(within: Self.patient) { checks.value += 1; return checks.value >= 3 }
        #expect(outcome == .met)
        #expect(checks.value == 3)
    }

    @Test func aConditionNeverTrueTimesOut() async {
        #expect(await Poll.until(within: .milliseconds(30)) { false } == .timedOut)
    }

    /// Giving up is its own answer, checked before the condition: a superseded ticket must not be
    /// credited with a drawing that belongs to the panel that replaced it.
    @Test func givingUpIsAbandonedEvenWhenTheConditionHolds() async {
        #expect(await Poll.until(within: Self.patient, abandonIf: { true }) { true } == .abandoned)
    }

    /// A cancelled caller stops waiting at once, after one last look.
    @Test func aCancelledPollStopsAndLooksOnceMore() async {
        let checks = Counter()
        let task = Task { await Poll.until(within: Self.patient) { checks.value += 1; return false } }
        task.cancel()
        #expect(await task.value == .abandoned)
        let seen = Task { await Poll.until(within: Self.patient) { true } }
        seen.cancel()
        #expect(await seen.value == .met, "a condition true at cancellation was reported as not met")
    }

    /// **Giving up wins at cancellation too** (verify of the closing pass, #19). The last look on
    /// cancellation asked only the condition, so a superseded panel that happened to be drawn was
    /// reported seen.
    ///
    /// The cancellation has to land **during the sleep**, which is the path the defect was on: the loop's
    /// own checks run first and pass, then the reason to stop and the condition both become true, then
    /// the sleep is cancelled.
    @Test func aCancelledPollThatShouldGiveUpGivesUp() async {
        let checks = Counter()
        let superseded = Counter()
        let task = Task {
            await Poll.until(within: Self.patient, abandonIf: { superseded.value > 0 }) {
                checks.value += 1
                return superseded.value > 0
            }
        }
        while checks.value == 0 { await Task.yield() }
        superseded.value = 1
        task.cancel()
        #expect(await task.value == .abandoned, "a superseded poll was reported met at cancellation")
    }
}
