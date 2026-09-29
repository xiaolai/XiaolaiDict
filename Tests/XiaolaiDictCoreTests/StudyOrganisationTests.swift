import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **WI-007: what the reader organises, what is suggested, and what the numbers may claim.**
///
/// The last is the part with a rule in it. A figure about memory is the easiest thing in this
/// project to overstate, and the tests here are mostly about what a number refuses to say.
struct StudyOrganisationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String, at when: Date? = nil,
                      source: String = "com.apple.Safari") throws -> StudyNote {
        let when = when ?? now
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: source, name: source),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: when)
    }

    private func read(_ ledger: Ledger, _ word: String, at when: Date,
                      source: String = "com.apple.Safari") throws {
        _ = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: source, name: source),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
    }

    // MARK: - A card the reader wrote (C07)

    /// **A custom target is a kind of its own**, never a phrase with no locators: a phrase is the
    /// publisher's spelling and this is the reader's, and one must never read as the other.
    @Test func areaderAuthoredCardIsItsOwnKindAndNeedsNoLookup() throws {
        let ledger = try ledger()
        let lookup = try ledger.record(LookupRecord(
            surface: "anything", lemma: "anything", context: "A sentence.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let own = try ledger.enroll(
            .custom(dictionary: "noad", text: "put up with"), issuer: .live, language: "en",
            chosenBy: .reader, answer: StudyAnswer(origin: .reader, text: "tolerate"),
            lookupID: lookup, at: now)
        // A phrase with the same words is a different target, because it is a different claim.
        let publishers = try ledger.enroll(
            .phrase(dictionary: "noad", text: "put up with"), issuer: .inventory, language: "en",
            chosenBy: nil, answer: StudyAnswer(origin: .dictionary, text: "tolerate"),
            lookupID: lookup, at: now)
        #expect(own.id != publishers.id)
        #expect(try ledger.notes().count == 2)

        // **And it stands without a reading**: its cue is the reader's own words, so demanding a
        // lookup for it would make the feature unusable the moment it was built.
        try ledger.deleteReading(lookups: [lookup])
        #expect(try ledger.readiness(of: own.id) == .ready)
        #expect(try ledger.readiness(of: publishers.id) == .needsRepair, "a citation still needs one")
        #expect(try ledger.askableNoteIDs() == [own.id])
    }

    // MARK: - Two questions about one note (K07, R08)

    /// A second prompt has **its own schedule**, because recognising a word and producing it are
    /// different things to know.
    @Test func asiblingCardSchedulesSeparately() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let meaning = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let production = try ledger.card(of: note.id, prompt: .production, at: now)
        #expect(meaning.id != production.id)

        _ = try ledger.grade(cardID: meaning.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try MemoryScheduler())
        #expect(try #require(try ledger.card(id: production.id)).scheduled.phase == .new,
                "grading one sibling scheduled the other")
    }

    /// **R08: one card per note in a batch.** Asking both siblings in one sitting asks the reader
    /// the same thing twice with the answer fresh, which measures the sitting and not their memory.
    @Test func abatchHoldsAtMostOneCardPerNote() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let other = try save(ledger, "hold")
        try ledger.card(of: note.id, prompt: .meaning, at: now)
        try ledger.card(of: note.id, prompt: .production, at: now)
        try ledger.card(of: other.id, prompt: .meaning, at: now)

        let batch = try ledger.dueCards(at: now, limit: 10, dictionary: nil)
        #expect(batch.count == 2, "got \(batch.count) cards for 2 notes")
        #expect(Set(batch.map(\.noteID)).count == 2)
        // The sibling is not dropped — it is still due, and the next batch can have it.
        let answered = try #require(batch.first { $0.noteID == note.id })
        _ = try ledger.grade(cardID: answered.id, .good, eventID: UUID(),
                             expectedRevision: answered.revision, at: now, using: try MemoryScheduler())
        let next = try ledger.dueCards(at: now, limit: 10, dictionary: nil)
        #expect(next.contains { $0.noteID == note.id }, "the sibling never came back")
    }

    // MARK: - Practice (R10)

    /// **Practice is recorded and inert.** It happened — it affects the reader's real memory — and
    /// it moves no schedule and enters no retention figure.
    @Test func practiceChangesNothingAndIsStillWrittenDown() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        let scheduled = try #require(try ledger.card(id: card.id)).scheduled

        _ = try ledger.practise(cardID: card.id, .again, eventID: UUID(), at: now)
        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled,
                "practice moved the schedule")
        let events = try ledger.reviews(ofCard: card.id)
        #expect(events.count == 2)
        #expect(events.last?.kind == .practice)
        #expect(try ledger.retention(dictionary: nil).practice == 1, "and it is counted as excluded")
    }

    /// A card that has never been reviewed cannot be practised: its first attempt **is** its first
    /// review, and there is no memory state to leave unchanged.
    @Test func anUnreviewedCardCannotBePractised() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        #expect(throws: ReviewError.notYetReviewed(card.id)) {
            try ledger.practise(cardID: card.id, .good, eventID: UUID(), at: self.now)
        }
    }

    // MARK: - What the numbers may claim (U03)

    /// **Every exclusion is counted, and the rate is nil when there is nothing to divide by.**
    /// A percentage with no denominator is not a measurement, and 0 attempts is not 0%.
    @Test func retentionStatesItsDenominatorAndRefusesToInventOne() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        let scheduler = try MemoryScheduler()

        #expect(try ledger.retention(dictionary: nil).rate == nil, "no attempts is not a rate")

        // A first review: an introduction, not a recall.
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: scheduler)
        var report = try ledger.retention(dictionary: nil)
        #expect(report.introductions == 1)
        #expect(report.attempts == 0)
        #expect(report.rate == nil)

        // Answered again within the day: a short-term repeat, a different metric.
        var revision = try #require(try ledger.card(id: card.id)).revision
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: revision,
                             at: now.addingTimeInterval(3_600), using: scheduler)
        report = try ledger.retention(dictionary: nil)
        #expect(report.shortTerm == 1)
        #expect(report.attempts == 0)

        // A day later: this one counts.
        revision = try #require(try ledger.card(id: card.id)).revision
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: revision,
                             at: now.addingTimeInterval(200_000), using: scheduler)
        report = try ledger.retention(dictionary: nil)
        #expect(report.attempts == 1)
        #expect(report.successes == 1)
        #expect(report.rate == 1)
        #expect(report.cards == 1, "one card, however many attempts")
    }

    /// A review the reader took back did not happen, and does not enter the denominator.
    @Test func avoidedReviewIsExcludedAndCounted() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        let scheduler = try MemoryScheduler()
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: scheduler)
        let revision = try #require(try ledger.card(id: card.id)).revision
        _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: revision,
                             at: now.addingTimeInterval(200_000), using: scheduler)
        #expect(try ledger.retention(dictionary: nil).attempts == 1)

        try ledger.undoLatestReview(ofCard: card.id, at: now)
        let report = try ledger.retention(dictionary: nil)
        #expect(report.attempts == 0, "a review the reader took back is still in the denominator")
        #expect(report.voided == 1)
    }

    // MARK: - Suggestions (C06)

    /// **Distinct days, not lookups.** A word met on three days is evidence of a gap; the same word
    /// met three times in an afternoon is one paragraph read twice.
    @Test func suggestionsRankByDistinctDaysNotByCount() throws {
        let ledger = try ledger()
        let day: TimeInterval = 86_400
        // `spread` on three days, once each. `burst` four times in one afternoon.
        for offset in [0.0, day, 2 * day] { try read(ledger, "spread", at: now.addingTimeInterval(offset)) }
        for offset in [0.0, 600.0, 1_200.0, 1_800.0] {
            try read(ledger, "burst", at: now.addingTimeInterval(offset))
        }
        let found = try ledger.suggestions(limit: 10, language: "en", studying: [.latin])
        #expect(found.first?.lemma == "spread", "got \(found.map(\.lemma))")
        #expect(found.first?.distinctDays == 3)
        #expect(found.first?.lookups == 3)
        #expect(found.contains { $0.lemma == "burst" } == false, "one day is not a pattern")
    }

    /// **A word already taken up is never suggested**, in any disposition — a word the reader
    /// ignored coming back as a suggestion is the whole point of ignoring it, undone.
    @Test func aWordAlreadyTakenUpIsNotSuggested() throws {
        let ledger = try ledger()
        let day: TimeInterval = 86_400
        for offset in [0.0, day] { try read(ledger, "fine", at: now.addingTimeInterval(offset)) }
        #expect(try ledger.suggestions(limit: 10, language: "en", studying: [.latin]).count == 1)

        let note = try save(ledger, "fine", at: now.addingTimeInterval(2 * day))
        #expect(try ledger.suggestions(limit: 10, language: "en", studying: [.latin]).isEmpty)
        try ledger.setEnrollment(.ignored, of: note.id)
        #expect(try ledger.suggestions(limit: 10, language: "en", studying: [.latin]).isEmpty,
                "an ignored word came back as a suggestion")
    }

    /// Suggesting writes nothing. It is a list, and what to do with it is the reader's.
    @Test func suggestingEnrolsNothing() throws {
        let ledger = try ledger()
        for offset in [0.0, 86_400.0] { try read(ledger, "fine", at: now.addingTimeInterval(offset)) }
        _ = try ledger.suggestions(limit: 10, language: "en", studying: [.latin])
        #expect(try ledger.notes().isEmpty)
    }

    // MARK: - The repair queue (R09)

    /// **Lapses on distinct days**, not lapses: four failures in one sitting is one bad evening.
    @Test func therepairQueueCountsDistinctDaysOfFailure() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        let scheduler = try MemoryScheduler()
        var when = now
        for _ in 0..<4 {
            let revision = try #require(try ledger.card(id: card.id)).revision
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: revision,
                                 at: when, using: scheduler)
            when = when.addingTimeInterval(600)  // four failures, all the same day
        }
        #expect(try ledger.repeatedlyLapsed(atLeast: 4, dictionary: nil).isEmpty,
                "one bad evening is not a broken card")

        for day in 1...3 {
            let revision = try #require(try ledger.card(id: card.id)).revision
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: revision,
                                 at: now.addingTimeInterval(Double(day) * 86_400), using: scheduler)
        }
        #expect(try ledger.repeatedlyLapsed(atLeast: 4, dictionary: nil) == [card.id])
    }

    // MARK: - Tags (M03)

    /// Tags are the reader's own, and **changing one touches no memory**.
    @Test func taggingIsOrganisationAndNotAFactAboutMemory() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        let scheduled = try #require(try ledger.card(id: card.id)).scheduled

        try ledger.tag(noteID: note.id, "law")
        try ledger.tag(noteID: note.id, "law")  // idempotent
        try ledger.tag(noteID: note.id, "  ")   // nothing
        try ledger.tag(noteID: note.id, "reading")
        #expect(try ledger.tags(of: note.id) == ["law", "reading"])
        #expect(try ledger.allTags().map(\.tag) == ["law", "reading"])
        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled)

        try ledger.untag(noteID: note.id, "law")
        #expect(try ledger.tags(of: note.id) == ["reading"])
    }

    /// A tag goes with its note and takes nothing else with it.
    @Test func removingAnoteTakesItsTags() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        try ledger.tag(noteID: note.id, "law")
        try ledger.removeFromStudy([note.id])
        #expect(try ledger.allTags().isEmpty)
        #expect(try ledger.history(of: "fine").count == 1)
    }
}
