import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import XiaolaiDictCore

/// **The ledger's own history, replayed by `integrity()`** (review-module-plan §7.2, WI-9b).
///
/// `Replay` is pure and `ReplayTests` holds its arithmetic. These hold the ledger to it: the order
/// events are read in, what undo, practice, pausing and postponing leave behind, and what reaches
/// `integrity()` — a broken history as a problem, a legacy one as a named fact that is not one.
struct StudyReplayTests {
    private static let day: TimeInterval = 86_400
    /// Plan §12's boundary: a storable last review, and the instant one ulp short of a day after it
    /// in memory that the ledger reads back as exactly a day.
    private let previous = Date(timeIntervalSinceReferenceDate: 800_879_356.388_499_7)
    private let original = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)

    private func ready(_ ledger: Ledger, _ lemma: String = "fine", at when: Date) throws -> StudyCard {
        let lookup = try ledger.record(LookupRecord(
            surface: lemma, lemma: lemma, context: "He paid the \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(lemma)", senseKey: "e-\(lemma).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: when)
        return try ledger.card(of: note.id, at: when)
    }

    @discardableResult
    private func grade(_ ledger: Ledger, _ id: UUID, _ grade: Grade, at when: Date) throws -> ReviewEvent {
        let card = try #require(try ledger.card(id: id))
        return try ledger.grade(cardID: id, grade, eventID: UUID(), expectedRevision: card.revision,
                                at: when, using: try MemoryScheduler())
    }

    /// **A grade as `grade` wrote it before WI-9a**: scheduled with the in-memory instant, stored at
    /// its encoding, the card written in the same shape. Inserted by hand, because the ledger no
    /// longer writes one — and every reader who graded before 2026-10-04 has some.
    private func gradeBeforeWI9a(_ ledger: Ledger, _ id: UUID, _ grade: Grade, at when: Date) throws -> UUID {
        let card = try #require(try ledger.card(id: id))
        let before = card.scheduled
        let after = try MemoryScheduler().review(before, grade: grade, now: when)
        let eventID = UUID()
        try ledger.run("""
            INSERT INTO review_events
                (id, card_id, grade, reviewed_at, before_phase, before_stability, before_difficulty,
                 before_last_review, before_due, after_phase, after_stability, after_difficulty,
                 after_due, scheduler_version, retention, card_revision, kind, voided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0.9, ?, 'graded', NULL)
            """, bind: [.text(eventID.uuidString), .text(id.uuidString), .integer(grade.rawValue),
                        .real(when.timeIntervalSince1970), .text(before.phase.rawValue),
                        .optionalReal(before.state?.stability), .optionalReal(before.state?.difficulty),
                        .optionalReal(before.lastReview?.timeIntervalSince1970),
                        .optionalReal(before.due?.timeIntervalSince1970), .text(after.phase.rawValue),
                        .optionalReal(after.state?.stability), .optionalReal(after.state?.difficulty),
                        .optionalReal(after.due?.timeIntervalSince1970), .text(MemoryScheduler.version),
                        .integer(card.revision)]) { _ in }
        try ledger.run("""
            UPDATE study_cards SET phase = ?, stability = ?, difficulty = ?, last_review = ?, due = ?,
                                   revision = revision + 1
            WHERE id = ?
            """, bind: [.text(after.phase.rawValue), .optionalReal(after.state?.stability),
                        .optionalReal(after.state?.difficulty), .optionalReal(after.lastReview?.timeIntervalSince1970),
                        .optionalReal(after.due?.timeIntervalSince1970), .text(id.uuidString)]) { _ in }
        return eventID
    }

    private func verdict(_ ledger: Ledger, _ id: UUID) throws -> Replay.Verdict {
        try #require(try ledger.replayVerdicts()[id])
    }

    private func replayProblems(_ ledger: Ledger) throws -> [String] {
        try ledger.integrity().filter { $0.hasPrefix("replay") }
    }

    // MARK: - The instant

    /// **A grade written since WI-9a is exact, not legacy** — on the very boundary that makes an older
    /// one legacy. `grade` schedules with the stored instant, so the decoded instant reproduces it.
    @Test func aRecordedWrittenByWI9aIsExactNotLegacy() throws {
        try #require(ReviewInstant.stored(original) != original, "the fixture's instant survives storage")
        let today = try Ledger(path: ":memory:")
        let card = try ready(today, at: previous)
        try grade(today, card.id, .good, at: previous)
        try grade(today, card.id, .good, at: original)
        #expect(try verdict(today, card.id) == .consistent)
        #expect(try today.integrity().isEmpty)

        // **The control**: the same two grades, the second written the way it was before WI-9a.
        let legacy = try Ledger(path: ":memory:")
        let old = try ready(legacy, at: previous)
        try grade(legacy, old.id, .good, at: previous)
        let second = try gradeBeforeWI9a(legacy, old.id, .good, at: original)
        #expect(try verdict(legacy, old.id) == .consistentAtLegacyPrecision(events: [second]))
    }

    /// **A legacy event is named and is not a problem.** The precision lost is bounded and checked;
    /// only *which* of three instants the reader's clock said is unknowable. A ledger whose history
    /// is whole reports nothing — the reader's own, with its one graded event, is that ledger.
    @Test func aLegacyEventIsNamedAndIntegrityStaysClean() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger, at: previous)
        try grade(ledger, card.id, .good, at: previous)
        let legacy = try gradeBeforeWI9a(ledger, card.id, .good, at: original)
        let exact = try ready(ledger, "hold", at: previous)
        try grade(ledger, exact.id, .good, at: original)

        let verdicts = try ledger.replayVerdicts()
        #expect(verdicts[card.id] == .consistentAtLegacyPrecision(events: [legacy]))
        #expect(verdicts[exact.id] == .consistent)
        #expect(verdicts.count == 2, "every card has a verdict")
        #expect(try ledger.integrity().isEmpty)
    }

    // MARK: - Order

    /// **Tied timestamps replay in rowid order**, which is the order they were written and the one
    /// undo walks backwards. At one instant Good-then-Again and Again-then-Good are different cards
    /// (S 0.7751 relearning against S 0.2467 review, `Tools/fsrs/fsrs6.py`), so the order is
    /// load-bearing — shown by swapping two rowids and watching the replay break.
    @Test func tiedTimestampsReplayInRowidOrder() throws {
        let ledger = try Ledger(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        // A card graded first and removed later, so its event leaves a gap below the tied ones.
        let gone = try ready(ledger, "gone", at: at)
        try grade(ledger, gone.id, .good, at: at)
        let goodFirst = try ready(ledger, "fine", at: at)
        let first = try grade(ledger, goodFirst.id, .good, at: at)
        try grade(ledger, goodFirst.id, .again, at: at)
        let againFirst = try ready(ledger, "hold", at: at)
        try grade(ledger, againFirst.id, .again, at: at)
        try grade(ledger, againFirst.id, .good, at: at)

        let one = try #require(try ledger.card(id: goodFirst.id)).scheduled
        let other = try #require(try ledger.card(id: againFirst.id)).scheduled
        #expect(one.state?.stability == 0.775_083_982_855_898_3 && one.phase == .relearning)
        #expect(other.state?.stability == 0.246_689_187_775_672_72 && other.phase == .review)
        #expect(try ledger.integrity().isEmpty)

        // **`VACUUM` keeps the order.** `eraseReadingData` runs one on the reader's ledger, and SQLite
        // documents that it may renumber the rowids of a table with no `INTEGER PRIMARY KEY`.
        try ledger.run("DELETE FROM study_cards WHERE id = ?", bind: [.text(gone.id.uuidString)]) { _ in }
        try ledger.execute("VACUUM")
        #expect(try ledger.integrity().isEmpty, "a vacuum reordered two tied grades")

        // The first grade written becomes the last read: the replay must notice.
        try ledger.run("UPDATE review_events SET rowid = (SELECT MAX(rowid) + 1 FROM review_events) WHERE id = ?",
                       bind: [.text(first.id.uuidString)]) { _ in }
        let swapped = try verdict(ledger, goodFirst.id)
        guard case .inconsistent(_, .startsElsewhere) = swapped else {
            Issue.record("swapping two tied grades replayed as \(swapped)")
            return
        }
        #expect(try verdict(ledger, againFirst.id) == .consistent)
    }

    // MARK: - What leaves no link

    /// **Practice is outside the chain**: recorded, inert, and no link between the grades either side.
    @Test func practiceIsOutsideTheChain() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        try grade(ledger, card.id, .good, at: start)
        let practised = try ledger.practise(cardID: card.id, .again, eventID: UUID(),
                                            at: start.addingTimeInterval(3_600))
        try ledger.practise(cardID: card.id, .good, eventID: UUID(), at: start.addingTimeInterval(7_200))
        try grade(ledger, card.id, .good, at: start.addingTimeInterval(3 * Self.day))
        #expect(try ledger.reviews(ofCard: card.id).count == 4)
        #expect(try verdict(ledger, card.id) == .consistent)
        #expect(try ledger.integrity().isEmpty)

        // A practice row that claims to have moved the card is the one thing practice may not be.
        try ledger.run("UPDATE review_events SET after_stability = after_stability + 1 WHERE id = ?",
                       bind: [.text(practised.id.uuidString)]) { _ in }
        #expect(try verdict(ledger, card.id) == .inconsistent(event: practised.id, reason: .practiceMoved))
        #expect(try replayProblems(ledger).count == 1)
    }

    /// **Undo, then grade again, replays**: the taken-back grade stays in the history, void, and the
    /// next one starts from the state before it — down to a card walked all the way back to new.
    @Test func undoThenRegradeReplays() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        try grade(ledger, card.id, .good, at: start)
        try grade(ledger, card.id, .again, at: start.addingTimeInterval(2 * Self.day))
        try ledger.undoLatestReview(ofCard: card.id, at: start.addingTimeInterval(2 * Self.day + 60))
        try grade(ledger, card.id, .good, at: start.addingTimeInterval(3 * Self.day))
        #expect(try ledger.reviews(ofCard: card.id).filter(\.isVoid).count == 1)
        #expect(try verdict(ledger, card.id) == .consistent)

        try ledger.undoLatestReview(ofCard: card.id, at: start.addingTimeInterval(4 * Self.day))
        try ledger.undoLatestReview(ofCard: card.id, at: start.addingTimeInterval(4 * Self.day))
        #expect(try #require(try ledger.card(id: card.id)).scheduled == ScheduledCard(), "back to new")
        #expect(try verdict(ledger, card.id) == .consistent)
        try grade(ledger, card.id, .hard, at: start.addingTimeInterval(5 * Self.day))
        #expect(try verdict(ledger, card.id) == .consistent)
        #expect(try ledger.integrity().isEmpty)
    }

    /// **Pausing and postponing are eligibility, not memory**: they move the revision and write no
    /// event, so the replay has nothing to say about them and must say nothing.
    @Test func pauseAndPostponeAreNotReplayed() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        try grade(ledger, card.id, .good, at: start)
        try ledger.setPaused(true, ofCard: card.id)
        try ledger.postpone(cardID: card.id, until: start.addingTimeInterval(5 * Self.day))
        try ledger.setPaused(true, ofNotes: [card.noteID])
        let states = try ledger.pauseStates(ofCardsUnder: [card.noteID])
        try ledger.setPaused(false, ofNotes: [card.noteID])
        try ledger.restorePauseStates(states.mapValues { _ in false })
        try ledger.postpone(cardID: card.id, until: nil)
        let moved = try #require(try ledger.card(id: card.id))
        try #require(moved.revision > 2, "the fixture did not move the revision")
        #expect(try ledger.reviews(ofCard: card.id).count == 1, "and wrote no event")
        #expect(try verdict(ledger, card.id) == .consistent)
        try grade(ledger, card.id, .good, at: start.addingTimeInterval(6 * Self.day))
        #expect(try verdict(ledger, card.id) == .consistent)
        #expect(try ledger.integrity().isEmpty)
    }

    // MARK: - What turns integrity red

    /// **Two live first grades of one card** — the offline-sync shape, a second device introducing a
    /// card the first already had. The second starts from `new`; the chain says it was not.
    @Test func twoLiveIntroductionsOfOneCardAreInconsistent() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        try grade(ledger, card.id, .good, at: start)
        #expect(try ledger.integrity().isEmpty, "a control: one introduction is a whole history")
        // The other device's card never saw the first grade.
        try ledger.run("""
            UPDATE study_cards SET phase = 'new', stability = NULL, difficulty = NULL, last_review = NULL,
                                   due = NULL
            WHERE id = ?
            """, bind: [.text(card.id.uuidString)]) { _ in }
        let second = try grade(ledger, card.id, .good, at: start.addingTimeInterval(3_600))
        #expect(try verdict(ledger, card.id) == .inconsistent(event: second.id, reason: .startsElsewhere))
        let problems = try replayProblems(ledger)
        #expect(problems.count == 1 && problems.allSatisfy { $0.contains(second.id.uuidString) },
                "got \(problems)")
    }

    /// **An edited number is found** — on the card, and on an event.
    @Test func anEditedStabilityTurnsIntegrityRed() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        let first = try grade(ledger, card.id, .good, at: start)
        let last = try grade(ledger, card.id, .good, at: start.addingTimeInterval(3 * Self.day))
        #expect(try ledger.integrity().isEmpty, "a control: the untouched history is whole")

        try ledger.run("UPDATE study_cards SET stability = stability * 1.01 WHERE id = ?",
                       bind: [.text(card.id.uuidString)]) { _ in }
        #expect(try verdict(ledger, card.id) == .inconsistent(event: last.id, reason: .cardIsElsewhere))
        #expect(try replayProblems(ledger).count == 1)

        try ledger.run("UPDATE study_cards SET stability = ? WHERE id = ?",
                       bind: [.optionalReal(last.after.state?.stability), .text(card.id.uuidString)]) { _ in }
        #expect(try ledger.integrity().isEmpty, "put back, it is whole again")
        try ledger.run("UPDATE review_events SET after_stability = after_stability * 1.01 WHERE id = ?",
                       bind: [.text(first.id.uuidString)]) { _ in }
        #expect(try verdict(ledger, card.id) == .inconsistent(event: first.id, reason: .notReproduced))
        #expect(try replayProblems(ledger).count == 1)
    }

    /// **A scheduler this build does not know is unreplayable, never consistent**, and integrity
    /// says so — on an event, and on a card with no events at all.
    @Test func anUnknownSchedulerVersionIsUnreplayableNotConsistent() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let graded = try ready(ledger, at: start)
        let event = try grade(ledger, graded.id, .good, at: start)
        let fresh = try ready(ledger, "hold", at: start)
        #expect(try ledger.integrity().isEmpty, "a control: the same ledger under the known version")

        let later = "fsrs7-later-v1"
        try ledger.run("UPDATE review_events SET scheduler_version = ? WHERE id = ?",
                       bind: [.text(later), .text(event.id.uuidString)]) { _ in }
        try ledger.run("UPDATE study_cards SET scheduler_version = ? WHERE id = ?",
                       bind: [.text(later), .text(fresh.id.uuidString)]) { _ in }
        #expect(try verdict(ledger, graded.id) == .unreplayable(.unknownSchedulerVersion(later)))
        #expect(try verdict(ledger, fresh.id) == .unreplayable(.unknownSchedulerVersion(later)))
        let problems = try replayProblems(ledger)
        #expect(problems.count == 2 && problems.allSatisfy { $0.contains("unreplayable") }, "got \(problems)")
    }

    /// **A grade scheduled by a configuration the replay does not rebuild is unreplayable, never
    /// inconsistent** (WI-8). `grade` takes any scheduler, and a cap of one day schedules a first Good
    /// at 1,800,000,000 for 1,800,086,400 where the default schedules 1,800,172,800. The event keeps
    /// its retention and nothing else of the configuration, so a replay with the default cap would call
    /// a genuine grade a forgery. The version the event records is what says it cannot be re-run.
    @Test func aGradeByANonDefaultSchedulerIsUnreplayableNotInconsistent() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let capped = try MemoryScheduler(maximumDays: 1)
        var weights = MemoryScheduler.defaultWeights
        weights[2] = 3.0
        for scheduler in [capped, try MemoryScheduler(weights: weights)] {
            let ledger = try Ledger(path: ":memory:")
            let card = try ready(ledger, at: start)
            let event = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                                         at: start, using: scheduler)
            #expect(event.schedulerVersion != MemoryScheduler.version,
                    "a configuration this build does not replay recorded the default's version")
            #expect(try verdict(ledger, card.id) == .unreplayable(.unknownSchedulerVersion(event.schedulerVersion)))
            let problems = try replayProblems(ledger)
            #expect(problems.count == 1 && problems.allSatisfy { $0.contains("unreplayable") }, "got \(problems)")
        }
        // The cap is what moved the transition: the fixture would prove nothing if it scheduled alike.
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger, at: start)
        let event = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                                     at: start, using: capped)
        #expect(event.after.due == Date(timeIntervalSince1970: 1_800_086_400))
        #expect(try MemoryScheduler().review(ScheduledCard(), grade: .good, now: start).due
                == Date(timeIntervalSince1970: 1_800_172_800))

        // **The controls**: retention is a column of its own, so a scheduler that differs only in it is
        // the default configuration and replays exactly — and so does the default itself.
        for scheduler in [try MemoryScheduler(retention: 0.8), try MemoryScheduler()] {
            let other = try Ledger(path: ":memory:")
            let fresh = try ready(other, at: start)
            let graded = try other.grade(cardID: fresh.id, .good, eventID: UUID(), expectedRevision: fresh.revision,
                                         at: start, using: scheduler)
            #expect(graded.schedulerVersion == MemoryScheduler.version)
            #expect(try verdict(other, fresh.id) == .consistent)
        }
    }

    /// **A memory state is both of its numbers or neither, in an event row as on a card** (WI-8). The
    /// decoder read `before_difficulty` only when `before_stability` was there, so a row with a
    /// difficulty and no stability decoded exactly as the genuine one did, and the replay — handed
    /// identical inputs — called the history whole. A pair the ledger never writes is corruption, and
    /// it throws, as every other unreadable row does (WI-1).
    @Test func anEventRowWithHalfAMemoryStateIsCorrupt() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // `review_events` has no CHECK on any of these, so each is one plain UPDATE away.
        let edits = [
            "UPDATE review_events SET before_difficulty = 9 WHERE id = ?",
            "UPDATE review_events SET before_stability = 9 WHERE id = ?",
            // No memory state on a card that has been reviewed, and one on a card that is `new`: the
            // two shapes the card table's own CHECK refuses, before and after alike.
            "UPDATE review_events SET before_phase = 'learning' WHERE id = ?",
            "UPDATE review_events SET after_phase = 'new' WHERE id = ?",
        ]
        for edit in edits {
            let ledger = try Ledger(path: ":memory:")
            let card = try ready(ledger, at: start)
            let event = try grade(ledger, card.id, .good, at: start)
            #expect(try ledger.integrity().isEmpty, "a control: the untouched history is whole")
            try ledger.run(edit, bind: [.text(event.id.uuidString)]) { _ in }
            #expect(throws: LedgerError.corruptRow("review_events \(event.id.uuidString)"), "\(edit)") {
                try ledger.integrity()
            }
        }
    }

    /// **A card row with half a memory state is corrupt too**, though the card table's CHECK refuses to
    /// write one: the decoder is the last reader, and it must not answer a difficulty of zero for a
    /// column that is NULL.
    @Test func aCardRowWithHalfAMemoryStateIsCorrupt() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for edit in ["UPDATE study_cards SET difficulty = NULL WHERE id = ?",
                     "UPDATE study_cards SET stability = NULL WHERE id = ?",
                     "UPDATE study_cards SET phase = 'new' WHERE id = ?"] {
            let ledger = try Ledger(path: ":memory:")
            let card = try ready(ledger, at: start)
            try grade(ledger, card.id, .good, at: start)
            #expect(try ledger.card(id: card.id) != nil, "a control: the graded card reads")
            try ledger.execute("PRAGMA ignore_check_constraints = ON")
            try ledger.run(edit, bind: [.text(card.id.uuidString)]) { _ in }
            #expect(throws: LedgerError.corruptRow("study_cards \(card.id.uuidString)"), "\(edit)") {
                try ledger.card(id: card.id)
            }
        }
    }

    /// **A row the schema cannot read is still corruption**, not a card with a shorter history
    /// (WI-1). The replay reads events through the one decoder, so it throws rather than skipping.
    @Test func aDamagedEventRowStillThrowsFromTheReplay() throws {
        let ledger = try Ledger(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let card = try ready(ledger, at: start)
        let event = try grade(ledger, card.id, .good, at: start)
        try ledger.run("UPDATE review_events SET before_phase = 'forgotten' WHERE id = ?",
                       bind: [.text(event.id.uuidString)]) { _ in }
        #expect(throws: LedgerError.corruptRow("review_events \(event.id.uuidString)")) {
            try ledger.integrity()
        }
    }
}
