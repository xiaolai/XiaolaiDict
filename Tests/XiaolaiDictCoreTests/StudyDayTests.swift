import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **The daily new-card allowance** (C08, and §10.4/§10.7 of the scheduler specification).
///
/// A P0 row that went unbuilt through WI-003: without it a first session is ten cards the reader
/// has never seen, all of which come back tomorrow, and the day after that they have twenty. The
/// allowance is the only thing standing between "I saved some words" and a backlog that grows
/// faster than anyone answers it.
struct StudyDayTests {
    /// 2027-01-15 12:00 UTC, built from its components rather than an epoch literal so the
    /// arithmetic below can be checked by eye against the comments.
    private let noon: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
    }()

    private func utc(_ cutoff: Int = 4) -> StudyDay {
        StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: cutoff)
    }

    /// **Before the cutoff belongs to yesterday**, which is the whole point of a boundary that is
    /// not midnight: someone reviewing at half past midnight is finishing the day they were awake
    /// for, and handing them a second day's new cards then is the opposite of helpful.
    @Test func atimeBeforeTheCutoffBelongsToTheDayBefore() {
        let day = utc()
        let start = day.start(containing: noon)
        // 04:00 the same day.
        #expect(start == noon.addingTimeInterval(-8 * 3_600))

        let oneAM = noon.addingTimeInterval(13 * 3_600)  // 01:00 the next calendar day
        #expect(day.start(containing: oneAM) == start, "01:00 is still the previous study day")

        let fiveAM = noon.addingTimeInterval(17 * 3_600)  // 05:00 the next calendar day
        #expect(day.start(containing: fiveAM) == start.addingTimeInterval(86_400),
                "05:00 has crossed into the next study day")
    }

    /// Exactly at the cutoff is the new day, not the old one.
    @Test func thecutoffInstantItselfStartsTheNewDay() {
        let day = utc()
        let start = day.start(containing: noon)
        #expect(day.start(containing: start) == start)
        #expect(day.start(containing: start.addingTimeInterval(-1)) == start.addingTimeInterval(-86_400))
    }

    /// **The cutoff is 04:00 on every day of the year, including the two that are not 24 hours
    /// long.** Adding `4 * 3600` to midnight is real-time arithmetic over a local-time boundary:
    /// on a spring-forward day an hour is missing, so it lands at 05:00, and on a fall-back day
    /// an hour repeats, so it lands at 03:00. A reader in a DST zone got a day that started an
    /// hour early or an hour late, twice a year, silently — and the allowance turns over on it.
    @Test func thecutoffIs0400OnDaylightSavingDaysToo() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let day = StudyDay(timeZone: zone, cutoffHour: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        // 2026-03-08 springs forward at 02:00; 2026-11-01 falls back at 02:00.
        for (month, dayOfMonth) in [(3, 8), (11, 1)] {
            let noon = try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: dayOfMonth, hour: 12)))
            let start = day.start(containing: noon)
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            #expect(parts.hour == 4 && parts.minute == 0,
                    "2026-\(month)-\(dayOfMonth): the day started at \(parts.hour ?? -1):\(parts.minute ?? -1)")
            #expect(parts.day == dayOfMonth, "and on the day the reader is in")
        }
    }

    /// **A day before a short day is still one day.** Stepping back by 86,400 seconds from a
    /// cutoff lands an hour out whenever a transition falls between them.
    @Test func theDayBeforeAdaylightSavingDayEndsAtItsOwnCutoff() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let day = StudyDay(timeZone: zone, cutoffHour: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // 01:00 on the spring-forward day belongs to the day before, which began at 04:00 on the 7th.
        let smallHours = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1)))
        let parts = calendar.dateComponents([.month, .day, .hour], from: day.start(containing: smallHours))
        #expect(parts.day == 7 && parts.hour == 4,
                "started at 2026-\(parts.month ?? -1)-\(parts.day ?? -1) \(parts.hour ?? -1):00")
    }

    /// A cutoff of midnight is allowed and means what it says; nonsense is clamped rather than
    /// refused, because this is a preference and not a boundary anything hostile reaches.
    /// **Decoding goes through the clamp too.** Synthesised `Codable` assigns stored properties
    /// directly, so a persisted 99 came back as 99 and the day boundary landed days away.
    @Test func adecodedCutoffIsClampedLikeAconstructedOne() throws {
        let json = Data(#"{"timeZone":{"identifier":"UTC"},"cutoffHour":99}"#.utf8)
        let decoded = try JSONDecoder().decode(StudyDay.self, from: json)
        #expect(decoded.cutoffHour == 23, "decoding bypassed the clamp")

        // And a round trip of a legitimate value is unchanged.
        let original = StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: 4)
        let back = try JSONDecoder().decode(StudyDay.self, from: try JSONEncoder().encode(original))
        #expect(back == original)
    }

    @Test func anOutOfRangeCutoffIsClamped() {
        #expect(StudyDay(cutoffHour: -3).cutoffHour == 0)
        #expect(StudyDay(cutoffHour: 99).cutoffHour == 23)
        let midnight = StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(midnight.start(containing: noon) == calendar.startOfDay(for: noon))
    }
}

/// The allowance, against a real ledger.
struct NewCardAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String) throws -> StudyCard {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
        return try ledger.card(of: note.id, at: now)
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
            let card = try save(ledger, "behind\(index)")
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
        let today = now.addingTimeInterval(1)
        #expect(try ledger.introductions(since: today, dictionary: nil) == 0)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: 5,
                                    dayStart: today).count == 3, "the remaining three, not five")
    }
}
