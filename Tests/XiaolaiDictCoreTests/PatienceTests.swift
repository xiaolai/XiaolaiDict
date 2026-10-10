import Foundation
import Testing
import XiaolaiDictTestSupport

/// **The one wait a test uses when the wait's only job is to stop a defect hanging the run.**
///
/// What it must do: end the moment its condition holds, and still end — false, so the caller's
/// assertion names the failure — when the condition never holds. A wait that could not run out would
/// hang the run; one that ran out before its condition could hold would measure the Mac.
struct PatienceTests {
    @Test func aConditionAlreadyTrueIsMetWithoutWaiting() async {
        var looks = 0
        #expect(await Patience.until { looks += 1; return true })
        #expect(looks == 1)
    }

    @Test func aConditionThatComesTrueIsWaitedFor() async {
        var looks = 0
        #expect(await Patience.until { looks += 1; return looks == 4 })
        #expect(looks == 4)
    }

    /// **The positive control: a condition that never holds runs out, and says so.** Given a bound of
    /// nothing, so this proves the guard can fail without the test waiting for one.
    @Test func aConditionThatNeverHoldsRunsOutAndSaysSo() async {
        var looks = 0
        #expect(await Patience.until(within: .zero) { looks += 1; return false } == false)
        #expect(looks >= 1, "it gave up without looking")
    }

    /// A wait whose caller was cancelled looks once more and stops — never a spin on a sleep that
    /// throws at once.
    @Test func aCancelledWaitLooksOnceMoreAndStops() async {
        let waiting = Task { await Patience.until { false } }
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    /// The condition runs on the caller's actor, so a main-actor test can wait on main-actor state.
    @MainActor @Test func theConditionRunsOnTheCallersActor() async {
        var looks = 0
        #expect(await Patience.until { MainActor.assertIsolated(); looks += 1; return looks == 2 })
    }

    @Test func aThrowingConditionThrows() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { _ = try await Patience.until { throw Boom() } }
    }

    /// The same, for a test that must not suspend.
    @Test func theBlockingWaitIsMetAndRunsOut() {
        var looks = 0
        #expect(Patience.blockingUntil { looks += 1; return looks == 3 })
        #expect(looks == 3)
        #expect(Patience.blockingUntil(within: .zero) { false } == false)
    }

    /// **The order the three bounds keep**: a wait fails by name before the test's limit ends it, and
    /// the limit ends a test before anything standing for never could finish and pass by accident.
    @Test func aWaitEndsBeforeTheLimitAndTheLimitBeforeNever() {
        let limit = Duration.seconds(60 * Patience.limitMinutes)
        #expect(Patience.wait < limit)
        #expect(limit < Patience.never)
    }
}
