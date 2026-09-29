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
        try save(ledger, word: "hold", sentence: "The cargo was lowered into the hold.",
                 answer: "the compartment of a ship below deck")
        // Its own sentence, because the default one — "A sentence holding fine." — contains
        // *holding*, and a fixture that matches the search by accident proves nothing.
        try save(ledger, word: "fine", sentence: "He paid the fine.",
                 answer: "a sum exacted as a penalty")

        #expect(try ledger.library(LibraryQuery(text: "hold")).count == 1)
        #expect(try ledger.library(LibraryQuery(text: "cargo")).count == 1, "the reader's own sentence")
        #expect(try ledger.library(LibraryQuery(text: "penalty")).count == 1, "the answer")
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
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil).isEmpty)
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

    /// A bulk action lands on exactly the set it was given, all of it or none.
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
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil).isEmpty)
        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled)
        try ledger.setPaused(false, ofNotes: [note.id])
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil).count == 1)
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
        try ledger.deleteReading(lookups: try ledger.lookupIDs(evidencing: note.id))
        #expect(try ledger.history(of: "fine").isEmpty)
        #expect(try ledger.library(LibraryQuery()).count == 1)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
        #expect(try ledger.answer(of: note.id) != nil, "and the answer it had is still there")
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
