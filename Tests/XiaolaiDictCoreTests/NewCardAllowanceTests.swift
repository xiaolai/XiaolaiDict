import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import XiaolaiDictCore

/// The allowance, against a real ledger.
struct NewCardAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    @discardableResult
    /// **`when` is not decoration.** Without it a backlog fixture had to create a card now and
    /// then grade it two days earlier, so the test rested on the ledger accepting a review of a
    /// card that did not yet exist.
    private func save(_ ledger: Ledger, _ word: String, at when: Date? = nil) throws -> StudyCard {
        let when = when ?? now
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: when)
        return try ledger.card(of: note.id, at: when)
    }

    /// **The cap applies to new cards and to nothing else.** Due work is work the reader already
    /// took on; only first introductions are rationed.
    @Test func abatchTakesAtMostTheAllowanceInNewCards() throws {
        let ledger = try ledger()
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let batch = try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: 3, dayStart: now.addingTimeInterval(-3_600))
        #expect(batch.count == 3, "got \(batch.count)")
        #expect(batch.allSatisfy { $0.scheduled.phase == .new })
    }

    /// Cards already in progress are not rationed — they are due, and due work is not new work.
    @Test func dueWorkIsNotRationed() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        for index in 0..<4 {
            let card = try save(ledger, "seen\(index)")
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: 0,
                                 at: now, using: scheduler)
        }
        for index in 0..<4 { try save(ledger, "fresh\(index)") }

        let later = now.addingTimeInterval(3_600)
        let batch = try ledger.dueCards(at: later, limit: 20, dictionary: nil,
                                        newAllowance: 0, dayStart: now.addingTimeInterval(-3_600))
        #expect(batch.count == 4, "four cards in progress are due and none of them is new")
        // `.again` from `new` is a first introduction, so these are *learning*, not relearning —
        // a lapse is a fall out of `review` and nothing here has been reviewed.
        #expect(batch.allSatisfy { $0.scheduled.phase == .learning })
    }

    /// **The allowance is spent by introductions already made today**, so a second sitting on the
    /// same day does not hand out a second day's worth.
    @Test func thesecondSittingOfAdayGetsWhatIsLeft() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let dayStart = now.addingTimeInterval(-3_600)

        let first = try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: 5,
                                        dayStart: dayStart)
        #expect(first.count == 5)
        // Answer three of them: three introductions spent.
        for card in first.prefix(3) {
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                 expectedRevision: card.revision, at: now, using: scheduler)
        }
        #expect(try ledger.introductions(since: dayStart, dictionary: nil) == 3)

        let second = try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: 5,
                                         dayStart: dayStart)
        #expect(second.count == 2, "five minus three already introduced, got \(second.count)")
    }

    /// **Undoing a first review gives the allowance back**, because a voided introduction is not
    /// one — nothing has to remember to refund it.
    @Test func undoingAnIntroductionReturnsIt() throws {
        let ledger = try ledger()
        let card = try save(ledger, "fine")
        let dayStart = now.addingTimeInterval(-3_600)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        #expect(try ledger.introductions(since: dayStart, dictionary: nil) == 1)

        try ledger.undoLatestReview(ofCard: card.id, at: now)
        #expect(try ledger.introductions(since: dayStart, dictionary: nil) == 0)
    }

    /// Practice cannot introduce anything: it never touches a card with no memory state.
    @Test func practiceNeverSpendsTheAllowance() throws {
        let ledger = try ledger()
        let card = try save(ledger, "fine")
        let dayStart = now.addingTimeInterval(-3_600)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        _ = try ledger.practise(cardID: card.id, .good, eventID: UUID(), at: now)
        #expect(try ledger.introductions(since: dayStart, dictionary: nil) == 1,
                "practice counted as an introduction")
    }

    /// **What the surface counts and what the queue hands out must agree about the allowance.**
    /// The end of a batch says how much is still due, and a count that ignored the cap would
    /// promise work no sitting will ever be offered today — the review surface's one forbidden
    /// claim, said the other way round.
    @Test func thecountAndTheQueueAgreeAboutTheAllowance() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        for index in 0..<9 { try save(ledger, "word\(index)") }
        let dayStart = now.addingTimeInterval(-3_600)

        let opening = try ledger.queueCounts(at: now, dictionary: nil, newAllowance: 4,
                                             dayStart: dayStart)
        #expect(opening.due == 4, "nine saved, four allowed")
        #expect(opening.heldBack == 5, "and the other five are visible as held, not as missing")

        let batch = try ledger.dueCards(at: now, limit: 100, dictionary: nil, newAllowance: 4,
                                        dayStart: dayStart)
        #expect(batch.count == 4)
        for card in batch.prefix(2) {
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                 expectedRevision: card.revision, at: now, using: scheduler)
        }
        // Two spent; two of the allowance left, and the two answered are scheduled away.
        let after = try ledger.queueCounts(at: now, dictionary: nil, newAllowance: 4,
                                           dayStart: dayStart)
        #expect(after.due == 2)
        #expect(after.heldBack == 5)
        #expect(try ledger.dueCards(at: now, limit: 100, dictionary: nil, newAllowance: 4,
                                    dayStart: dayStart).count == 2)
    }

    /// **Fewer under backlog, and no second constant to get wrong.** C08 asks for the intake to
    /// shrink when the reader is behind; it already does, and not by a rule of its own. The queue
    /// orders new cards last and the batch has a size, so due work fills the sitting first and the
    /// new ones simply do not reach it. Nothing is spent either, because the allowance is counted
    /// at the grade and not at the draw.
    @Test func abacklogCrowdsOutNewCardsWithoutAruleOfItsOwn() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        // Introduced two days ago and answered `.again`, so they are long overdue *and* their
        // introductions belong to a day that is over.
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        for index in 0..<12 {
            let card = try save(ledger, "behind\(index)", at: twoDaysAgo)
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(),
                                 expectedRevision: card.revision, at: twoDaysAgo, using: scheduler)
        }
        for index in 0..<5 { try save(ledger, "fresh\(index)") }
        let dayStart = now.addingTimeInterval(-3_600)
        #expect(try ledger.introductions(since: dayStart, dictionary: nil) == 0,
                "today's allowance is intact")

        let batch = try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: 5,
                                        dayStart: dayStart)
        #expect(batch.count == 10)
        #expect(batch.allSatisfy { $0.scheduled.phase != .new },
                "the backlog fills the sitting; the new ones wait")
        // **The five are not held back — they are simply behind twelve.** The count says so, and
        // a surface that read this as "waiting for tomorrow" would be telling the reader to stop.
        let counts = try ledger.queueCounts(at: now, dictionary: nil, newAllowance: 5,
                                            dayStart: dayStart)
        #expect(counts.due == 17)
        #expect(counts.heldBack == 0)
    }

    /// Yesterday's introductions do not spend today's allowance.
    @Test func adayIsAday() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let yesterday = now.addingTimeInterval(-3_600)
        let batch = try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: 5,
                                        dayStart: yesterday)
        for card in batch {
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                 expectedRevision: card.revision, at: now, using: scheduler)
        }
        // **A real next-day sitting**: the boundary is a day on, and the question is asked after
        // it. Setting the boundary one second ahead of `now` and then asking at `now` tested a
        // day that had not begun — a shape no sitting can be in.
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(try ledger.introductions(since: tomorrow, dictionary: nil) == 0,
                "yesterday's five belong to yesterday")
        let next = try ledger.dueCards(at: tomorrow.addingTimeInterval(60), limit: 10,
                                       dictionary: nil, newAllowance: 5, dayStart: tomorrow)
        #expect(next.filter { $0.scheduled.phase == .new }.count == 3,
                "the three never introduced, and the allowance is whole again")
    }
}
