import DictionaryModel
import Foundation
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
        let legal = try save(ledger, word: "fine")
        try save(ledger, word: "hold")
        try ledger.tag(noteID: legal.id, "legal")

        let rows = try ledger.library(LibraryQuery(tag: "legal"))
        #expect(rows.map(\.id) == [legal.id])
        #expect(try ledger.libraryCount(LibraryQuery(tag: "legal")) == 1)
        #expect(try ledger.library(LibraryQuery(tag: "nobody")).isEmpty)
        #expect(try ledger.library(LibraryQuery()).count == 2, "and no tag is no narrowing")
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
        let before = try ledger.pauseStates(ofNotes: ids)
        #expect(before[meaning.id] == false)
        #expect(before[production.id] == true, "one card of this note is resting and one is not")

        try ledger.setPaused(true, ofNotes: ids)
        #expect(try ledger.pauseStates(ofNotes: ids).values.allSatisfy { $0 })

        try ledger.restorePauseStates(before)
        let after = try ledger.pauseStates(ofNotes: ids)
        #expect(after == before, "each card went back to its own state, not the note's")
        #expect(after[meaning.id] == false, "the card that was running is running again")
        #expect(after[production.id] == true)
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
        let card = try #require(try ledger.card(of: note.id, at: now))
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
