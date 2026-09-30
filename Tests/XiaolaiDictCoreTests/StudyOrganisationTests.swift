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

        // **And the cue exists.** The sentence above claimed it and nothing checked: `cue` built
        // its word from the newest reading and returned nil without one, so a custom card was
        // eligible for review and drawn by nothing — skipped every sitting, for ever.
        let card = try ledger.card(of: own.id, at: now)
        let cue = try #require(try ledger.cue(forCard: card.id), "a custom card has no cue at all")
        #expect(cue.word == "put up with", "its cue is the reader's own words")
        #expect(cue.sentence == nil, "and it was met in no sentence, rather than echoing itself")
        #expect(cue.readAt == nil, "nor at a time, which would be a reading that never happened")

        // It also has to survive the library, which derived its word from a reading too.
        let row = try #require(try ledger.library(LibraryQuery(now: now)).first { $0.id == own.id })
        #expect(row.word == "put up with", "the library drew it as a blank row")
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

        let batch = try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast)
        #expect(batch.count == 2, "got \(batch.count) cards for 2 notes")
        #expect(Set(batch.map(\.noteID)).count == 2)
        // The sibling is not dropped — it is still due, and the next batch can have it.
        let answered = try #require(batch.first { $0.noteID == note.id })
        _ = try ledger.grade(cardID: answered.id, .good, eventID: UUID(),
                             expectedRevision: answered.revision, at: now, using: try MemoryScheduler())
        let next = try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast)
        // **The sibling, by identity.** Matching on the note alone was satisfied by the card just
        // answered coming back — which is the opposite of the rule being asserted.
        let returned = try #require(next.first { $0.noteID == note.id }, "the sibling never came back")
        #expect(returned.id != answered.id, "the card just answered came back, not its sibling")
        #expect(returned.prompt != answered.prompt)
    }

    // MARK: - Practice (R10)

    /// **Practice obeys the two rules the queue obeys**: it does not offer a card the reader
    /// paused or put off, and it holds at most one card per note. It offered all three.
    @Test func practiceSkipsWhatTheReaderPutAwayAndHoldsOnePerNote() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()

        // Three notes, each with a reviewed card so all are practisable to begin with.
        let paused = try save(ledger, "resting")
        let putOff = try save(ledger, "tomorrow")
        let twoPrompts = try save(ledger, "both")
        var cards: [UUID: StudyCard] = [:]
        for note in [paused, putOff, twoPrompts] {
            let card = try ledger.card(of: note.id, at: now)
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                 expectedRevision: card.revision, at: now, using: scheduler)
            cards[note.id] = card
        }
        // The second prompt of one note, also reviewed.
        let sibling = try ledger.card(of: twoPrompts.id, prompt: .production, at: now)
        _ = try ledger.grade(cardID: sibling.id, .good, eventID: UUID(),
                             expectedRevision: sibling.revision, at: now, using: scheduler)

        try ledger.setPaused(true, ofCard: try #require(cards[paused.id]).id)
        try ledger.postpone(cardID: try #require(cards[putOff.id]).id,
                            until: now.addingTimeInterval(86_400))

        let batch = try ledger.practisableCards(limit: 10, dictionary: nil)
        #expect(batch.contains { $0.noteID == paused.id } == false, "a paused card was offered")
        #expect(batch.contains { $0.noteID == putOff.id } == false, "a card put off was offered")
        #expect(batch.filter { $0.noteID == twoPrompts.id }.count == 1,
                "both prompts of one note in a batch")
    }

    /// **An eligibility change moves the revision**, because the revision is the compare-and-swap
    /// that stops a grade computed against one state landing on another — and pausing or putting
    /// a card off changes whether it may be asked at all. Without it a presentation drawn before
    /// the change passed the guard and graded a card the reader had just put away.
    @Test func pausingAndPostponingRefuseAgradeDrawnBeforeThem() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        for (label, put) in [("paused", true), ("postponed", false)] {
            let note = try save(ledger, "fine-\(label)")
            let card = try ledger.card(of: note.id, at: now)
            let drawnAt = card.revision
            if put {
                try ledger.setPaused(true, ofCard: card.id)
            } else {
                try ledger.postpone(cardID: card.id, until: now.addingTimeInterval(86_400))
            }
            #expect(throws: ReviewError.self, "a \(label) card accepted a grade drawn before it") {
                try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                 expectedRevision: drawnAt, at: self.now, using: scheduler)
            }
        }
    }

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

        // **A second card, failed, so neither number is its own denominator.** With one card at
        // 100% a rate of 1 was satisfied by counting attempts, by counting cards, or by returning
        // a constant; `cards == 1` likewise could not tell distinct cards from attempts.
        let second = try save(ledger, "hold")
        let other = try ledger.card(of: second.id, at: now)
        _ = try ledger.grade(cardID: other.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: scheduler)
        let otherRevision = try #require(try ledger.card(id: other.id)).revision
        _ = try ledger.grade(cardID: other.id, .again, eventID: UUID(), expectedRevision: otherRevision,
                             at: now.addingTimeInterval(200_000), using: scheduler)
        // **A second eligible recall on the first card**, so attempts and cards are different
        // numbers. With one each, `cards` counting attempts satisfied the assertion — measured.
        revision = try #require(try ledger.card(id: card.id)).revision
        _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: revision,
                             at: now.addingTimeInterval(400_000), using: scheduler)

        report = try ledger.retention(dictionary: nil)
        #expect(report.attempts == 3, "three eligible recalls across two cards")
        #expect(report.cards == 2, "distinct cards, not attempts")
        #expect(report.successes == 1)
        #expect(report.rate == 1.0 / 3.0)
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
        // `spread` on three days, once each. `burst` four times in one afternoon. **And `middling`
        // on two days**, which is the candidate that makes the ordering assertion mean something:
        // with `burst` excluded by the two-day minimum there was only ever one eligible word, so
        // any ordering — including none — put it first.
        for offset in [0.0, day, 2 * day] { try read(ledger, "spread", at: now.addingTimeInterval(offset)) }
        // **More lookups, fewer days**, which is the only shape that separates the two rules.
        // A runner-up with fewer of both left ordering by raw count indistinguishable from
        // ordering by distinct days — measured: the by-count mutant passed.
        for offset in [0.0, 600.0, 1_200.0, day, day + 600] {
            try read(ledger, "clumped", at: now.addingTimeInterval(offset))
        }
        for offset in [0.0, 600.0, 1_200.0, 1_800.0] {
            try read(ledger, "burst", at: now.addingTimeInterval(offset))
        }
        let found = try ledger.suggestions(limit: 10, language: "en", studying: [.latin])
        #expect(found.map(\.lemma) == ["spread", "clumped"], "got \(found.map(\.lemma))")
        #expect(found.first?.distinctDays == 3)
        #expect(found.first?.lookups == 3)
        #expect(found.last?.distinctDays == 2, "and the runner-up is ranked by days…")
        #expect(found.last?.lookups == 5, "…despite having been looked up more often")
        #expect(found.contains { $0.lemma == "burst" } == false,
                "one day is not a pattern, however many times")
    }

    /// **Suggestions count study days, not calendar days.** Two lookups either side of midnight
    /// are one evening; counted as two they cleared the two-day minimum and a single sitting was
    /// offered as repeated reading — the exact pattern this ranking exists to find, invented.
    @Test func lookupsEitherSideOfMidnightAreOneDay() throws {
        let ledger = try ledger()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let midnight = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) throws -> Date {
            try #require(calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour,
                                                                minute: minute), to: midnight))
        }
        // 23:50 and 00:10 the next calendar day: one study day, on either side of midnight.
        try read(ledger, "evening", at: try at(23, 50))
        try read(ledger, "evening", at: try at(0, 10, dayOffset: 1))

        let found = try ledger.suggestions(limit: 10, language: "en", studying: [.latin])
        #expect(found.isEmpty, "one evening is not two days: \(found.map { "\($0.lemma) \($0.distinctDays)" })")
    }

    /// **A homograph in another language is a different word.** Saving English *pain* suppressed
    /// French *pain* as a suggestion: the saved-word exclusion matched the lemma alone while the
    /// ignored-word check beside it matched lemma and language, so one rule silenced a word the
    /// reader had never taken up and nothing said why.
    @Test func savingAwordInOneLanguageDoesNotSilenceItsHomograph() throws {
        let ledger = try ledger()
        let day: TimeInterval = 86_400
        // Read on two days in French, so it qualifies; and saved in English, which must not count.
        for offset in [0.0, day] {
            let lookup = try ledger.record(LookupRecord(
                surface: "pain", lemma: "pain", context: "Le pain est frais.", lemmaBasis: .tagger,
                language: "fr", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
                lookedUpAt: now.addingTimeInterval(offset), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
            _ = lookup
        }
        let english = try ledger.record(LookupRecord(
            surface: "pain", lemma: "pain", context: "It caused him pain.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        _ = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-pain", senseKey: "e-pain.1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "physical suffering"),
            lookupID: english, at: now)

        let found = try ledger.suggestions(limit: 10, language: "fr", studying: [.latin])
        #expect(found.map(\.lemma) == ["pain"],
                "the French word was silenced by the English one: \(found.map(\.lemma))")
        #expect(found.first?.language == "fr")
    }

    /// **A tag comes off the way it went on.** Adding " law " stores `law`; removing " law "
    /// compared the untrimmed text and matched nothing, so the reader typing exactly what they
    /// typed before could not take the tag off.
    @Test func atagIsRemovedByTheWordsTheReaderTyped() throws {
        let ledger = try ledger()
        let note = try save(ledger, "fine")
        try ledger.tag(noteID: note.id, "  law  ")
        #expect(try ledger.tags(of: note.id) == ["law"], "stored trimmed")
        try ledger.untag(noteID: note.id, "  law  ")
        #expect(try ledger.tags(of: note.id).isEmpty, "it went on trimmed and would not come off")
    }

    /// **A reading with no source is not a place it was read.** `COALESCE(source_app, '')` made
    /// every unattributed lookup share one synthetic source, so a word read twice in nothing at
    /// all reported two sources and outranked one genuinely read in two apps.
    @Test func lookupsWithNoSourceAreNotCountedAsAplace() throws {
        let ledger = try ledger()
        let day: TimeInterval = 86_400
        for offset in [0.0, day] {
            _ = try ledger.record(LookupRecord(
                surface: "nowhere", lemma: "nowhere", context: "A sentence with nowhere.",
                lemmaBasis: .tagger, language: "en", contextRange: nil,
                place: ReadingPlace(bundleID: nil, name: nil),
                lookedUpAt: now.addingTimeInterval(offset), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
        }
        let found = try #require(
            try ledger.suggestions(limit: 10, language: "en", studying: [.latin]).first)
        #expect(found.lemma == "nowhere")
        #expect(found.distinctSources == 0, "two readings from nowhere are not two places")
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
