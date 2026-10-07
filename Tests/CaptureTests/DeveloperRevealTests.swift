import Foundation
import Testing

@testable import Capture

/// Shift+Up three times in quick succession reveals the developer pane. The detector is a value, so the
/// gesture is tested without posting an event.
struct DeveloperRevealTests {
    private func run(_ presses: [(Bool, Double)]) -> [Bool] {
        var sequence = RevealSequence()
        return presses.map { sequence.note(shiftUp: $0.0, at: $0.1) }
    }

    @Test func threeShiftUpsInARowReveal() {
        #expect(run([(true, 0), (true, 0.3), (true, 0.6)]) == [false, false, true])
    }

    /// Two is not three, and the third alone starts over.
    @Test func fewerThanThreeRevealNothing() {
        #expect(run([(true, 0), (true, 0.3)]) == [false, false])
    }

    /// **Any other key in between starts again**, so ordinary arrowing around a list never completes it.
    @Test func anyOtherKeyResets() {
        #expect(run([(true, 0), (true, 0.2), (false, 0.4), (true, 0.6), (true, 0.8)]) == [false, false, false, false, false])
    }

    /// Too slow is not a gesture.
    @Test func aPauseResets() {
        #expect(run([(true, 0), (true, 0.3), (true, 5)]) == [false, false, false])
    }

    /// After revealing it starts over, so a fourth press is not a second reveal.
    @Test func itFiresOnceAndStartsOver() {
        #expect(run([(true, 0), (true, 0.1), (true, 0.2), (true, 0.3)]) == [false, false, true, false])
    }
}
