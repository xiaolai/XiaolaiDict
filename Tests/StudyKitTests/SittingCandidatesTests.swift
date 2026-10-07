import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import StudyKit

/// **The one read a Review sitting is planned from, and the SQL queue the plan is held to**
/// (review-module-plan §8.1, WI-2). `SittingPlannerTests` proves the planner's rules on values; these
/// prove the ledger hands it the right set, and that its order is the queue's with only one study
/// day's tie replaced.
struct SittingCandidatesTests {
    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func studyDay() throws -> StudyDay {
        StudyDay(timeZone: try #require(TimeZone(identifier: "UTC")), cutoffHour: 4)
    }

    @discardableResult
    private func ready(_ ledger: Ledger, _ word: String, dictionary: String = "noad") throws -> StudyCard {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: dictionary, entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
        return try ledger.card(of: note.id, at: now)
    }

    /// A card placed in `phase`, due at `due`, the way the ledger writes a schedule.
    private func place(_ ledger: Ledger, _ card: StudyCard, _ phase: SchedulePhase, due: Date) throws {
        try ledger.run("""
            UPDATE study_cards SET phase = ?, stability = 10.0, difficulty = 5.0, last_review = ?, due = ?
            WHERE id = ?
            """, bind: [.text(phase.rawValue), .real(due.addingTimeInterval(-10 * day).timeIntervalSince1970),
                        .real(due.timeIntervalSince1970), .text(card.id.uuidString)]) { _ in }
    }

    /// What the order is made of, below the tie: the phase's rank and the study day of `due`.
    private func rank(_ card: StudyCard, _ studyDay: StudyDay) -> String {
        let phase = switch card.scheduled.phase {
        case .learning, .relearning: 0
        case .review: 1
        case .new: 2
        }
        return "\(phase)@\(card.scheduled.due.map { studyDay.start(containing: $0).timeIntervalSince1970 } ?? -1)"
    }

    /// A ledger holding every phase, due across several study days, with ties inside two of them,
    /// and one card of each kind the queue must leave out.
    private func mixed(ties: Bool) throws -> Ledger {
        let ledger = try Ledger(path: ":memory:")
        try place(ledger, try ready(ledger, "relapse"), .relearning, due: now.addingTimeInterval(-1.5 * day))
        try place(ledger, try ready(ledger, "learn"), .learning, due: now.addingTimeInterval(-3_600))
        try place(ledger, try ready(ledger, "oldest"), .review, due: now.addingTimeInterval(-5 * day))
        try place(ledger, try ready(ledger, "older"), .review, due: now.addingTimeInterval(-3 * day))
        try place(ledger, try ready(ledger, "old"), .review, due: now.addingTimeInterval(-2 * day))
        try ready(ledger, "unseen")
        if ties {
            try place(ledger, try ready(ledger, "learn2"), .learning, due: now.addingTimeInterval(-1_800))
            for hour in 0..<4 {
                try place(ledger, try ready(ledger, "same\(hour)"), .review,
                          due: now.addingTimeInterval(-4 * day + TimeInterval(hour) * 600))
            }
            for index in 0..<3 { try ready(ledger, "unseen\(index)") }
        }
        // Left out by both: paused, put off, not yet due, and a note that is not askable.
        let paused = try ready(ledger, "paused")
        try place(ledger, paused, .review, due: now.addingTimeInterval(-day))
        try ledger.setPaused(true, ofCard: paused.id)
        let putOff = try ready(ledger, "putoff")
        try place(ledger, putOff, .review, due: now.addingTimeInterval(-day))
        try ledger.postpone(cardID: putOff.id, until: now.addingTimeInterval(day))
        try place(ledger, try ready(ledger, "later"), .review, due: now.addingTimeInterval(day))
        let unconfirmed = try ready(ledger, "unconfirmed")
        try ledger.run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                       bind: [.text(unconfirmed.noteID.uuidString)]) { _ in }
        return ledger
    }

    /// **Phase order identical to the SQL queue, ties aside.** Where every phase-and-day group holds
    /// one card the two orders are the same list; where a study day holds several, the sequence of
    /// groups is the same and only the order inside a group may differ — the one change R6 makes.
    @Test func thePlannerReproducesTheSqlQueueOrder() throws {
        let studyDay = try studyDay()
        for ties in [false, true] {
            let ledger = try mixed(ties: ties)
            let sql = try ledger.dueCards(at: now, limit: 100, dictionary: "noad",
                                          newAllowance: .max, dayStart: .distantPast)
            let planner = SittingPlanner(studyDay: studyDay, now: now, batchSize: 100, newCardsPerDay: .max)
            let planned = planner.reviewSitting(
                from: try ledger.sittingCandidates(dictionary: "noad", introducedSince: .distantPast)).batch
            #expect(sql.count == (ties ? 14 : 6), "the fixture is not the one described")
            #expect(Set(planned.map(\.id)) == Set(sql.map(\.id)), "ties \(ties): a different set of cards")
            #expect(planned.map { rank($0, studyDay) } == sql.map { rank($0, studyDay) },
                    "ties \(ties): the phase or study-day order differs from the SQL queue")
            if !ties {
                #expect(planned.map(\.id) == sql.map(\.id), "with no tie, the order is the queue's exactly")
            }
        }
        // **And under a batch and an allowance**, where which new cards are taken may differ but how
        // many, and in which groups, may not.
        let ledger = try mixed(ties: true)
        let sql = try ledger.dueCards(at: now, limit: 12, dictionary: "noad", newAllowance: 2,
                                      dayStart: studyDay.start(containing: now))
        let planned = SittingPlanner(studyDay: studyDay, now: now, batchSize: 12, newCardsPerDay: 2)
            .reviewSitting(from: try ledger.sittingCandidates(
                dictionary: "noad", introducedSince: studyDay.start(containing: now))).batch
        #expect(sql.count == 12)
        #expect(planned.map { rank($0, studyDay) } == sql.map { rank($0, studyDay) })
    }

    /// **The candidates are every card of an askable note — due or not, hidden or not, paused or
    /// not — and nothing else.** Due and hidden are questions about an instant, and the reminder asks
    /// them about a later one than the sitting; readiness is the ledger's question and is answered
    /// here, in SQL, once.
    @Test func theCandidatesAreEveryCardOfAnAskableNoteAndTodaysIntroductions() throws {
        let ledger = try Ledger(path: ":memory:")
        let due = try ready(ledger, "due")
        try place(ledger, due, .review, due: now.addingTimeInterval(-day))
        let later = try ready(ledger, "later")
        try place(ledger, later, .review, due: now.addingTimeInterval(3 * day))
        let putOff = try ready(ledger, "putoff")
        try ledger.postpone(cardID: putOff.id, until: now.addingTimeInterval(day))
        let paused = try ready(ledger, "paused")
        try ledger.setPaused(true, ofCard: paused.id)
        let fresh = try ready(ledger, "fresh")
        let unconfirmed = try ready(ledger, "unconfirmed")
        try ledger.run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                       bind: [.text(unconfirmed.noteID.uuidString)]) { _ in }
        let archived = try ready(ledger, "archived")
        try ledger.setEnrollment(.archived, of: archived.noteID)
        let elsewhere = try ready(ledger, "elsewhere", dictionary: "oxford")

        let candidates = try ledger.sittingCandidates(dictionary: "noad", introducedSince: .distantPast)
        #expect(Set(candidates.cards.map(\.id)) == [due.id, later.id, putOff.id, paused.id, fresh.id])
        #expect(candidates.introducedToday == 0)
        // Read as the queue reads a card: the schedule, the pause and the put-off all came through.
        let byID = Dictionary(uniqueKeysWithValues: candidates.cards.map { ($0.id, $0) })
        #expect(byID[paused.id]?.isPaused == true)
        #expect(byID[putOff.id]?.hiddenUntil == now.addingTimeInterval(day))
        #expect(byID[later.id]?.scheduled.due == now.addingTimeInterval(3 * day))
        #expect(Set(try ledger.sittingCandidates(dictionary: nil, introducedSince: .distantPast).cards.map(\.id))
                == [due.id, later.id, putOff.id, paused.id, fresh.id, elsewhere.id],
                "no scope is every namespace")

        // **Today's introductions come with the cards**, counted from the start the caller names.
        _ = try ledger.grade(cardID: fresh.id, .good, eventID: UUID(), expectedRevision: fresh.revision,
                             at: now, using: try MemoryScheduler())
        #expect(try ledger.sittingCandidates(dictionary: "noad", introducedSince: now.addingTimeInterval(-3_600))
            .introducedToday == 1)
        #expect(try ledger.sittingCandidates(dictionary: "noad", introducedSince: now.addingTimeInterval(3_600))
            .introducedToday == 0, "an introduction before the day began is not today's")
        #expect(try ledger.sittingCandidates(dictionary: "oxford", introducedSince: .distantPast)
            .introducedToday == 0, "nor is another dictionary's")
    }

    /// **The counts every surface shows are the planner's**, so the Library's badge, the
    /// instrument's report and the sitting cannot disagree about one queue. Checked against the
    /// plan on a fixture where each filter — paused, put off, not yet due, unaskable, the
    /// allowance — changes the number.
    @Test func queueCountsAreThePlannersCounts() throws {
        let studyDay = try studyDay()
        let ledger = try mixed(ties: true)
        let dayStart = studyDay.start(containing: now)
        for allowance in [0, 2, 5, Int.max] {
            let counts = try ledger.queueCounts(at: now, dictionary: "noad", newAllowance: allowance,
                                                dayStart: dayStart)
            let plan = SittingPlanner(studyDay: studyDay, now: now, batchSize: 10, newCardsPerDay: allowance)
                .reviewSitting(from: try ledger.sittingCandidates(dictionary: "noad", introducedSince: dayStart))
            #expect(counts == plan.counts, "allowance \(allowance)")
        }
        // 10 due cards that are not new, and 4 new: the numbers, not merely their agreement.
        #expect(try ledger.queueCounts(at: now, dictionary: "noad", newAllowance: 3, dayStart: dayStart)
                == QueueCounts(due: 10 + 3, heldBack: 1))
    }
}
