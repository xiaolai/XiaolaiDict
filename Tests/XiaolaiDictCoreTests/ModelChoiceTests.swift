import Foundation
@testable import ModelKit
import Testing

/// **Which model answers, and whether the reader is told it is not the one they chose.**
///
/// The case these exist for was measured on 2026-09-30: a 32 GB Mac with 4,729 MB free, a 9B
/// needing 6,633 MB, and the 4B that would have answered deleted to make room for it.
struct ModelChoiceTests {
    private static let mac: UInt64 = 32 * 1_073_741_824
    /// Enough for 4B (3,585 MB peak) and not for 9B (6,633 MB) — the state that Mac was in.
    private static let tight: UInt64 = 4_729 * 1_048_576
    private static let roomy: UInt64 = 24 * 1_073_741_824

    @Test func thechosenModelAnswersWhenItFits() {
        let choice = ModelSizing.answering(
            wanted: .large, installed: [.standard, .large],
            physicalMemory: Self.mac, availableMemory: Self.roomy)
        #expect(choice == .chosen(.large))
        #expect(!choice.isStandingIn)
    }

    /// **The whole point.** The reader chose 9B, the Mac is busy, and the 4B they kept answers —
    /// named as standing in, so the card cannot read as the answer they asked for.
    @Test func asmallerModelStandsInAndSaysWhoseAnswerItIs() {
        let choice = ModelSizing.answering(
            wanted: .large, installed: [.standard, .large],
            physicalMemory: Self.mac, availableMemory: Self.tight)
        #expect(choice == .standingIn(.standard, forWanted: .large))
        #expect(choice.answering == .standard)
        #expect(choice.isStandingIn, "the reader would have read a 4B answer as a 9B one")
    }

    /// Without the smaller model kept, the same Mac has nothing — which is what pruning to one
    /// produced, and what this whole change exists to stop.
    @Test func withoutTheSmallerModelTheBusyMacHasNothing() {
        let choice = ModelSizing.answering(
            wanted: .large, installed: [.large], physicalMemory: Self.mac, availableMemory: Self.tight)
        #expect(choice == .none(wanted: .large))
        #expect(choice.answering == nil)
    }

    /// **A larger model never stands in for a smaller one.** Choosing 4B is a decision about
    /// memory and time, and answering it with 9B spends both against the reader's wishes.
    @Test func alargerModelNeverStandsInForAsmallerOne() {
        let choice = ModelSizing.answering(
            wanted: .standard, installed: [.standard, .large],
            physicalMemory: Self.mac, availableMemory: Self.roomy)
        #expect(choice == .chosen(.standard))

        // Even where only the larger is installed and fits, it does not answer for the smaller.
        let absent = ModelSizing.answering(
            wanted: .standard, installed: [.large], physicalMemory: Self.mac, availableMemory: Self.roomy)
        #expect(absent == .none(wanted: .standard), "9B answered for a reader who asked for 4B")
    }

    /// No choice recorded is not a failure: the largest that fits answers, and nothing is
    /// standing in, because there is nothing for it to stand in for.
    @Test func noChoiceTakesTheLargestThatFits() {
        #expect(ModelSizing.answering(wanted: nil, installed: [.standard, .large],
                                      physicalMemory: Self.mac, availableMemory: Self.roomy)
                == .chosen(.large))
        #expect(ModelSizing.answering(wanted: nil, installed: [.standard, .large],
                                      physicalMemory: Self.mac, availableMemory: Self.tight)
                == .chosen(.standard))
        #expect(ModelSizing.answering(wanted: nil, installed: [],
                                      physicalMemory: Self.mac, availableMemory: Self.roomy)
                == .none(wanted: nil))
    }
}
