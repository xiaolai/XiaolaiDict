import Testing

@testable import XiaolaiDict

/// **The arithmetic that decides whether the settings window shudders.** It lived inline in the
/// report's sampling loop, where nothing tested it — so the assertion that caught a real shudder
/// was itself unchecked. Each case below is a shape the window was measured making.
struct FrameTrajectoryTests {
    /// One movement: every position between the two ends, one direction, nothing past the target.
    @Test func aCleanMovement() {
        let move = FrameTrajectory(from: 621, samples: [662, 685, 715, 741, 770, 785], to: 785)
        #expect(move.steps == 5)
        #expect(move.reversals == 0)
        #expect(move.overshoot == 0)
    }

    /// The shudder, as measured on Dictionary: down past the target by the height of the title bar
    /// and tabs, then back. Steps alone call this smooth — it took many — which is why reversals
    /// and overshoot exist.
    @Test func overshootAndCorrect() {
        let move = FrameTrajectory(from: 785, samples: [765, 698, 620, 580, 598, 654, 668], to: 668)
        #expect(move.reversals == 1)
        #expect(move.overshoot == 88)
    }

    /// A snap: the window is at its target by the first sample. Zero steps, and not a reversal.
    @Test func aSnap() {
        let move = FrameTrajectory(from: 394, samples: [786, 786, 786], to: 786)
        #expect(move.steps == 0)
        #expect(move.reversals == 0)
        #expect(move.overshoot == 0)
    }

    /// A frame lands on half points; a half-point wobble is rounding, not a change of direction.
    @Test func aWobbleSmallerThanAPointIsNotAReversal() {
        let move = FrameTrajectory(from: 400, samples: [450, 449.5, 450.4, 500], to: 500)
        #expect(move.reversals == 0)
    }

    /// No change is no movement — not a movement of zero steps that some check then calls a jump.
    @Test func standingStill() {
        let move = FrameTrajectory(from: 621, samples: [621, 621], to: 621)
        #expect(move.path == [621])
        #expect(move.change == 0)
        #expect(move.steps == 0)
    }
}
