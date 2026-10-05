import Foundation
@testable import ReviewKit
import Testing

/// **The post-confirmation cooldown — an experiment the owner has not approved** (review-module-plan
/// §8.3c, R1c). The rule, the arm and the surface it may be set from; whether it runs at all is the
/// app's switch, off by default, and tested there.
struct ConfirmationCooldownTests {
    /// Shanghai keeps no daylight saving, so a test about the study day's cutoff is not also a test
    /// about a clock change. `StudyDayTests` owns those.
    private func zone() throws -> TimeZone { try #require(TimeZone(identifier: "Asia/Shanghai")) }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try zone()
        return try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: day, hour: hour, minute: minute, second: second)))
    }

    /// The default minimum delay, so the placeholder is what is measured.
    private func cooldown() throws -> ConfirmationCooldown {
        ConfirmationCooldown(studyDay: StudyDay(timeZone: try zone(), cutoffHour: 4))
    }

    /// The last byte of a UUID is the arm: even is the control, odd the cooldown.
    private func note(endingIn last: String) throws -> UUID {
        try #require(UUID(uuidString: "6F9619FF-8B86-4011-B42D-00C04FC964\(last)"))
    }

    /// **The later of the next study day and the minimum delay.** Without the minimum, a confirmation
    /// at 03:59:59 hides the card for one second — the study day ends then.
    @Test func theCooldownIsTheLaterOfTheNextStudyDayAndTheMinimumDelay() throws {
        let rule = try cooldown()
        #expect(ConfirmationCooldown.placeholderMinimumDelay == 8 * 3_600, "the placeholder is 8 h")
        // One second before the cutoff: the minimum wins, 8 h on.
        #expect(rule.hiddenUntil(confirmedAt: try at(15, 3, 59, 59)) == (try at(15, 11, 59, 59)))
        // Five hours before the cutoff: the minimum still wins, past it.
        #expect(rule.hiddenUntil(confirmedAt: try at(15, 23)) == (try at(16, 7)))
        // Eighteen hours before it: the next study day wins.
        #expect(rule.hiddenUntil(confirmedAt: try at(15, 10)) == (try at(16, 4)))
    }

    /// **Set only from a surface that displayed the answer.** Confirming from a list that never showed
    /// it is the reader agreeing with an identity, not having just read the back of the card.
    @Test func aSurfaceThatDidNotShowTheAnswerHidesNothing() throws {
        let rule = try cooldown(), when = try at(15, 10)
        for id in [try note(endingIn: "00"), try note(endingIn: "01")] {
            #expect(rule.hiddenUntil(noteID: id, confirmedAt: when, exposure: .answerNotShown) == nil)
        }
        // Positive control: the same note, in the cooldown arm, from a surface that showed it.
        #expect(rule.hiddenUntil(noteID: try note(endingIn: "01"), confirmedAt: when, exposure: .answerShown)
                == (try at(16, 4)))
    }

    /// **Deterministic, and nothing stored.** The arm is a fact of the note's id, so the comparison
    /// at the second graded review (§8.3c) can be run later on any ledger without a column saying
    /// which arm a note was in.
    @Test func theArmIsDecidedByNoteIdParity() throws {
        let rule = try cooldown(), when = try at(15, 10)
        #expect(ConfirmationCooldown.arm(of: try note(endingIn: "00")) == .control)
        #expect(ConfirmationCooldown.arm(of: try note(endingIn: "01")) == .cooldown)
        #expect(ConfirmationCooldown.arm(of: try note(endingIn: "0B")) == .cooldown, "11 is odd")
        #expect(ConfirmationCooldown.arm(of: try note(endingIn: "FE")) == .control, "254 is even")
        // The control arm hides nothing, even where the answer was shown.
        #expect(rule.hiddenUntil(noteID: try note(endingIn: "00"), confirmedAt: when, exposure: .answerShown) == nil)
        // Half each way over every value the last byte can take — two arms, not a skew.
        let arms = try (0...255).map { try ConfirmationCooldown.arm(of: note(endingIn: String(format: "%02X", $0))) }
        #expect(arms.filter { $0 == .cooldown }.count == 128)
    }

    // MARK: - The reader's choice (R1c, 2026-10-05)

    /// **The minimum delay is the reader's, from a small set, and the rule waits exactly that.** One
    /// hour before the cutoff the next study day is an hour away, so every choice — and only the
    /// choice — decides the instant.
    @Test func theRuleWaitsTheMinimumTheReaderChose() throws {
        let hour: TimeInterval = 3_600
        let offered: [TimeInterval] = [4 * hour, 8 * hour, 12 * hour]
        #expect(ConfirmationCooldown.minimumDelayChoices == offered)
        #expect(ConfirmationCooldown.minimumDelayChoices.contains(ConfirmationCooldown.placeholderMinimumDelay))
        let when = try at(15, 3)
        for choice in ConfirmationCooldown.minimumDelayChoices {
            let rule = ConfirmationCooldown(studyDay: StudyDay(timeZone: try zone(), cutoffHour: 4), minimumDelay: choice)
            #expect(rule.hiddenUntil(confirmedAt: when) == when.addingTimeInterval(choice))
        }
    }

    /// **A stored value off the menu is the placeholder** — the one rule the Settings picker and the
    /// confirmation both read, so the two cannot disagree about a value one of them cannot show.
    @Test func aStoredMinimumOffTheMenuIsThePlaceholder() {
        let placeholder = ConfirmationCooldown.placeholderMinimumDelay
        #expect(ConfirmationCooldown.minimumDelay(stored: nil) == placeholder)
        for choice in ConfirmationCooldown.minimumDelayChoices {
            #expect(ConfirmationCooldown.minimumDelay(stored: choice) == choice)
        }
        let strays: [TimeInterval] = [3 * 3_600, 0, -4 * 3_600, .infinity, .nan]
        for stray in strays {
            #expect(ConfirmationCooldown.minimumDelay(stored: stray) == placeholder, "\(stray)")
        }
    }
}
