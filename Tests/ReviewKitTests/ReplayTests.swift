import Foundation
@testable import ReviewKit
import Testing

/// **A card's history, re-run against the real scheduler** (review-module-plan §7.2, WI-9b).
///
/// The ledger keeps every grade with the state either side of it, so a history can be checked: each
/// live grade starts where the one before it left the card, the scheduler reproduces what the grade
/// says it did, and the card holds where the last one ended. The instant is the subtle part. The
/// ledger keeps seconds since 1970 and `Date` keeps seconds since 2001, so one stored value stands
/// for up to a few in-memory instants — and a grade written before WI-9a was scheduled with the one
/// the reader's clock gave, not the one the ledger reads back. These tests hold the search over those
/// instants to what it claims.
struct ReplayTests {
    /// SplitMix64, seeded, so a failure names an instant that can be found again.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let day: TimeInterval = 86_400

    /// A last review the ledger can hold, from plan §12.
    private let previous = Date(timeIntervalSinceReferenceDate: 800_879_356.388_499_7)
    /// **One ulp short of a whole day after `previous` in memory, and exactly a day once stored.**
    /// The reader's clock gave this; the ledger reads back 800,965,756.388,499,7.
    private let original = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)

    /// A grade as the ledger reads it back: every instant through storage, and `after.lastReview`
    /// derived from `reviewed_at` for a grade and from `before` for practice, as `Ledger` derives it.
    private func readBack(_ card: UUID, _ grade: Grade, at instant: Date, before: ScheduledCard,
                          after: ScheduledCard, kind: ReviewEvent.Kind = .graded,
                          version: String = MemoryScheduler.version, voided: Bool = false) -> ReviewEvent {
        let reviewedAt = ReviewInstant.stored(instant)
        let storedBefore = ScheduledCard(state: before.state, phase: before.phase,
                                         lastReview: before.lastReview.map(ReviewInstant.stored),
                                         due: before.due.map(ReviewInstant.stored))
        let storedAfter = ScheduledCard(state: after.state, phase: after.phase,
                                        lastReview: kind == .practice ? storedBefore.lastReview : reviewedAt,
                                        due: after.due.map(ReviewInstant.stored))
        return ReviewEvent(cardID: card, grade: grade, reviewedAt: reviewedAt, before: storedBefore,
                           after: storedAfter, schedulerVersion: version,
                           retention: kind == .practice ? 0 : 0.9, cardRevision: 0, kind: kind,
                           voidedAt: voided ? reviewedAt : nil)
    }

    /// A grade as the ledger writes one today: scheduled with the stored instant (WI-9a).
    private func graded(_ card: UUID, _ grade: Grade, from before: ScheduledCard, at instant: Date,
                        version: String = MemoryScheduler.version) throws -> ReviewEvent {
        let after = try MemoryScheduler().review(before, grade: grade, now: ReviewInstant.stored(instant))
        return readBack(card, grade, at: instant, before: before, after: after, version: version)
    }

    /// A grade as the ledger wrote one **before WI-9a**: scheduled with the in-memory instant and
    /// stored at its encoding.
    private func gradedBeforeWI9a(_ card: UUID, _ grade: Grade, from before: ScheduledCard,
                                  at instant: Date) throws -> ReviewEvent {
        let after = try MemoryScheduler().review(before, grade: grade, now: instant)
        return readBack(card, grade, at: instant, before: before, after: after)
    }

    private func card(_ id: UUID, holding scheduled: ScheduledCard,
                      version: String = MemoryScheduler.version) -> StudyCard {
        StudyCard(id: id, noteID: UUID(), scheduled: scheduled, schedulerVersion: version,
                  createdAt: previous)
    }

    // MARK: - The preimage search

    /// **The legacy boundary, pinned** (plan §12): a grade one ulp short of a day in memory is the
    /// short-term branch, S 10.96; the instant the ledger reads back is exactly a day, S 13.47. A
    /// replay at the decoded instant alone would call a genuine pre-WI-9a grade a forgery.
    @Test func aLegacyBoundaryEventIsConsistentThroughAPreimage() throws {
        let scheduler = try MemoryScheduler()
        let decoded = ReviewInstant.stored(original)
        try #require(ReviewInstant.stored(previous) == previous, "the fixture's last review is not storable")
        try #require(decoded.timeIntervalSinceReferenceDate == 800_965_756.388_499_7)
        #expect(original.timeIntervalSince(previous) == 86_399.999_999_880_79)
        #expect(decoded.timeIntervalSince(previous) == 86_400)

        let before = ScheduledCard(state: MemoryState(stability: 10.96, difficulty: 6.0), phase: .review,
                                   lastReview: previous, due: previous.addingTimeInterval(11 * Self.day))
        let written = try scheduler.review(before, grade: .good, now: original)
        let atDecoded = try scheduler.review(before, grade: .good, now: decoded)
        #expect(written.state?.stability == 10.96)
        #expect(atDecoded.state?.stability == 13.471_132_703_771_99)

        let event = readBack(UUID(), .good, at: original, before: before, after: written)
        #expect(Replay.transition(of: event, using: scheduler) == .atLegacyPrecision)
        // **A control**: the same grade written today replays at the decoded instant itself.
        let today = readBack(UUID(), .good, at: original, before: before, after: atDecoded)
        #expect(Replay.transition(of: today, using: scheduler) == .exact)

        // And a whole card: introduced on the stored instant, then graded the old way on the boundary.
        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        let second = try gradedBeforeWI9a(id, .good, from: first.after, at: original)
        try #require(try scheduler.review(first.after, grade: .good, now: decoded).state != second.after.state,
                     "the boundary schedules this card alike either side, so it cannot show the search")
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, second])
                == .consistentAtLegacyPrecision(events: [second.id]))
    }

    /// **No instant the stored value stands for reproduces it**, so it is not a genuine grade: the
    /// genuine instant is always in the set. Every preimage is tried before that is said.
    @Test func anEventNoPreimageReproducesIsInconsistent() throws {
        let stored = ReviewInstant.encoded(original)
        let expected = [800_965_756.388_499_7, 800_965_756.388_499_6, 800_965_756.388_499_9]
        #expect(Replay.preimages(of: stored)
                == .found(expected.map(Date.init(timeIntervalSinceReferenceDate:))),
                "the decoded instant first, then the rest of the set")

        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        // A transition the real scheduler did compute — for an instant two days on, which this
        // stored value does not stand for.
        let elsewhere = try MemoryScheduler().review(first.after, grade: .good,
                                                    now: previous.addingTimeInterval(2 * Self.day))
        let forged = readBack(id, .good, at: original, before: first.after, after: elsewhere)
        #expect(Replay.transition(of: forged, using: try MemoryScheduler()) == .notReproduced)
        #expect(Replay.verdict(of: card(id, holding: forged.after), events: [first, forged])
                == .inconsistent(event: forged.id, reason: .notReproduced))
    }

    /// **The encoding model, against the clock**: every instant lies in the preimage set of its own
    /// stored value, with the decoded instant first. Plan §12 measured 0 misses in 200,000.
    ///
    /// The set grows without bound towards 2001-01-01, where the reference date's resolution is
    /// finest — 8,193 instants at 2001-01-02 — so the search stops at `preimageLimit` and says so.
    /// Asserted below: it says so only before 2^17 s after the reference date, and nowhere else.
    @Test func everyGradeLiesInItsStoredPreimageSet() {
        let completeFrom: TimeInterval = 131_072  // 2^17 s: 2001-01-02T12:24:32Z
        var generator = Seeded(state: 20_261_004)
        var misses: [Double] = [], refusedLate: [Double] = [], refused = 0, moved = 0
        var sizes2026 = Set<Int>(), sizes2010s = Set<Int>()
        let year: TimeInterval = 31_557_600
        let spans: [(Range<TimeInterval>, Int)] = [(0..<100 * year, 200_000),        // 2001–2100
                                                   (25 * year..<26 * year, 50_000),   // 2026
                                                   (9 * year..<17 * year, 50_000)]    // 2010–2017
        for (span, count) in spans {
            for _ in 0..<count {
                let instant = Date(timeIntervalSinceReferenceDate: .random(in: span, using: &generator))
                let stored = ReviewInstant.encoded(instant)
                switch Replay.preimages(of: stored) {
                case .beyondTheSearch:
                    refused += 1
                    if instant.timeIntervalSinceReferenceDate >= completeFrom {
                        refusedLate.append(instant.timeIntervalSinceReferenceDate)
                    }
                case .found(let set):
                    if !set.contains(instant) || set.first != ReviewInstant.decoded(stored) {
                        misses.append(instant.timeIntervalSinceReferenceDate)
                    }
                    if span.lowerBound == 25 * year { sizes2026.insert(set.count) }
                    if span.lowerBound == 9 * year { sizes2010s.insert(set.count) }
                }
                if ReviewInstant.stored(instant) != instant { moved += 1 }
            }
        }
        // **Exact powers of two, and an ulp either side** — where the reference date's resolution
        // halves, so where a set changes size and its limit is reached first. A uniform sample lands on
        // one with probability nil, and the boundary the claim starts from is one (WI-8).
        for exponent in 0...31 {
            let edge = Double(UInt64(1) << UInt64(exponent))
            for seconds in [edge.nextDown, edge, edge.nextUp] {
                let instant = Date(timeIntervalSinceReferenceDate: seconds)
                switch Replay.preimages(of: ReviewInstant.encoded(instant)) {
                case .beyondTheSearch:
                    refused += 1
                    if seconds >= completeFrom { refusedLate.append(seconds) }
                case .found(let set):
                    if !set.contains(instant) || set.first != ReviewInstant.stored(instant) {
                        misses.append(seconds)
                    }
                }
            }
        }
        // And the instants a real clock gives, which are what the ledger is handed.
        for _ in 0..<1_000 {
            let now = Date()
            if case .found(let set) = Replay.preimages(of: ReviewInstant.encoded(now)), set.contains(now) {
                continue
            }
            misses.append(now.timeIntervalSinceReferenceDate)
        }
        #expect(misses.isEmpty, "the original instant is not in its stored value's preimage set: \(misses.prefix(5))")
        #expect(refusedLate.isEmpty, "the search gave up on an instant it covers: \(refusedLate.prefix(5))")
        #expect(sizes2026 == [1, 3], "plan §12: 1–3 preimages for 2026 dates")
        #expect(sizes2010s == [3, 5], "plan §12: 3–5 preimages for 2010–2017 dates")
        // **Controls.** The search is a no-op where storage moves nothing, so the samples must
        // include instants storage moves; and the refusal must be reachable, or the second
        // assertion could not fail.
        #expect(moved > 100_000, "too few sampled instants change in storage to test anything")
        #expect(refused > 0, "no sample reached the limit, so the refusal above is untested")
        #expect(Replay.preimages(of: ReviewInstant.encoded(Date(timeIntervalSinceReferenceDate: 1)))
                == .beyondTheSearch)
        #expect(Replay.preimages(of: .nan) == .found([]), "no instant is stored as NaN")
        #expect(Replay.preimages(of: .infinity) == .found([]), "nor as infinity")
    }

    /// **The documented boundary, exactly** (WI-8). 2^17 s after the reference date is where the
    /// instant's resolution halves: below it, steps of 2^-36 s; above, 2^-35 s. Its stored value
    /// stands for 4,096 instants below and 2,048 above as well as itself — 6,145 — so a limit of 4,097
    /// refused the very instant the claim starts from, and refused it before asking whether the
    /// decoded instant, the one a grade since WI-9a is scheduled with, reproduces the grade.
    @Test func theSearchIsCompleteFromItsDocumentedBoundaryOn() throws {
        let boundary = Date(timeIntervalSinceReferenceDate: 131_072)
        guard case .found(let set) = Replay.preimages(of: ReviewInstant.encoded(boundary)) else {
            Issue.record("the search gave up at 2^17 s, where it claims to be complete")
            return
        }
        #expect(set.count == 6_145)
        #expect(set.first == boundary, "the decoded instant first")
        #expect(set.contains(boundary.addingTimeInterval(-0x1p-24)) && set.contains(boundary.addingTimeInterval(0x1p-24)),
                "the set reaches half the stored value's step either side")

        // A grade written today at that instant is exact, and its card consistent.
        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: boundary)
        #expect(Replay.transition(of: first, using: try MemoryScheduler()) == .exact)
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [first]) == .consistent)
    }

    /// **An instant the search cannot enumerate is unreplayable, never inconsistent**: nothing
    /// was shown to be wrong, and nothing was shown to be right either.
    @Test func anInstantBeyondTheSearchIsUnreplayableNotInconsistent() throws {
        let id = UUID()
        let early = Date(timeIntervalSinceReferenceDate: 3_600)  // 2001-01-01T01:00:00Z
        // Scheduled for an instant this stored value does not stand for, so the decoded instant does
        // not reproduce it — and the rest of its set is far past the limit.
        let elsewhere = try MemoryScheduler().review(ScheduledCard(), grade: .good,
                                                    now: early.addingTimeInterval(2 * Self.day))
        let forged = readBack(id, .good, at: early, before: ScheduledCard(), after: elsewhere)
        #expect(Replay.verdict(of: card(id, holding: forged.after), events: [forged])
                == .unreplayable(.instantBeyondTheSearch(event: forged.id)))
        // **The decoded instant needs no search** (WI-8): a grade written today at the same instant is
        // exact, however many other instants its stored value stands for.
        let today = try graded(id, .good, from: ScheduledCard(), at: early)
        #expect(Replay.verdict(of: card(id, holding: today.after), events: [today]) == .consistent)
    }

    /// **A history the scheduler refuses is a verdict, never a trap** (audit-fix round 1). A grade at
    /// -1e30 s and the next at the present are 1.2e25 elapsed days apart, which no whole-day count
    /// holds; the scheduler refuses that span, so no build could have written the second grade, and
    /// the replay says so by name — inconsistent, not reproduced — rather than ending the process.
    @Test func aSpanTheSchedulerRefusesIsInconsistentNotATrap() throws {
        let id = UUID()
        let ancient = Date(timeIntervalSince1970: -1e30)
        let first = try graded(id, .good, from: ScheduledCard(), at: ancient)
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [first]) == .consistent,
                "a control: the ancient grade alone replays")
        // What a scheduler would have said over an ordinary span, written as if it were this one's.
        let near = ScheduledCard(state: first.after.state, phase: first.after.phase,
                                 lastReview: previous.addingTimeInterval(-10 * Self.day), due: previous)
        let plausible = try MemoryScheduler().review(near, grade: .good, now: previous)
        let second = readBack(id, .good, at: previous, before: first.after, after: plausible)
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, second])
                == .inconsistent(event: second.id, reason: .notReproduced))
    }

    // MARK: - The chain

    /// **A card's own history, and nothing else, is a new card**: a schedule with no live grade
    /// behind it is one nobody can account for.
    @Test func anEmptyHistoryIsANewCardAndNothingElse() throws {
        let id = UUID()
        #expect(Replay.verdict(of: card(id, holding: ScheduledCard()), events: []) == .consistent)
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [])
                == .inconsistent(event: nil, reason: .cardIsElsewhere))
        #expect(Replay.verdict(of: card(id, holding: ScheduledCard()), events: [first])
                == .inconsistent(event: first.id, reason: .cardIsElsewhere))
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [first]) == .consistent)
    }

    /// **Two first grades of one card**: the offline-sync shape, two devices each introducing it.
    /// The second starts from `new`, and the chain says the card was not new by then.
    @Test func aSecondIntroductionStartsElsewhere() throws {
        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        let second = try graded(id, .good, from: ScheduledCard(), at: previous.addingTimeInterval(3_600))
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, second])
                == .inconsistent(event: second.id, reason: .startsElsewhere))
    }

    /// **A voided grade is no link.** Undo restores `before` and marks the event; the next grade
    /// starts from the state before it.
    @Test func aVoidedGradeIsNotALink() throws {
        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        let taken = try graded(id, .again, from: first.after, at: previous.addingTimeInterval(Self.day))
        let undone = readBack(id, .again, at: previous.addingTimeInterval(Self.day), before: taken.before,
                              after: taken.after, voided: true)
        let regraded = try graded(id, .good, from: first.after, at: previous.addingTimeInterval(2 * Self.day))
        #expect(Replay.verdict(of: card(id, holding: regraded.after), events: [first, undone, regraded])
                == .consistent)
        // **A control**: live, the taken-back grade is a link the regrade does not start from.
        #expect(Replay.verdict(of: card(id, holding: regraded.after), events: [first, taken, regraded])
                == .inconsistent(event: regraded.id, reason: .startsElsewhere))
    }

    /// **Practice is outside the chain**: it may sit anywhere in the history, it is no link, and
    /// the one thing asked of it is that it moved nothing.
    @Test func practiceIsInertAndNoLink() throws {
        let id = UUID()
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        let practised = readBack(id, .again, at: previous.addingTimeInterval(3_600), before: first.after,
                                 after: first.after, kind: .practice)
        let second = try graded(id, .good, from: first.after, at: previous.addingTimeInterval(3 * Self.day))
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, practised, second])
                == .consistent)
        // Not a link: a practice attempt recorded against some other state is still no break.
        let stray = readBack(id, .good, at: previous.addingTimeInterval(7_200), before: second.after,
                             after: second.after, kind: .practice)
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, stray, second])
                == .consistent)
        let moved = readBack(id, .again, at: previous.addingTimeInterval(3_600), before: first.after,
                             after: second.after, kind: .practice)
        #expect(Replay.verdict(of: card(id, holding: second.after), events: [first, moved, second])
                == .inconsistent(event: moved.id, reason: .practiceMoved))
    }

    /// **A version this build does not know is unreplayable, never consistent** — the card's or a
    /// grade's. A replay with today's rules over yesterday's history would answer, and wrongly.
    @Test func aHistoryOnlyAnUnknownSchedulerCanReplayIsUnreplayable() throws {
        let id = UUID(), later = "fsrs7-later-v1"
        let first = try graded(id, .good, from: ScheduledCard(), at: previous)
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [first]) == .consistent,
                "a control: the same history under the known version")
        let unknown = try graded(id, .good, from: ScheduledCard(), at: previous, version: later)
        #expect(Replay.verdict(of: card(id, holding: unknown.after), events: [unknown])
                == .unreplayable(.unknownSchedulerVersion(later)))
        #expect(Replay.verdict(of: card(id, holding: ScheduledCard(), version: later), events: [])
                == .unreplayable(.unknownSchedulerVersion(later)))
    }

    /// **A scheduler's identity names every parameter that changes a transition but retention**
    /// (WI-8), which an event keeps in a column of its own. The default configuration is `version`
    /// whatever its retention — the configuration the replay rebuilds — and any other cap or weights is
    /// a version the replay does not know, so its grade is unreplayable rather than a forgery.
    @Test func aSchedulersIdentityNamesEveryParameterButRetention() throws {
        #expect(try MemoryScheduler().identity == MemoryScheduler.version)
        #expect(try MemoryScheduler(retention: 0.8).identity == MemoryScheduler.version)
        var heavier = MemoryScheduler.defaultWeights
        heavier[2] = 3.0
        let others = [try MemoryScheduler(maximumDays: 1), try MemoryScheduler(maximumDays: 365),
                      try MemoryScheduler(weights: heavier)]
        #expect(Set(others.map(\.identity)).count == others.count, "two configurations share one identity")
        #expect(others.allSatisfy { $0.identity != MemoryScheduler.version && $0.identity.hasPrefix(MemoryScheduler.version) })
        #expect(try MemoryScheduler(maximumDays: 1).identity == others[0].identity, "one configuration, one identity")

        // A grade the capped scheduler computed, under its own identity: unreplayable. **The control**:
        // the same event under the default's identity is the forgery the replay would otherwise call it.
        let capped = others[0], id = UUID()
        let after = try capped.review(ScheduledCard(), grade: .good, now: previous)
        let own = readBack(id, .good, at: previous, before: ScheduledCard(), after: after, version: capped.identity)
        #expect(Replay.verdict(of: card(id, holding: own.after), events: [own])
                == .unreplayable(.unknownSchedulerVersion(capped.identity)))
        let misnamed = readBack(id, .good, at: previous, before: ScheduledCard(), after: after)
        #expect(Replay.verdict(of: card(id, holding: misnamed.after), events: [misnamed])
                == .inconsistent(event: misnamed.id, reason: .notReproduced))
    }

    /// **An event of another card is never part of this one's history**, whoever handed it over.
    @Test func anotherCardsEventIsNotThisCardsHistory() throws {
        let id = UUID()
        let first = try graded(UUID(), .good, from: ScheduledCard(), at: previous)
        #expect(Replay.verdict(of: card(id, holding: first.after), events: [first])
                == .inconsistent(event: first.id, reason: .anotherCardsEvent))
    }
}
