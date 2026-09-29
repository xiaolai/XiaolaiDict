import Foundation
import Testing
import XiaolaiDictCore

/// **The Swift scheduler against the kernel it was ported from, transition by transition.**
///
/// Every constant in `MemoryScheduler` produces plausible intervals when it is wrong. A scheduler that
/// is subtly wrong is indistinguishable from a correct one until a reader has lost a year of reviews,
/// so "ported carefully" is not a claim this project accepts — the fixture is.
///
/// `Tools/fsrs/parity-vectors.json` is 2,000 transitions from a seeded walk: all four grades, five
/// retentions, delays from one minute to a year, and both sides of the 24-hour boundary that separates
/// the short-term branch from the long-term one. Regenerate with `python3 Tools/fsrs/vectors.py` only
/// when the numbers are *meant* to change, and expect this to go red when they do.
struct MemorySchedulerParityTests {
    struct Vectors: Decodable {
        let version: String
        let transitions: [Transition]
    }

    struct Transition: Decodable {
        let retention: Double
        let grade: Int
        let now: Double
        let before: State
        let after: State
    }

    struct State: Decodable {
        let stability: Double?
        let difficulty: Double?
        let phase: String
        let lastReview: Double?
        let due: Double?
    }

    static let vectors: Vectors = {
        // From the source tree, not a bundled resource: the fixture belongs to the kernel that
        // generates it, and a copy in a resource bundle is one that can quietly fall behind.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tools/fsrs/parity-vectors.json")
        // Force-unwrapped deliberately: a missing or unreadable fixture is a broken checkout, and
        // every test below would otherwise pass over zero transitions and report success.
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    private func card(_ state: State) -> ScheduledCard {
        ScheduledCard(
            state: state.stability.flatMap { s in
                state.difficulty.map { MemoryState(stability: s, difficulty: $0) }
            },
            phase: SchedulePhase(rawValue: state.phase) ?? .new,
            lastReview: state.lastReview.map { Date(timeIntervalSince1970: $0) },
            due: state.due.map { Date(timeIntervalSince1970: $0) })
    }

    /// **The fixture is what this suite is**, so a suite that read none of it would pass in silence.
    @Test func thefixtureIsTheOneThisPortWasWrittenAgainst() {
        #expect(Self.vectors.version == MemoryScheduler.version)
        #expect(Self.vectors.transitions.count == 2_000)
        // Every phase a card can be in before a grade, so no branch of the transition table is
        // unexercised. `new` is the first review of each of the 100 walks.
        let phases = Set(Self.vectors.transitions.map(\.before.phase))
        #expect(phases == ["new", "learning", "review", "relearning"])
        #expect(Set(Self.vectors.transitions.map(\.grade)) == [1, 2, 3, 4])
    }

    /// Stability and difficulty, to the last bit the two languages can both represent.
    ///
    /// **Exactly, not nearly.** A tolerance here would hide the one class of defect worth finding — a
    /// constant off in the fifth decimal, which compounds over a year of intervals into months. `1e-12`
    /// is the width of `Double` arithmetic ordering differences between the two, not a margin for
    /// error: the measured worst case over these 2,000 is far below it, and it is asserted.
    @Test func everyTransitionMatchesTheKernel() throws {
        var worstState = 0.0, checked = 0
        for (index, transition) in Self.vectors.transitions.enumerated() {
            let scheduler = try MemoryScheduler(retention: transition.retention)
            let grade = try #require(Grade(rawValue: transition.grade))
            let produced = try scheduler.review(
                card(transition.before), grade: grade,
                now: Date(timeIntervalSince1970: transition.now))
            let expected = transition.after

            let state = try #require(produced.state, "transition \(index) produced no memory state")
            let expectedStability = try #require(expected.stability)
            let expectedDifficulty = try #require(expected.difficulty)
            worstState = max(worstState, abs(state.stability - expectedStability))
            worstState = max(worstState, abs(state.difficulty - expectedDifficulty))
            checked += 1

            #expect(produced.phase.rawValue == expected.phase,
                    "transition \(index): phase \(produced.phase.rawValue) ≠ \(expected.phase)")
            // **The due instant is exact.** It is an integer number of seconds from `now` in both
            // implementations — ten minutes, fifteen, or whole days — so any difference at all is a
            // different interval, not a rounding artefact.
            let producedDue = produced.due?.timeIntervalSince1970
            #expect(producedDue == expected.due, "transition \(index): due \(producedDue as Any) ≠ \(expected.due as Any)")
            #expect(produced.lastReview?.timeIntervalSince1970 == expected.lastReview)
        }
        #expect(checked == 2_000)
        print("PARITY \(checked) transitions, worst |ΔS| or |ΔD| = \(worstState)")
        #expect(worstState < 1e-12, "the port diverges from the kernel by \(worstState)")
    }

    /// The spec's own worked example (§13), which is the one sequence a person can check by eye.
    @Test func theworkedExampleFromTheSpecificationReproduces() throws {
        let scheduler = try MemoryScheduler()
        var card = ScheduledCard()
        var now = Date(timeIntervalSince1970: 1_790_640_000)
        let expected: [(grade: Grade, stability: Double, difficulty: Double, days: Double)] = [
            (.good, 2.3065, 2.1181, 2), (.good, 10.9643, 2.1112, 11), (.good, 46.2802, 2.1043, 46),
            (.again, 2.9326, 7.3900, 10.0 / 1_440), (.good, 2.9326, 7.3778, 3),
            (.good, 7.7945, 7.3657, 8),
        ]
        for (index, step) in expected.enumerated() {
            card = try scheduler.review(card, grade: step.grade, now: now)
            let state = try #require(card.state)
            #expect(abs(state.stability - step.stability) < 5e-5, "step \(index + 1) stability")
            #expect(abs(state.difficulty - step.difficulty) < 5e-5, "step \(index + 1) difficulty")
            let interval = try #require(card.due).timeIntervalSince(now) / 86_400
            #expect(abs(interval - step.days) < 1e-9, "step \(index + 1) interval")
            now = try #require(card.due)
        }
    }

    /// `R(0, S) = 1` and `R(S, S) = 0.9` are the curve's two fixed points. The first is a mathematical
    /// boundary and **not a claim that a reader certainly knows something they just saw** — which is why
    /// no surface may render it as measured knowledge.
    @Test func thecurveKeepsItsTwoFixedPoints() throws {
        let scheduler = try MemoryScheduler()
        for stability in [0.001, 1.0, 10.0, 365.0, 36_500.0] {
            #expect(try scheduler.recall(elapsedDays: 0, stability: stability) == 1)
            #expect(abs(try scheduler.recall(elapsedDays: stability, stability: stability) - 0.9) < 1e-12)
        }
        // At the default retention the raw interval *is* the stability, which is what makes `S`
        // readable as a number of days rather than an opaque score.
        #expect(abs(try scheduler.interval(stability: 10) - 10) < 1e-12)
    }

    /// What the scheduler refuses. A caller that invents memory for a new card, or hands back a clock
    /// that has gone backwards, is a caller with a defect — and silence here would write it to disk.
    @Test func invalidInputIsRefusedRatherThanAbsorbed() throws {
        let scheduler = try MemoryScheduler()
        let now = Date(timeIntervalSince1970: 1_790_640_000)
        #expect(throws: SchedulerError.self) {
            try scheduler.review(
                ScheduledCard(state: MemoryState(stability: 5, difficulty: 5), phase: .new),
                grade: .good, now: now)
        }
        #expect(throws: SchedulerError.self) {
            try scheduler.review(
                ScheduledCard(state: MemoryState(stability: 5, difficulty: 5), phase: .review,
                              lastReview: now, due: now),
                grade: .good, now: now.addingTimeInterval(-1))
        }
        #expect(throws: SchedulerError.self) { try MemoryScheduler(retention: 1) }
        #expect(throws: SchedulerError.self) { try MemoryScheduler(retention: 0) }
        #expect(throws: SchedulerError.self) { try MemoryScheduler(weights: [1, 2, 3]) }
        var wrong = MemoryScheduler.defaultWeights
        wrong[4] = 999
        #expect(throws: SchedulerError.self) { try MemoryScheduler(weights: wrong) }
    }

    /// **A failure never deletes the card's history.** It lowers the estimate and reschedules; it does
    /// not return the card to `new`, which would throw away everything the reader has done with it.
    @Test func alapseLowersTheEstimateWithoutResettingTheCard() throws {
        let scheduler = try MemoryScheduler()
        var card = ScheduledCard()
        var now = Date(timeIntervalSince1970: 1_790_640_000)
        for _ in 0..<3 {
            card = try scheduler.review(card, grade: .good, now: now)
            now = try #require(card.due)
        }
        let before = try #require(card.state)
        card = try scheduler.review(card, grade: .again, now: now)
        let after = try #require(card.state)
        #expect(after.stability < before.stability, "a lapse must lower the estimate")
        #expect(after.stability > 0, "and must not erase it")
        #expect(card.phase == .relearning)
        #expect(try #require(card.due).timeIntervalSince(now) == 600)
    }
}
