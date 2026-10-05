import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import XiaolaiDictCore

/// **The library: finding a card months later, and changing it without losing anything.** WI-005.
///
/// The drawer is a fortnight and 400 rows. This is the one surface where a reader takes stock, so its
/// failures are different: a page that silently drops a row, a filter that hides scheduled work, and
/// the two deletions that must never be each other.
struct StudyLibraryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    @discardableResult
    private func save(_ ledger: Ledger, word: String, sentence: String? = nil,
                      dictionary: String = "noad", script: ProbeScript? = .latin,
                      answer: String = "a penalty", at when: Date? = nil,
                      source: String = "com.apple.Safari") throws -> StudyNote {
        let when = when ?? now
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: sentence ?? "A sentence holding \(word).",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: source, name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: script))
        return try ledger.enroll(
            .sense(dictionary: dictionary, entryID: "e-\(word)", senseKey: "e-\(word).001",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: answer), lookupID: lookup, at: when)
    }

    // MARK: - Finding

    /// **Past the drawer's window in both directions.** A card saved a year ago, from a lookup older
    /// than any drawer will show, is still the reader's and must still be findable.
    @Test func thelibraryReachesPastTheDrawersWindow() throws {
        let ledger = try ledger()
        let old = try save(ledger, word: "antediluvian", at: now.addingTimeInterval(-400 * 86_400))
        try save(ledger, word: "fresh")
        let rows = try ledger.library(LibraryQuery())
        #expect(rows.count == 2)
        #expect(rows.map(\.note.id).contains(old.id))
        #expect(rows.first?.word == "fresh", "newest first")
    }

    /// Search matches the word, the reader's own sentence, and the answer.
    @Test func searchLooksInTheWordTheSentenceAndTheAnswer() throws {
        let ledger = try ledger()
        // **Each term appears in exactly one field.** The sentence used to be "…into the hold",
        // so searching for *hold* matched through the sentence and the word search could have
        // been deleted with this test still green. Three searches, three fields, no overlap.
        let hold = try save(ledger, word: "hold", sentence: "The cargo went downstairs.",
                            answer: "a ship's storage space")
        try save(ledger, word: "fine", sentence: "He paid it.", answer: "a penalty")

        #expect(try ledger.library(LibraryQuery(text: "hold")).map(\.id) == [hold.id], "the word")
        #expect(try ledger.library(LibraryQuery(text: "downstairs")).map(\.id) == [hold.id],
                "the reader's own sentence")
        #expect(try ledger.library(LibraryQuery(text: "storage")).map(\.id) == [hold.id], "the answer")
        #expect(try ledger.library(LibraryQuery(text: "nothing here")).isEmpty)
    }

    /// A reader searching for `100%` is searching for `100%`, not for every row.
    @Test func searchTreatsWildcardsAsText() throws {
        let ledger = try ledger()
        try save(ledger, word: "percent", answer: "100% of the time")
        try save(ledger, word: "other", answer: "nothing like it")
        #expect(try ledger.library(LibraryQuery(text: "100%")).count == 1)
        // A bare `%` is a search for the character, not for everything: one row contains one.
        #expect(try ledger.library(LibraryQuery(text: "%")).count == 1)
        #expect(try ledger.library(LibraryQuery(text: "_")).isEmpty, "and `_` matches no single char")
    }

    /// **Keyset pagination, not an offset.** A card enrolled while the reader is paging shifts every
    /// offset after it — which silently skips a row, and skipping is invisible.
    @Test func pagingDoesNotSkipARowWhenOneIsAddedBehindIt() throws {
        let ledger = try ledger()
        for index in 0..<5 {
            try save(ledger, word: "word\(index)", at: now.addingTimeInterval(Double(index)))
        }
        let first = try ledger.library(LibraryQuery(limit: 2))
        #expect(first.map(\.word) == ["word4", "word3"])

        // A newer card arrives between the pages: with an offset it would push `word2` past the
        // boundary and the reader would never see it.
        try save(ledger, word: "word5", at: now.addingTimeInterval(99))
        let second = try ledger.library(LibraryQuery(limit: 2, after: first.last?.cursor))
        #expect(second.map(\.word) == ["word2", "word1"])
        let third = try ledger.library(LibraryQuery(limit: 2, after: second.last?.cursor))
        #expect(third.map(\.word) == ["word0"])
    }

    /// Two notes saved in the same instant are two pages' worth of rows, not one row twice.
    @Test func pagingBreaksAtieOnIdentity() throws {
        let ledger = try ledger()
        for index in 0..<4 { try save(ledger, word: "same\(index)", at: now) }
        var seen: [UUID] = []
        var cursor: LibraryQuery.Cursor?
        for _ in 0..<4 {
            let page = try ledger.library(LibraryQuery(limit: 1, after: cursor))
            guard let row = page.first else { break }
            seen.append(row.note.id)
            cursor = row.cursor
        }
        #expect(seen.count == 4)
        #expect(Set(seen).count == 4, "a row repeated across pages")
    }

    /// **M10: the script filter is offered, and off by default.** Applying the reader's *reading*
    /// filter to their card collection unasked hides scheduled work, and an empty library and a
    /// filtered one look exactly alike.
    @Test func scriptNarrowingHidesNothingUnlessItIsAsked() throws {
        let ledger = try ledger()
        try save(ledger, word: "fine", script: .latin)
        try save(ledger, word: "水", script: .han)

        #expect(try ledger.library(LibraryQuery()).count == 2, "off by default")
        #expect(try ledger.library(LibraryQuery(scripts: [.latin])).count == 1, "and offered")
        // A row the reader can see is a row they can act on: the script is on it, so a surface can
        // annotate what falls outside their setting instead of dropping it.
        #expect(try ledger.library(LibraryQuery()).compactMap(\.script).sorted() == [.latin, .han].sorted())
    }

    /// A row written before the ledger recorded scripts is unknown, and unknown is **drawn**.
    @Test func arowWithNoRecordedScriptIsNotHidden() throws {
        let ledger = try ledger()
        try save(ledger, word: "old", script: nil)
        #expect(try ledger.library(LibraryQuery(scripts: [.latin])).count == 1)
    }

    /// The library shows archived and ignored cards: it is where a reader goes to find what they put
    /// away. The queue does not, which is the difference between taking stock and being asked.
    @Test func thelibraryShowsWhatTheQueueWillNot() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.setEnrollment(.archived, of: note.id)
        #expect(try ledger.library(LibraryQuery()).count == 1)
        #expect(try ledger.library(LibraryQuery(enrollment: [.active])).isEmpty)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty)
    }

    /// Study state belongs to one dictionary, and the old collection stays findable after a switch.
    @Test func anOldCollectionIsStillThereAfterSwitchingDictionaries() throws {
        let ledger = try ledger()
        try save(ledger, word: "fine", dictionary: "noad")
        try save(ledger, word: "fine", dictionary: "oxford")
        #expect(try ledger.library(LibraryQuery(dictionary: "noad")).count == 1)
        #expect(try ledger.library(LibraryQuery()).count == 2, "no scope is every namespace")
    }

    /// Each row says whether it can be asked, so the library can show what needs attention.
    @Test func arowCarriesItsOwnReadiness() throws {
        let ledger = try ledger()
        let fine = try save(ledger, word: "fine")
        let broken = try save(ledger, word: "hold")
        try ledger.run("DELETE FROM study_answers WHERE note_id = ?",
                       bind: [.text(broken.id.uuidString)]) { _ in }
        let rows = try ledger.library(LibraryQuery())
        #expect(rows.first(where: { $0.note.id == fine.id })?.readiness == .ready)
        #expect(rows.first(where: { $0.note.id == broken.id })?.readiness == .needsRepair)
    }

    /// **Listing the library must not write to it.** `library(_:)` reached for each note's card
    /// through the accessor that *creates* one when it is missing, so merely opening the window —
    /// or counting the rows, which lists them all — enrolled a schedule for every note that had
    /// none. A read with a side effect is the kind of defect that only shows up as rows appearing
    /// from nowhere.
    @Test func listingTheLibraryCreatesNothing() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        // A note with no card: the shape a pre-schema-10 enrollment has, since the migration
        // deliberately backfilled none.
        try ledger.execute("DELETE FROM study_cards")
        var cards = 0
        try ledger.run("SELECT COUNT(*) FROM study_cards", bind: []) { cards = $0.integer(0) }
        #expect(cards == 0)

        let rows = try ledger.library(LibraryQuery())
        #expect(rows.count == 1)
        #expect(rows.first?.note.id == note.id)
        #expect(rows.first?.card == nil, "a note with no card reports none rather than gaining one")
        _ = try ledger.libraryCount(LibraryQuery())

        try ledger.run("SELECT COUNT(*) FROM study_cards", bind: []) { cards = $0.integer(0) }
        #expect(cards == 0, "listing the library created \(cards) cards")
    }

    /// **Each state filter must return its own collection.** They all reduced to
    /// `enrollment = 'active'`, so Paused listed unpaused cards, Due listed cards due next year and
    /// Needs attention listed cards with nothing wrong — and a bulk action then operated on a set
    /// the label had described wrongly.
    @Test func eachStateFilterReturnsItsOwnCollection() throws {
        let ledger = try ledger()
        let due = try save(ledger, word: "due")
        let future = try save(ledger, word: "future")
        let paused = try save(ledger, word: "paused")
        let unconfirmed = try save(ledger, word: "unconfirmed")

        // `future` is graded, so it is scheduled well ahead; the others have never been reviewed
        // and are due as soon as they are ready.
        let futureCard = try #require(try ledger.existingCard(of: future.id))
        _ = try ledger.grade(cardID: futureCard.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try MemoryScheduler())
        try ledger.setPaused(true, ofNotes: [paused.id])
        try ledger.setAnswer(StudyAnswer(origin: .dictionary, text: "x"), of: unconfirmed.id, at: now)
        try ledger.setEnrollment(.active, of: unconfirmed.id)
        // Unconfirmed: a model's proposal nobody has agreed with.
        try ledger.unconfirmForTesting(noteID: unconfirmed.id)

        func ids(_ state: LibraryQuery.State?) throws -> Set<UUID> {
            Set(try ledger.library(LibraryQuery(state: state, now: now)).map(\.id))
        }
        let dueIDs = try ids(.due), pausedIDs = try ids(.paused)
        let attention = try ids(.needsAttention), all = try ids(nil)
        #expect(dueIDs == [due.id], "Due listed \(dueIDs)")
        #expect(pausedIDs == [paused.id], "Paused listed \(pausedIDs)")
        #expect(attention == [unconfirmed.id], "Needs attention listed \(attention)")
        #expect(all.count == 4, "and All is all of them")
    }

    /// **The library's *Struggling* filter and the repair list select the same cards.** R09's
    /// `repeatedlyLapsed` had no surface at all; giving it one by narrowing a page in Swift would
    /// have broken the keyset rule, so the lapse count is one SQL expression used in both places.
    /// Two spellings of "keeps failing" is how a filter and a list start disagreeing in front of
    /// the reader.
    @Test func thestrugglingFilterAndTheRepairListAgree() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        let struggling = try save(ledger, word: "recalcitrant")
        try save(ledger, word: "easy")
        let card = try ledger.card(of: struggling.id, at: now)
        for day in 0..<Ledger.repeatedLapseDays {
            let revision = try #require(try ledger.card(id: card.id)).revision
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(),
                                 expectedRevision: revision,
                                 at: now.addingTimeInterval(Double(day) * 86_400),
                                 using: scheduler)
        }

        let listed = try ledger.library(LibraryQuery(state: .struggling, now: now))
        #expect(listed.map(\.id) == [struggling.id], "listed \(listed.map(\.word))")
        #expect(try ledger.libraryCount(LibraryQuery(state: .struggling, now: now)) == 1)
        #expect(try ledger.repeatedlyLapsed(dictionary: nil) == [card.id],
                "and the repair list says the same")
    }

    /// **The study day's 04:00 cutoff reaches the SQL too**, and this fixture is built to tell the
    /// two boundaries apart. Four failures on four *calendar* days, but the first two straddle
    /// local midnight and are one waking evening — three study days, which is under the bar.
    ///
    /// A midnight boundary lists this card. That is the whole point of the test: it fails if the
    /// shift is dropped, which a test of four failures in one afternoon would not.
    @Test func thelapseCountUsesTheStudyDayAndNotMidnight() throws {
        let ledger = try ledger()
        let scheduler = try MemoryScheduler()
        let note = try save(ledger, word: "fine")
        let card = try ledger.card(of: note.id, at: now)

        // SQLite's `localtime` is this machine's, so the fixture is built in the same calendar.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let midnight = calendar.startOfDay(for: now)
        func at(day: Int, hour: Int, minute: Int = 0) throws -> Date {
            try #require(calendar.date(byAdding: DateComponents(day: day, hour: hour,
                                                                minute: minute), to: midnight))
        }
        func fail(_ when: Date) throws {
            let revision = try #require(try ledger.card(id: card.id)).revision
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(),
                                 expectedRevision: revision, at: when, using: scheduler)
        }
        try fail(try at(day: 0, hour: 23, minute: 30))   // study day 0, calendar day 0
        try fail(try at(day: 1, hour: 1, minute: 30))    // study day 0, calendar day 1
        try fail(try at(day: 2, hour: 12))               // study day 2
        try fail(try at(day: 3, hour: 12))               // study day 3

        #expect(try ledger.library(LibraryQuery(state: .struggling, now: now)).isEmpty,
                "four calendar days, but three study days — the small hours are one evening")

        // And the check is not passing because nothing ever matches.
        try fail(try at(day: 4, hour: 12))
        #expect(try ledger.library(LibraryQuery(state: .struggling, now: now)).count == 1)
    }

    // MARK: - The audit trail (M05)

    /// **Lookups and reviews, separately** — M05's rule, and the reason this is one call returning
    /// two lists rather than one merged sequence. A reading is something the reader did with a
    /// text; a review is something they did with a card, and a timeline that interleaves them
    /// invites reading a grade as evidence about the sentence beside it.
    @Test func thetimelineKeepsReadingsAndReviewsApart() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine", sentence: "He paid the fine.")
        // A second encounter of the same meaning, a week later.
        let second = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "A fine of two hundred.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now.addingTimeInterval(7 * 86_400), result: .found,
            answeredBy: .dictionaryService, quality: nil, script: .latin))
        try ledger.link(noteID: note.id, toLookup: second, at: now.addingTimeInterval(7 * 86_400))

        let card = try ledger.card(of: note.id, at: now)
        let scheduler = try MemoryScheduler()
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: scheduler)
        _ = try ledger.practise(cardID: card.id, .again, eventID: UUID(), at: now)

        let timeline = try ledger.timeline(of: note.id)
        #expect(timeline.readings.count == 2)
        #expect(timeline.readings.map(\.sentence) == ["A fine of two hundred.", "He paid the fine."],
                "newest first, like every other history surface here")
        #expect(timeline.reviews.count == 2, "the practice attempt is shown, not hidden")
        #expect(timeline.reviews.contains { $0.kind == .practice })
    }

    /// **Reading a history writes nothing.** Enrolment makes the `meaning` card; the harder
    /// `production` direction is opt-in and must stay that way. `card(of:prompt:)` *creates*, so a
    /// timeline that walked the prompts with it would silently double the reader's load every time
    /// they looked at a row — which is why this walks `existingCard`.
    @Test func readingAnoteTimelineCreatesNoCard() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        func cardCount() throws -> Int {
            try StudyCard.Prompt.allCases.compactMap {
                try ledger.existingCard(of: note.id, prompt: $0)
            }.count
        }
        #expect(try cardCount() == 1, "the meaning card, made when it was enrolled")

        let timeline = try ledger.timeline(of: note.id)
        #expect(timeline.readings.count == 1)
        #expect(timeline.reviews.isEmpty, "nothing has been answered")
        #expect(try cardCount() == 1, "and asking for the history made no second card")
    }

    // MARK: - Tags the reader can see and remove (M03)

    /// **A tag nobody can see is worse than no tag.** `tag`, `tags(of:)`, `untag` and `allTags`
    /// were four methods with one caller between them: a reader could add a label and then never
    /// find it, never read it back and never take it off.
    @Test func atagCanBeReadBackAndTakenOff() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.tag(noteID: note.id, "legal")
        try ledger.tag(noteID: note.id, "money")
        #expect(try ledger.tags(of: note.id) == ["legal", "money"])
        #expect(try ledger.allTags().map(\.tag) == ["legal", "money"])

        try ledger.untag(noteID: note.id, "money")
        #expect(try ledger.tags(of: note.id) == ["legal"])
        #expect(try ledger.allTags().map(\.tag) == ["legal"], "and the empty tag stops being offered")
    }

    /// **A tag is for finding things again**, so it goes in the query like every other filter —
    /// not applied to a page after the `LIMIT`, which would hand back a short page.
    @Test func thelibraryCanBeNarrowedToAtag() throws {
        let ledger = try ledger()
        // **The tagged rows are the older half, and the limit is smaller than either half.**
        // Two rows under the default fifty could not tell the two implementations apart: a
        // filter applied in Swift after the `LIMIT` returns the same answer when everything
        // fits on one page, which is the only case the old fixture had.
        var tagged: [UUID] = []
        for index in 0..<10 {
            let note = try save(ledger, word: "word\(index)", at: now.addingTimeInterval(Double(-index)))
            if index >= 5 { try ledger.tag(noteID: note.id, "legal"); tagged.append(note.id) }
        }
        var page = LibraryQuery(tag: "legal"); page.limit = 3
        let rows = try ledger.library(page)
        #expect(rows.count == 3, "a filter applied after the LIMIT would hand back a short page")
        #expect(rows.allSatisfy { tagged.contains($0.id) })
        #expect(try ledger.libraryCount(LibraryQuery(tag: "legal")) == 5, "and the count is of all of them")
        #expect(try ledger.library(LibraryQuery(tag: "nobody")).isEmpty)
        #expect(try ledger.library(LibraryQuery()).count == 10, "and no tag is no narrowing")
    }

    /// **The first confirmation stands.** A bulk confirm reaches every selected note, including
    /// ones confirmed weeks ago, and it rewrote their timestamps with today's — changing the
    /// record of *when* the reader said something, which is the one thing that record must keep.
    @Test func confirmingAgainDoesNotRewriteWhenTheReaderSaidIt() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.unconfirmForTesting(noteID: note.id)
        try ledger.confirm(noteID: note.id, at: now)
        let first = try #require(try ledger.notes().first?.confirmedAt)

        try ledger.confirm(noteID: note.id, at: now.addingTimeInterval(30 * 86_400))
        #expect(try ledger.notes().first?.confirmedAt == first,
                "a later confirm rewrote when the reader agreed")
    }

    /// **An instrument puts back exactly what it added.** `--panel-report` drives a real lookup
    /// through the app's own door, which records — so a measurement left fabricated reading in
    /// the reader's ledger, changing the drawer, the suggestion ranking and every later run on
    /// that Mac. The baseline is taken before the write, so a lookup the reader made meanwhile
    /// is out of range by construction.
    @Test func removingAninstrumentsRowsCannotReachTheReadersOwn() throws {
        let ledger = try ledger()
        try save(ledger, word: "theirs")
        let baseline = try ledger.newestLookupID()
        #expect(baseline > 0)

        try save(ledger, word: "mine")
        #expect(try ledger.newestLookupID() > baseline)

        try ledger.deleteLookups(after: baseline)
        #expect(try ledger.newestLookupID() == baseline, "the instrument's row is gone")
        #expect(try ledger.history(of: "theirs").count == 1, "and the reader's is untouched")
        #expect(try ledger.history(of: "mine").isEmpty)
    }

    // MARK: - Changing

    /// The reader's own words replace what the card reveals; the encounter's snapshot is untouched.
    @Test func theReadersAnswerReplacesTheCardsWithoutRewritingTheEvidence() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        let lookup = try #require(try ledger.lookupIDs(evidencing: note.id).first)
        try ledger.record(SenseEncounter(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad", version: "2.6"),
            entryID: "e-fine", senseKey: "e-fine.001", senseKeyKind: .publisher, sensePath: nil,
            entrySenseCount: 4, senseHash: "h", gloss: "the publisher's words", chosenBy: .reader,
            chosenAt: now), for: lookup)

        try ledger.setReaderAnswer("the money you pay when caught", of: note.id, at: now)
        #expect(try ledger.answer(of: note.id)?.text == "the money you pay when caught")
        #expect(try ledger.answer(of: note.id)?.origin == .reader)
        #expect(try ledger.encounters(ofLookup: lookup).first?.gloss == "the publisher's words",
                "the evidence is not a draft to be edited")
    }

    /// **An undo restores what was there, not what it assumes was there** (M04).
    ///
    /// Pause is per *card* and a note can have more than one, so "put it back" cannot mean "unpause
    /// the note": a note with one card paused and one running, bulk-paused and then undone, must
    /// come back with one paused and one running. Recording the note's disposition would have
    /// resumed both and called it an undo.
    @Test func anUndoOfAbulkPauseRestoresEachCardsOwnState() throws {
        let ledger = try ledger()
        // **One note with two cards in different states**, which is the whole claim: pause is per
        // card. Two notes of one card each could be satisfied by an implementation that stored a
        // single pause state per *note* — exactly the shape this is written against.
        let note = try save(ledger, word: "fine")
        let meaning = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let production = try ledger.card(of: note.id, prompt: .production, at: now)
        try ledger.setPaused(true, ofCard: production.id)

        let ids = [note.id]
        let before = try ledger.pauseStates(ofCardsUnder: ids)
        #expect(before[meaning.id] == false)
        #expect(before[production.id] == true, "one card of this note is resting and one is not")

        try ledger.setPaused(true, ofNotes: ids)
        #expect(try ledger.pauseStates(ofCardsUnder: ids).values.allSatisfy { $0 })

        try ledger.restorePauseStates(before)
        let after = try ledger.pauseStates(ofCardsUnder: ids)
        #expect(after == before, "each card went back to its own state, not the note's")
        #expect(after[meaning.id] == false, "the card that was running is running again")
        #expect(after[production.id] == true)
    }

    /// **A bulk pause moves every card's revision, as pausing one card does.** The revision is the
    /// compare-and-swap that stops a grade computed against one state landing on another, and
    /// pausing changes whether a card may be asked at all. Every card under every note, because pause
    /// is per card and a note can carry two.
    @Test func bulkPauseMovesEveryCardsRevision() throws {
        let ledger = try ledger()
        let first = try save(ledger, word: "fine"), second = try save(ledger, word: "hold")
        let cards = [try ledger.card(of: first.id, prompt: .meaning, at: now),
                     try ledger.card(of: first.id, prompt: .production, at: now),
                     try ledger.card(of: second.id, prompt: .meaning, at: now)]
        let untouched = try ledger.card(of: try save(ledger, word: "bank").id, at: now)

        try ledger.setPaused(true, ofNotes: [first.id, second.id])
        for card in cards {
            #expect(try #require(try ledger.card(id: card.id)).revision == card.revision + 1,
                    "pausing \(card.prompt) of a note left its revision where a drawn grade still fits")
        }
        try ledger.setPaused(false, ofNotes: [first.id, second.id])
        for card in cards {
            #expect(try #require(try ledger.card(id: card.id)).revision == card.revision + 2,
                    "and resuming moves it again")
        }
        #expect(try #require(try ledger.card(id: untouched.id)).revision == untouched.revision,
                "a card outside the selection moved")
    }

    /// **Putting a bulk pause back is a pause too**, and moves the revision the same way.
    @Test func restoringPauseStatesMovesTheRevision() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        let meaning = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let production = try ledger.card(of: note.id, prompt: .production, at: now)

        try ledger.restorePauseStates([meaning.id: true, production.id: false])
        #expect(try #require(try ledger.card(id: meaning.id)).revision == meaning.revision + 1)
        #expect(try #require(try ledger.card(id: production.id)).revision == production.revision + 1,
                "restored to the state it was already in, and still a write a drawn grade must not cross")
    }

    /// **The case the revision exists for.** A review window draws a card; the reader bulk-pauses it
    /// in the library and then undoes the pause. The card is askable again and in the same schedule,
    /// but the grade the window collected was drawn before two writes it never saw — refused as
    /// stale, as it is when the same happens to one card.
    @Test func aGradeDrawnBeforeABulkPauseAndResumeIsStale() throws {
        let scheduler = try MemoryScheduler()
        for route in ["resume", "restore"] {
            let ledger = try ledger()
            let note = try save(ledger, word: "fine-\(route)")
            let drawn = try ledger.card(of: note.id, at: now)

            let before = try ledger.pauseStates(ofCardsUnder: [note.id])
            try ledger.setPaused(true, ofNotes: [note.id])
            if route == "resume" {
                try ledger.setPaused(false, ofNotes: [note.id])
            } else {
                try ledger.restorePauseStates(before)
            }
            #expect(try ledger.readiness(of: note.id) == .ready, "\(route): the fixture's card is not askable")
            // **Stale, by the two writes**, not any refusal: a card that was still paused would
            // throw too, and that is not what this asserts.
            #expect(throws: ReviewError.staleRevision(expected: drawn.revision, found: drawn.revision + 2),
                    "\(route): a grade drawn before the pause landed") {
                try ledger.grade(cardID: drawn.id, .good, eventID: UUID(),
                                 expectedRevision: drawn.revision, at: self.now, using: scheduler)
            }
            #expect(try ledger.reviews(ofCard: drawn.id).isEmpty, "\(route): and it was recorded")
        }
    }

    /// **Editing the answer is a write a drawn grade must not cross** (audit-fix round 3, #10). The card
    /// reveals the note's answer, so a review window that drew it, showed the old meaning and collected a
    /// grade was grading a question the reader has since rewritten — ADR-0031: anything that wrote in
    /// between invalidates the answer. Every card of the note moves, and a card of another note does not.
    @Test func editingTheAnswerMakesAGradeDrawnBeforeItStale() throws {
        let scheduler = try MemoryScheduler()
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.setReaderAnswer("the money you pay", of: note.id, at: now)
        let drawn = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let sibling = try ledger.card(of: note.id, prompt: .production, at: now)
        let untouched = try ledger.card(of: try save(ledger, word: "hold").id, at: now)
        #expect(try ledger.readiness(of: note.id) == .ready, "the fixture's card is not askable")

        try ledger.setReaderAnswer("a sum paid as a penalty", of: note.id, at: now)
        #expect(try #require(try ledger.card(id: drawn.id)).revision == drawn.revision + 1,
                "the answer changed under a drawn card and its revision did not move")
        #expect(try #require(try ledger.card(id: sibling.id)).revision == sibling.revision + 1,
                "the note's other card reveals the same answer and did not move")
        #expect(try #require(try ledger.card(id: untouched.id)).revision == untouched.revision,
                "a card of another note moved")
        #expect(throws: ReviewError.staleRevision(expected: drawn.revision, found: drawn.revision + 1),
                "a grade drawn over the old answer landed") {
            try ledger.grade(cardID: drawn.id, .good, eventID: UUID(),
                             expectedRevision: drawn.revision, at: self.now, using: scheduler)
        }
        #expect(try ledger.reviews(ofCard: drawn.id).isEmpty)
    }

    /// The same for archiving, which is per note. **`.active` is not the answer** — a candidate the
    /// reader never took up, archived by accident and restored, must go back to being a candidate.
    @Test func anUndoOfAbulkArchiveRestoresTheDispositionEachNoteHad() throws {
        let ledger = try ledger()
        let active = try save(ledger, word: "working")
        let candidate = try save(ledger, word: "offered")
        try ledger.setEnrollment(.candidate, of: candidate.id)

        let ids = [active.id, candidate.id]
        let before = try ledger.enrollments(ofNotes: ids)
        #expect(before[candidate.id] == .candidate)

        try ledger.setEnrollment(.archived, ofNotes: ids)
        #expect(try ledger.enrollments(ofNotes: ids).values.allSatisfy { $0 == .archived })

        try ledger.restoreEnrollments(before)
        #expect(try ledger.enrollments(ofNotes: ids) == before,
                "restored to what each was, not to active")
    }

    /// **A row the undo's receipt cannot name is refused, not skipped** (audit-fix round 2) — the rule
    /// `card(from:)` and `note(from:)` already keep. A card whose id is not a UUID was left out of the
    /// "before" a bulk pause records and paused with the rest by the `UPDATE`, so its undo put back every
    /// card but that one, silently.
    @Test func aCardTheUndoCouldNotNameStopsTheBulkPauseBeforeItBegins() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        // A second question on the note, written as an edited file would hold it.
        try ledger.execute("""
            INSERT INTO study_cards (id, note_id, prompt, phase, scheduler_version, created_at)
            VALUES ('not-a-uuid', '\(note.id.uuidString)', 'recall', 'new', 'fsrs', 0)
            """)
        #expect(throws: LedgerError.corruptRow("study_cards not-a-uuid")) {
            _ = try ledger.pauseStates(ofCardsUnder: [note.id])
        }
    }

    /// **The rest of the class, found by grepping for it**: every study read that parsed an id and skipped
    /// the row it could not parse. The queue's agreement check lost a note, the Struggling list and the
    /// retention figure a card, and the export a note's tags — each silently, each the shape round 1's
    /// `note(from:)` and these two now refuse. Renamed as an edited file would hold them.
    @Test func everyStudyReadRefusesAnIdItCannotName() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        let card = try #require(try ledger.existingCard(of: note.id))
        let scheduler = try MemoryScheduler()
        for day in 0..<Ledger.repeatedLapseDays {
            let current = try #require(try ledger.card(id: card.id))
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: current.revision,
                                 at: now.addingTimeInterval(Double(day) * 86_400), using: scheduler)
        }
        // **The controls**: each read names this note or card before it is renamed.
        try #require(try ledger.askableNoteIDs() == [note.id])
        try #require(try ledger.repeatedlyLapsed(dictionary: nil) == [card.id])
        try #require(try ledger.retention(dictionary: nil).cardIDs == [card.id])
        try #require(try ledger.export(dictionary: nil).rows.count == 1)
        let (noteID, cardID) = (note.id.uuidString, card.id.uuidString)
        try ledger.execute("""
            PRAGMA foreign_keys = OFF;
            UPDATE study_notes SET id = 'bad-note' WHERE id = '\(noteID)';
            UPDATE study_note_lookups SET note_id = 'bad-note' WHERE note_id = '\(noteID)';
            UPDATE study_answers SET note_id = 'bad-note' WHERE note_id = '\(noteID)';
            UPDATE study_keep_metadata SET note_id = 'bad-note' WHERE note_id = '\(noteID)';
            UPDATE study_cards SET id = 'bad-card', note_id = 'bad-note' WHERE id = '\(cardID)';
            UPDATE review_events SET card_id = 'bad-card' WHERE card_id = '\(cardID)';
            PRAGMA foreign_keys = ON;
            """)
        #expect(throws: LedgerError.corruptRow("study_notes bad-note")) { _ = try ledger.askableNoteIDs() }
        #expect(throws: LedgerError.corruptRow("study_cards bad-card")) { _ = try ledger.repeatedlyLapsed(dictionary: nil) }
        #expect(throws: LedgerError.corruptRow("study_cards bad-card")) { _ = try ledger.retention(dictionary: nil) }
        #expect(throws: LedgerError.corruptRow("study_notes bad-note")) { _ = try ledger.export(dictionary: nil) }
    }

    /// **A stored value a read cannot name is a damaged row, never an absent one** (audit-fix round 3,
    /// #7, and its class). A reading linked to a note whose id did not parse came back with no note and
    /// a study status beside it — a saved meaning drawn as unsaved; a disposition it did not know read as
    /// kept; a target kind as no kind; a script as none, which every script filter lets through. Each is
    /// written the way only an edited file could hold it, and each read that decodes it must refuse.
    @Test func aReadRefusesAStoredValueItCannotName() throws {
        func fixture() throws -> (Ledger, StudyNote, Int) {
            let made = try self.ledger()
            let note = try save(made, word: "fine")
            let lookup = try #require(try made.lookupIDs(evidencing: note.id).first)
            // **The control**: the reading names its note before anything is edited.
            try #require(try made.reading(ofLookup: lookup)?.studyNoteID == note.id)
            try #require(try made.library(LibraryQuery()).count == 1)
            try #require(try made.history(of: "fine").count == 1)
            return (made, note, lookup)
        }

        var (ledger, note, lookup) = try fixture()
        try ledger.execute("""
            PRAGMA foreign_keys = OFF;
            UPDATE study_notes SET id = 'bad-note' WHERE id = '\(note.id.uuidString)';
            UPDATE study_note_lookups SET note_id = 'bad-note' WHERE note_id = '\(note.id.uuidString)';
            UPDATE study_answers SET note_id = 'bad-note' WHERE note_id = '\(note.id.uuidString)';
            UPDATE study_keep_metadata SET note_id = 'bad-note' WHERE note_id = '\(note.id.uuidString)';
            UPDATE study_cards SET note_id = 'bad-note' WHERE note_id = '\(note.id.uuidString)';
            PRAGMA foreign_keys = ON;
            """)
        #expect(throws: LedgerError.corruptRow("study_notes.id 'bad-note'"),
                "a reading linked to a note it could not name was drawn as unsaved") {
            _ = try ledger.reading(ofLookup: lookup)
        }

        (ledger, note, lookup) = try fixture()
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE study_notes SET target_kind = 'shelf' WHERE id = '\(note.id.uuidString)';
            PRAGMA ignore_check_constraints = OFF;
            """)
        #expect(throws: LedgerError.corruptRow("study_notes.target_kind 'shelf'"),
                "a target kind it could not name was read as none") {
            _ = try ledger.reading(ofLookup: lookup)
        }

        (ledger, note, lookup) = try fixture()
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE lookups SET disposition = 'shelved' WHERE id = \(lookup);
            PRAGMA ignore_check_constraints = OFF;
            """)
        #expect(throws: LedgerError.corruptRow("lookups.disposition 'shelved'"),
                "a disposition it could not name was read as kept") {
            _ = try ledger.reading(ofLookup: lookup)
        }

        (ledger, note, lookup) = try fixture()
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE lookups SET script = 'runic' WHERE id = \(lookup);
            PRAGMA ignore_check_constraints = OFF;
            """)
        #expect(throws: LedgerError.corruptRow("lookups.script 'runic'"),
                "a script it could not name was read as none in the history") {
            _ = try ledger.history(of: "fine")
        }
        #expect(throws: LedgerError.corruptRow("lookups.script 'runic'"),
                "a script it could not name was read as none in the library") {
            _ = try ledger.library(LibraryQuery())
        }
    }

    /// The same for archiving: an enrollment this build cannot read is refused rather than left out of
    /// what the undo restores. Written past the `CHECK` the way only an edited file could be.
    @Test func anEnrollmentTheUndoCouldNotRestoreIsRefused() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.execute("""
            PRAGMA ignore_check_constraints = ON;
            UPDATE study_notes SET enrollment = 'shelved' WHERE id = '\(note.id.uuidString)';
            PRAGMA ignore_check_constraints = OFF;
            """)
        #expect(throws: LedgerError.corruptRow("study_notes \(note.id.uuidString)")) {
            _ = try ledger.enrollments(ofNotes: [note.id])
        }
    }

    /// A bulk action lands on **exactly the set it was given** — every one of them, and nothing
    /// else.
    ///
    /// **Not all-or-nothing, which is not reachable from here.** Every statement these bulk
    /// helpers run is an `UPDATE` that matches nothing when its id is absent, so no iteration can
    /// fail and the savepoint has nothing to roll back. The transaction is belt-and-braces
    /// against a future statement that *can* fail; saying this test covers it would be a claim
    /// nobody has checked.
    @Test func abulkActionAffectsExactlyTheSelection() throws {
        let ledger = try ledger()
        let a = try save(ledger, word: "a"), b = try save(ledger, word: "b")
        let untouched = try save(ledger, word: "c")
        try ledger.setEnrollment(.archived, ofNotes: [a.id, b.id])
        let rows = try ledger.library(LibraryQuery())
        #expect(rows.first(where: { $0.note.id == a.id })?.note.enrollment == .archived)
        #expect(rows.first(where: { $0.note.id == b.id })?.note.enrollment == .archived)
        #expect(rows.first(where: { $0.note.id == untouched.id })?.note.enrollment == .active)
    }

    /// Pausing a selection stops them being asked and **touches no memory**.
    @Test func pausingAselectionChangesEligibilityAndNothingElse() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        let scheduled = try #require(try ledger.card(id: card.id)).scheduled

        try ledger.setPaused(true, ofNotes: [note.id])
        let later = now.addingTimeInterval(400 * 86_400)
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty)
        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled)
        try ledger.setPaused(false, ofNotes: [note.id])
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).count == 1)
    }

    // MARK: - The two deletions

    /// **Remove from study keeps the reading.** A reader tidying their cards has said nothing about
    /// their history, and a command that took both would destroy months of it on a misread menu item.
    @Test func removingFromStudyLeavesTheReadingHistory() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        try ledger.removeFromStudy([note.id])
        #expect(try ledger.library(LibraryQuery()).isEmpty)
        #expect(try ledger.history(of: "fine").count == 1)
    }

    /// **Delete reading keeps the card**, and it is not the mirror of the other. The reader wanted
    /// the history gone, not the target — so the note stays and becomes repairable.
    @Test func deletingReadingLeavesTheCardNeedingRepair() throws {
        let ledger = try ledger()
        let note = try save(ledger, word: "fine")
        // **The card and its schedule are what "keeps the card" means.** Asserting the note and
        // its answer left the claim untested: deleting the reader's study progress while keeping
        // the note would have passed.
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try MemoryScheduler())
        let scheduled = try #require(try ledger.card(id: card.id)).scheduled

        try ledger.deleteReading(lookups: try ledger.lookupIDs(evidencing: note.id))
        #expect(try ledger.history(of: "fine").isEmpty)
        #expect(try ledger.library(LibraryQuery()).count == 1)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
        #expect(try ledger.answer(of: note.id) != nil, "and the answer it had is still there")
        let kept = try #require(try ledger.existingCard(of: note.id))
        #expect(kept.scheduled == scheduled, "the schedule the reader earned is untouched")
        #expect(try ledger.reviews(ofCard: card.id).count == 1, "and so is what they answered")
    }

    /// **Previewed before it is offered**, because clearing a source cannot be undone: how much
    /// history goes, and how many cards it leaves without a cue are two different numbers.
    @Test func asourceWideDeletionIsCountedBeforeItHappens() throws {
        let ledger = try ledger()
        let onlySafari = try save(ledger, word: "fine", source: "com.apple.Safari")
        let bothPlaces = try save(ledger, word: "hold", source: "com.apple.Safari")
        // The second note was also met somewhere else, so it keeps a cue.
        let elsewhere = try ledger.record(LookupRecord(
            surface: "hold", lemma: "hold", context: "Another sentence with hold.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.TextEdit",
                                                                   name: "TextEdit"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        try ledger.link(noteID: bothPlaces.id, toLookup: elsewhere, at: now)

        let impact = try ledger.readingImpact(ofSource: "com.apple.Safari")
        #expect(impact.lookups == 2)
        #expect(impact.notesLeftWithoutACue == 1, "only the note met nowhere else")

        try ledger.deleteReading(lookups: try ledger.lookupIDs(fromSource: "com.apple.Safari"))
        #expect(try ledger.readiness(of: onlySafari.id) == .needsRepair)
        #expect(try ledger.readiness(of: bothPlaces.id) == .ready, "it still has a sentence")
    }
}

/// Four claims about the library query that the page tests cannot make, because each is about
/// where an answer *comes from* rather than about which rows come back.
struct StudyLibraryQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func save(_ ledger: Ledger, word: String, at when: Date) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence holding \(word).",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).001",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: when)
    }

    /// **The word and the sentence come from the same reading.** Four copies of the same
    /// correlated `ORDER BY … LIMIT 1` are four places for the ordering rule to drift, and a row
    /// whose word came from one reading and whose sentence came from another would look
    /// perfectly ordinary.
    @Test func arowsReadingIsOneReading() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try save(ledger, word: "settle", at: now.addingTimeInterval(-86_400))
        let newer = try ledger.record(LookupRecord(
            surface: "settled", lemma: "settle", context: "The dust settled overnight.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        try ledger.link(noteID: note.id, toLookup: newer, at: now)

        let row = try #require(try ledger.library(LibraryQuery()).first)
        #expect(row.word == "settled", "the newest reading's word")
        #expect(row.excerpt == "The dust settled overnight.", "and the same reading's sentence")
        #expect(row.readAt == now, "and the same reading's time")
    }

    /// **A state filter judges the card the row draws.** A row loads the meaning card, so a filter
    /// that accepted any of a note's cards could put a row under Paused whose own card says it is
    /// not paused — and under Due a row that is not.
    @Test func astateFilterJudgesTheCardTheRowDraws() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try save(ledger, word: "settle", at: now)
        _ = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let production = try ledger.card(of: note.id, prompt: .production, at: now)
        // **Card-level, because that is the only way to build the case.** `setPaused`
        // takes notes and moves every card under one together, which is why a row whose own
        // card disagrees with its note has never appeared in a test before.
        try ledger.restorePauseStates([production.id: true])

        #expect(try ledger.library(LibraryQuery(state: .paused, now: now)).isEmpty,
                "the card this row draws is not paused")
        #expect(try ledger.library(LibraryQuery(state: .due, now: now)).count == 1,
                "and it is the one that is due")
        #expect(try ledger.libraryCount(LibraryQuery(state: .paused, now: now)) == 0,
                "the count applies the same rule")
    }

    /// **An explicitly empty enrollment set matches nothing.** `nil` already means unrestricted,
    /// so treating `[]` as unrestricted too left a caller with no way to say "none of them" and
    /// gave a query that asked for nothing the whole library instead.
    @Test func anEmptyEnrollmentSetMatchesNothing() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try save(ledger, word: "settle", at: now)
        #expect(try ledger.library(LibraryQuery(enrollment: [])).isEmpty)
        #expect(try ledger.libraryCount(LibraryQuery(enrollment: [])) == 0)
        #expect(try ledger.library(LibraryQuery(enrollment: nil)).count == 1,
                "nil is still unrestricted")
    }

    /// **The count and the page agree under every filter.** The count is its own SQL now rather
    /// than the page query run with no limit, so the two can disagree — and a surface that
    /// promises rows no page will hand out is the defect this replaces.
    @Test func thecountAgreesWithThePageUnderEveryFilter() throws {
        let ledger = try Ledger(path: ":memory:")
        for index in 0..<12 {
            let note = try save(ledger, word: "word\(index)", at: now.addingTimeInterval(Double(-index)))
            let card = try ledger.card(of: note.id, prompt: .meaning, at: now)
            if index % 3 == 0 { try ledger.restorePauseStates([card.id: true]) }
        }
        let states: [LibraryQuery.State?] = [nil, .due, .paused, .needsAttention, .struggling]
        for state in states {
            var page = LibraryQuery(state: state, now: now); page.limit = 500
            let rows = try ledger.library(page).count
            let counted = try ledger.libraryCount(LibraryQuery(state: state, now: now))
            #expect(rows == counted, "\(String(describing: state)): \(rows) rows against \(counted)")
        }
        var searched = LibraryQuery(text: "word1"); searched.limit = 500
        let found = try ledger.library(searched).count
        #expect(found == (try ledger.libraryCount(LibraryQuery(text: "word1"))), "and under a search")
    }
}

/// **What a card read does with a row it cannot understand, and what asking "is there anything"
/// costs.** Both are about the shape of an answer rather than its value, so no existing test
/// could have noticed either.
struct StudyCardReadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func save(_ ledger: Ledger, word: String) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence holding \(word).",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).001",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    /// **A row this schema cannot read is corruption, not an absence.** Skipping it returned a
    /// shorter list indistinguishable from a reader with fewer cards, so a damaged file lost work
    /// silently and a queue that should have refused went on handing out questions.
    @Test func acardRowThisSchemaCannotReadIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try save(ledger, word: "settle")
        try ledger.confirm(noteIDs: [note.id], at: now)
        let card = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let queue = { try ledger.dueCards(at: self.now, limit: 10, dictionary: nil,
                                          newAllowance: 20, dayStart: self.now) }
        #expect(try queue().map(\.id) == [card.id], "the queue can reach it while it is readable")

        // **`prompt`, because `phase` has a CHECK and `prompt` does not.** No code path can write
        // an unknown prompt — every writer passes the enum — so the only source is a damaged or
        // hand-edited file, which is exactly the case a read must refuse rather than skip.
        // The queue is the read that sees it: every prompt-scoped query filters the row out
        // by its `WHERE`, which is correct and is why this went unnoticed.
        try ledger.run("UPDATE study_cards SET prompt = 'no-such-prompt' WHERE id = ?",
                       bind: [.text(card.id.uuidString)]) { _ in }
        #expect(throws: LedgerError.corruptRow("study_cards \(card.id.uuidString)")) {
            _ = try queue()
        }
    }

    /// **Whether there is a single note is not the same question as what they all are.** The app
    /// used to load, sort and decode the whole collection to answer one bit.
    @Test func existenceIsItsOwnQuestion() throws {
        let ledger = try Ledger(path: ":memory:")
        #expect(try ledger.hasAnyNote() == false)
        #expect(try ledger.hasAnyNote() == !(try ledger.notes().isEmpty))
        _ = try save(ledger, word: "settle")
        #expect(try ledger.hasAnyNote())
        #expect(try ledger.hasAnyNote() == !(try ledger.notes().isEmpty))
    }

    /// **One card query for a page, and every row still gets its own card.** Batching it is only
    /// a saving if each row is still handed the card that belongs to it.
    @Test func everyRowOnApageIsHandedItsOwnCard() throws {
        let ledger = try Ledger(path: ":memory:")
        var expected: [UUID: UUID] = [:]
        for index in 0..<8 {
            let note = try save(ledger, word: "word\(index)")
            expected[note.id] = try ledger.card(of: note.id, prompt: .meaning, at: now).id
        }
        let rows = try ledger.library(LibraryQuery())
        #expect(rows.count == 8)
        for row in rows {
            #expect(row.card?.id == expected[row.note.id], "\(row.word) has its own card")
        }
    }
}

/// **A card asking a question this build cannot present.** `StudyCards` declares `.production`
/// ahead of the surface that will ask it, and nothing creates one — so the risk is not that a
/// reader meets one, it is that the day someone builds the surface, both halves of a card go on
/// answering as though it were a meaning card.
struct StudyPromptTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acardThisBuildCannotAskIsRefusedRatherThanMislabelled() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        let meaning = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let production = try ledger.card(of: note.id, prompt: .production, at: now)

        #expect(try ledger.cue(forCard: meaning.id) != nil, "the card this build does ask")
        #expect(try ledger.revealed(cardID: meaning.id) != nil)
        #expect(throws: LedgerError.unaskablePrompt("production")) {
            _ = try ledger.cue(forCard: production.id)
        }
        #expect(throws: LedgerError.unaskablePrompt("production")) {
            _ = try ledger.revealed(cardID: production.id)
        }
    }

    /// **The creating accessor finds what the reading one finds.** Two spellings of "does this
    /// note already have this card" is two chances for one to stop matching the other, and the
    /// creating one would then insert a duplicate.
    @Test func askingForAcardTwiceMakesOne() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        let first = try ledger.card(of: note.id, prompt: .meaning, at: now)
        let again = try ledger.card(of: note.id, prompt: .meaning, at: now.addingTimeInterval(60))
        #expect(first.id == again.id)
        #expect(try ledger.existingCard(of: note.id, prompt: .meaning)?.id == first.id)
        #expect(try ledger.cards(ofNotes: [note.id], prompt: .meaning).count == 1)
    }
}
