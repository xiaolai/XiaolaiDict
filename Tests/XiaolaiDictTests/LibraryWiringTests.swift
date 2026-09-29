import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
@testable import XiaolaiDict

/// **The Library window against a real ledger.** WI-005's wire.
///
/// `StudyLibraryTests` proves the query; these prove that the reader's filter reaches it, that a bulk
/// action lands on the set they selected, and that the row says why a card is not being asked.
@MainActor
struct LibraryWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-library-\(UUID().uuidString).sqlite").path
        return (path, { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } })
    }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String, script: ProbeScript = .latin) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word) in it.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil, script: script))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    private func model(_ path: String, scripts: Set<ProbeScript> = [.latin]) -> LibraryModel {
        // **Somewhere disposable, always.** Nothing in this suite exports, but a default that
        // reached the reader's Downloads folder is how the other suite's export test came to
        // delete what it found there.
        let exports = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-export-\(UUID().uuidString)", isDirectory: true)
        return LibraryModel(store: { Task { try LedgerStore(path: path) } },
                            studyScripts: { scripts }, clock: { self.now },
                            exportDirectory: { exports })
    }

    @Test func thelibraryListsWhatTheReaderSaved() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.count == 2)
        #expect(model.presentation.total == 2)
        #expect(model.presentation.rows.allSatisfy { !$0.answer.isEmpty }, "the row carries its answer")
        #expect(model.presentation.rows.allSatisfy { $0.status == nil }, "and nothing is wrong with it")
    }

    /// The search reaches the query, not a filter applied to the page after it.
    @Test func searchingNarrowsTheQuery() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        model.act(.search("hold"))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.rows.first?.word == "hold")
        #expect(model.presentation.total == 1, "the count is of what matched, not of the page")
    }

    /// **M10, at the wire.** The script filter is off until the reader asks for it.
    @Test func thescriptFilterIsOffUntilAsked() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine", script: .latin)
        try save(ledger, "水", script: .han)

        let model = model(path, scripts: [.latin])
        await model.reload()
        #expect(model.presentation.rows.count == 2, "a card outside the reader's scripts is not hidden")
        model.act(.filterScripts(true))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.scriptFiltered)
    }

    /// A bulk action lands on exactly the selection and clears it afterwards.
    @Test func abulkArchiveAffectsTheSelectionAndClearsIt() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id]))
        try await settle { model.presentation.selection == [fine.id] }
        model.act(.archive)
        try await settle { model.presentation.selection.isEmpty }

        let reopened = try Ledger(path: path)
        let rows = try reopened.library(LibraryQuery())
        #expect(rows.first(where: { $0.id == fine.id })?.note.enrollment == .archived)
        #expect(rows.first(where: { $0.id != fine.id })?.note.enrollment == .active)
    }

    /// **Remove from study keeps the reading.** The row goes; the lookup does not.
    @Test func removingFromStudyLeavesTheReading() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id]))
        try await settle { model.presentation.selection == [fine.id] }
        model.act(.removeFromStudy)
        try await settle { model.presentation.rows.isEmpty }

        let reopened = try Ledger(path: path)
        #expect(try reopened.history(of: "fine").count == 1, "the reader's reading was not theirs to take")
    }

    /// The row says why a card is not being asked, so the library can show what needs attention.
    @Test func arowSaysWhyAcardIsNotBeingAsked() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        // Saved with no answer at all rather than reaching into the schema: a test that writes SQL
        // is a test that keeps working after the schema stops meaning what it did.
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "A sentence with fine in it.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        let broken = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-broken", senseKey: "e-broken.1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader, answer: nil, lookupID: lookup, at: now)
        let paused = try save(ledger, "hold")
        try ledger.setPaused(true, ofNotes: [paused.id])

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.first(where: { $0.id == broken.id })?.status == .needsRepair)
        #expect(model.presentation.rows.first(where: { $0.id == paused.id })?.status == .paused)
    }

    // MARK: - What the inspector shows (M03, M05, U03)

    /// **The audit trail reaches the reader** (M05). `timeline`, `reviews(ofCard:)` and
    /// `encounters(ofLookup:)` all existed with no surface between them.
    @Test func theinspectorShowsReadingsAndReviewsSeparately() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try MemoryScheduler())

        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.inspector != nil }
        let inspector = try #require(model.presentation.inspector)
        #expect(inspector.readings.count == 1)
        #expect(inspector.readings.first?.sentence == "A sentence with fine in it.")
        #expect(inspector.reviews.count == 1)
        #expect(inspector.reviews.first?.grade == .good)
        #expect(inspector.reviews.first?.isPractice == false)
    }

    /// **A tag the reader adds can be read back and taken off** (M03). It could be added and then
    /// never seen again, which is a worse state than not having tags.
    @Test func atagIsVisibleAndRemovable() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")

        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.inspector != nil }
        model.act(.tag("legal"))
        model.act(.select([note.id]))
        try await settle { model.presentation.inspector?.tags == ["legal"] }

        // **And it can be searched by.** A tag that can be written and never found again is half
        // a feature; `allTags` existed with nothing reading it.
        #expect(model.presentation.tagVocabulary.map(\.tag) == ["legal"])
        model.act(.filterTag("legal"))
        try await settle { model.presentation.tag == "legal" && model.presentation.rows.count == 1 }
        model.act(.filterTag(nil))
        try await settle { model.presentation.tag == nil }

        model.act(.select([note.id]))
        try await settle { model.presentation.inspector != nil }
        model.act(.untag(noteID: note.id, tag: "legal"))
        try await settle { model.presentation.inspector?.tags.isEmpty == true }
        #expect(try Ledger(path: path).tags(of: note.id).isEmpty)
        #expect(model.presentation.tagVocabulary.isEmpty, "and the empty tag stops being offered")
    }

    /// **Study actually looks the word up.** `suggestionTaken` was set and `takeSuggestion` was
    /// called by these tests alone — nothing in the app read either, so pressing Study did
    /// nothing at all. A control that silently refuses its own click is worse than a disabled
    /// one: there is not even a reason to read.
    @Test func pressingStudyOnAsuggestionAsksForAlookup() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        for day in 0..<2 {
            _ = try ledger.record(LookupRecord(
                surface: "recondite", lemma: "recondite", context: "A recondite argument.",
                lemmaBasis: .tagger, language: "en", contextRange: nil,
                place: ReadingPlace(bundleID: nil, name: nil),
                lookedUpAt: now.addingTimeInterval(Double(day) * 86_400), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
        }

        var asked: [String] = []
        let model = LibraryModel(store: { Task { try LedgerStore(path: path) } },
                                 studyScripts: { [.latin] }, clock: { self.now },
                                 lookUp: { asked.append($0) })
        model.act(.filter(.suggested))
        try await settle { model.presentation.suggestions.count == 1 }

        model.act(.study(lemma: "recondite"))
        #expect(asked == ["recondite"], "the word never reached the lookup path")
    }

    /// **"Already know" is reversible** (C05). `unignoreSuggestion` existed and nothing reached
    /// it, so a word declared known by a mis-click was declared known for ever — and invisibly,
    /// because setting one aside enrols nothing and leaves no row in the library to find.
    ///
    /// The reversal belongs beside the suggestions, which is the only place the declaration has
    /// any effect.
    @Test func alreadyKnowCanBeTakenBack() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        // Looked up on two days, so it would be suggested.
        for day in 0..<2 {
            _ = try ledger.record(LookupRecord(
                surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
                language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
                lookedUpAt: now.addingTimeInterval(Double(day) * 86_400), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
        }

        let model = model(path)
        model.act(.filter(.suggested))
        try await settle { model.presentation.suggestions.count == 1 }

        model.act(.ignore(lemma: "fine", language: "en"))
        try await settle { model.presentation.suggestions.isEmpty }
        // **And it is visible where it went**, or "already know" is a word that disappears.
        try await settle { model.presentation.setAside.map(\.lemma) == ["fine"] }

        model.act(.unignore(lemma: "fine", language: "en"))
        try await settle { model.presentation.suggestions.count == 1 }
        #expect(model.presentation.setAside.isEmpty)
    }

    /// **The retention figure states its denominator, or is absent** (U03). `retention` was
    /// computed by nothing and shown to nobody; a rate with no denominator beside it is the one
    /// number in this product that cannot be checked afterwards.
    @Test func theretentionFigureArrivesWithItsDenominatorOrNotAtAll() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        let scheduler = try MemoryScheduler()

        let model = model(path)
        await model.reload()
        #expect(model.presentation.retention == nil, "a first review is an introduction, not a recall")

        // One introduction, then a delayed recall a week later: one eligible attempt.
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: scheduler)
        let later = now.addingTimeInterval(7 * 86_400)
        let revision = try #require(try ledger.card(id: card.id)).revision
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: revision,
                             at: later, using: scheduler)

        await model.reload()
        let retention = try #require(model.presentation.retention)
        #expect(retention.attempts == 1, "the introduction is excluded")
        #expect(retention.successes == 1)
    }

    /// **What is on screen is the answer to the last thing the reader asked.**
    ///
    /// Every reload suspends several times, and each keystroke starts another. Fired as a burst,
    /// because that is how a search field behaves.
    ///
    /// **This does not verify the generation guard, and must not be read as doing so.** Measured
    /// 2026-09-30: it passes three times out of three with the guard removed, because separately
    /// created `Task`s on the main actor happen to resume in the order they were made here. The
    /// guard is kept because that ordering is not a guarantee Swift makes — but the race it
    /// closes was not reproducible through this model's own API, so what is written here is an
    /// invariant, not a control.
    @Test func thelastRequestIsTheOneOnScreen() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        try save(ledger, "hold")
        try save(ledger, "holding")

        let model = model(path)
        await model.reload()
        for term in ["f", "fi", "fin", "fine", "h", "ho", "hol"] { model.act(.search(term)) }
        try await settle {
            model.presentation.search == "hol" && model.presentation.rows.count == 2
        }
        #expect(model.presentation.search == "hol")
        #expect(Set(model.presentation.rows.map(\.word)) == ["hold", "holding"],
                "showed \(model.presentation.rows.map(\.word)) under a search for hol")
        #expect(model.presentation.total == 2, "and the count agrees with the list")
    }

    /// **A card put off until tomorrow does not say "Due".** The library read the schedule and
    /// not `hiddenUntil`, so a card the reader had deliberately set aside sat in the list looking
    /// exactly like work waiting for them — and no batch that day would offer it.
    @Test func apostponedCardSaysWhenItComesBack() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        try ledger.postpone(cardID: card.id, until: now.addingTimeInterval(86_400))

        let model = model(path)
        await model.reload()
        let row = try #require(model.presentation.rows.first)
        #expect(row.due != "Due", "a card nothing will offer today is not due")
        #expect(row.due != "New", "and it is not waiting to be introduced either")
    }

    // MARK: - Bulk actions, and putting them back (M04)

    /// **Pause was a one-way door.** `setPaused(false, …)` existed and nothing could reach it, so a
    /// reader who paused a selection had no way back — not by undo and not by hand. Both halves
    /// are wired here: the control turns into Resume when everything selected is already resting.
    @Test func pausingIsReversibleByHand() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        _ = try ledger.card(of: note.id, at: now)

        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        #expect(model.presentation.selectionIsPaused == false)

        model.act(.pause)
        try await settle { model.presentation.rows.first?.status == .paused }
        model.act(.select([note.id]))
        try await settle { model.presentation.selectionIsPaused }

        model.act(.resume)
        try await settle { model.presentation.rows.first?.status == nil }
        #expect(try Ledger(path: path).pauseStates(ofNotes: [note.id]).values.allSatisfy { !$0 })
    }

    /// Archiving likewise: out of the way, and reachable again.
    @Test func archivingIsReversibleByHand() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")

        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        model.act(.archive)
        try await settle { model.presentation.rows.first?.status == .archived }

        model.act(.select([note.id]))
        try await settle { model.presentation.selectionIsArchived }
        model.act(.unarchive)
        try await settle { model.presentation.rows.first?.status == nil }
        #expect(try Ledger(path: path).enrollments(ofNotes: [note.id])[note.id] == .active)
    }

    /// **The undo restores what each row was**, which is the whole difficulty: one of these is
    /// already paused before the bulk action, and an undo that resumed everything would be a
    /// second unasked-for change wearing the label of a reversal.
    @Test func undoingAbulkPausePutsEachRowBackAsItWas() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let resting = try save(ledger, "resting")
        let working = try save(ledger, "working")
        _ = try ledger.card(of: resting.id, at: now)
        _ = try ledger.card(of: working.id, at: now)
        try ledger.setPaused(true, ofNotes: [resting.id])

        let model = model(path)
        await model.reload()
        #expect(model.presentation.undoable == nil, "nothing has happened yet")
        model.act(.select([resting.id, working.id]))
        try await settle { model.presentation.selection.count == 2 }
        model.act(.pause)
        try await settle { model.presentation.rows.allSatisfy { $0.status == .paused } }
        #expect(model.presentation.undoable == .pause(2))

        model.act(.undo)
        try await settle { model.presentation.undoable == nil }
        let states = try Ledger(path: path).pauseStates(ofNotes: [resting.id, working.id])
        #expect(states.values.filter { $0 }.count == 1,
                "the one that was already resting is still resting")
        let byWord = Dictionary(uniqueKeysWithValues:
            model.presentation.rows.map { ($0.word, $0.status) })
        #expect(byWord["resting"] == .paused)
        #expect(byWord["working"] == LibraryPresentation.Status?.none)
    }

    /// And an archive that swept up a candidate puts the candidate back as a candidate.
    @Test func undoingAbulkArchiveDoesNotEnrolAnything() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let active = try save(ledger, "working")
        let candidate = try save(ledger, "offered")
        try ledger.setEnrollment(.candidate, of: candidate.id)

        let model = model(path)
        await model.reload()
        model.act(.select([active.id, candidate.id]))
        try await settle { model.presentation.selection.count == 2 }
        model.act(.archive)
        try await settle { model.presentation.undoable == .archive(2) }

        model.act(.undo)
        try await settle { model.presentation.undoable == nil }
        let after = try Ledger(path: path).enrollments(ofNotes: [active.id, candidate.id])
        #expect(after[candidate.id] == .candidate, "not promoted by way of being restored")
        #expect(after[active.id] == .active)
    }

    /// **One level, and it stops being offered once something else has happened.** An undo button
    /// that survives an unrelated change is one the reader will press expecting it to reverse the
    /// last thing they did.
    @Test func theundoIsRetiredByThenextChange() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        _ = try ledger.card(of: note.id, at: now)

        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        model.act(.pause)
        try await settle { model.presentation.undoable == .pause(1) }

        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        model.act(.tag("later"))
        try await settle { model.presentation.undoable == nil }
    }

    // MARK: - The inspector

    /// **`setReaderAnswer` had no caller.** A ledger method with tests and no surface is not a
    /// feature — this is the wire that makes it one, and it asserts the write landed rather than
    /// that a button exists.
    @Test func thereaderCanReplaceTheAnswerFromTheInspector() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")

        let model = model(path)
        await model.reload()
        #expect(model.presentation.inspector == nil, "nothing is selected")
        model.act(.select([note.id]))
        try await settle { model.presentation.inspector != nil }
        let inspector = try #require(model.presentation.inspector)
        #expect(inspector.word == "fine")
        #expect(inspector.answer == "what fine means")
        #expect(inspector.isReaders == false, "the dictionary's words, so far")

        model.act(.setAnswer(noteID: note.id, text: "the money you pay when caught"))
        try await settle { model.presentation.inspector?.isReaders == true }
        #expect(model.presentation.inspector?.answer == "the money you pay when caught")

        let reopened = try Ledger(path: path)
        #expect(try reopened.answer(of: note.id)?.text == "the money you pay when caught")
        #expect(try reopened.answer(of: note.id)?.origin == .reader)
    }

    /// **An edit reaches the row the reader was looking at, not the row the model has moved to.**
    ///
    /// Selection changes at once; the inspector catches up after a reload. In that window the
    /// pane still shows A — A's word, A's answer, A's text in the editor — while the model's
    /// selection is already B. Saving then wrote A's answer onto B, and untag had the same
    /// targeting. The view knows which row it is showing; the action carries it.
    @Test func anEditReachesTheRowTheInspectorWasShowing() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let first = try save(ledger, "fine")
        let second = try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([first.id]))
        try await settle { model.presentation.inspector?.id == first.id }

        // The reader clicks the other row and saves before the reload has redrawn the pane, so
        // the edit is still the one they were typing into.
        model.act(.select([second.id]))
        model.act(.setAnswer(noteID: first.id, text: "the money you pay when caught"))
        try await settle { (try? Ledger(path: path).answer(of: first.id)?.text)
            == "the money you pay when caught" }

        let reopened = try Ledger(path: path)
        #expect(try reopened.answer(of: first.id)?.text == "the money you pay when caught")
        #expect(try reopened.answer(of: second.id)?.text == "what hold means",
                "the row the reader was not looking at is untouched")
    }

    /// The same for taking a tag off.
    @Test func untaggingReachesTheRowTheInspectorWasShowing() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let first = try save(ledger, "fine")
        let second = try save(ledger, "hold")
        try ledger.tag(noteID: first.id, "legal")
        try ledger.tag(noteID: second.id, "legal")

        let model = model(path)
        await model.reload()
        model.act(.select([first.id]))
        try await settle { model.presentation.inspector?.tags == ["legal"] }

        model.act(.select([second.id]))
        model.act(.untag(noteID: first.id, tag: "legal"))
        try await settle { (try? Ledger(path: path).tags(of: first.id))?.isEmpty == true }
        #expect(try Ledger(path: path).tags(of: second.id) == ["legal"],
                "the other row keeps its tag")
    }

    /// **One row, or none.** An inspector over a multiple selection would have to pick a row to
    /// edit, and the reader cannot see which — so it is absent, and the bulk controls are what a
    /// multiple selection offers.
    @Test func theinspectorIsAbsentForAmultipleSelection() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let first = try save(ledger, "fine")
        let second = try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([first.id, second.id]))
        try await settle { model.presentation.selection.count == 2 }
        #expect(model.presentation.inspector == nil)
    }

    /// **The struggling filter reaches the query**, and the model does not narrow a page after it.
    @Test func thestrugglingFilterReachesTheLedger() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let bad = try save(ledger, "recalcitrant")
        try save(ledger, "easy")
        let scheduler = try MemoryScheduler()
        let card = try ledger.card(of: bad.id, at: now)
        for day in 0..<Ledger.repeatedLapseDays {
            let revision = try #require(try ledger.card(id: card.id)).revision
            _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(),
                                 expectedRevision: revision,
                                 at: now.addingTimeInterval(Double(day) * 86_400), using: scheduler)
        }

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.count == 2)
        model.act(.filter(.struggling))
        try await settle { model.presentation.filter == .struggling && model.presentation.rows.count == 1 }
        #expect(model.presentation.rows.first?.word == "recalcitrant")
        #expect(model.presentation.total == 1, "and the count is the filtered one")
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}

extension LibraryWiringTests {
    /// **A destructive action must affect exactly what the footer says.**
    ///
    /// The selection was pruned into the *presentation* and not in the model, so selecting two rows
    /// and then searching until one was visible showed "Remove 1" over a command that removed both.
    /// The reader sees a count and presses a button; those have to be the same set.
    @Test func abulkActionCannotReachRowsTheReaderCanNoLongerSee() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")
        let hold = try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id, hold.id]))
        try await settle { model.presentation.selection.count == 2 }

        // Narrow until only one of them is on screen.
        model.act(.search("hold"))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.selection == [hold.id], "the footer counts what is visible")

        model.act(.removeFromStudy)
        try await settle { model.presentation.rows.isEmpty }

        let reopened = try Ledger(path: path)
        let left = try reopened.library(LibraryQuery())
        #expect(left.map(\.id) == [fine.id],
                "the action reached a row the reader could not see")
    }
}

extension LibraryWiringTests {
    /// **A status with no remedy is a diagnosis.** The library showed "Confirm the meaning" and
    /// offered no way to confirm, so a proposal the reader saved stayed out of review for ever.
    @Test func thereaderCanConfirmAproposalFromTheLibrary() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        // Enrolled as the model proposed it: saved, and not askable.
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                 newAllowance: .max, dayStart: .distantPast).isEmpty)

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.first?.status == .needsConfirmation)
        model.act(.select([note.id]))
        try await settle { model.presentation.canConfirm }
        model.act(.confirm)
        try await settle { model.presentation.rows.first?.status == nil }

        let reopened = try Ledger(path: path)
        #expect(try reopened.readiness(of: note.id) == .ready)
        #expect(try reopened.dueCards(at: now, limit: 10, dictionary: nil,
                                 newAllowance: .max, dayStart: .distantPast).count == 1,
                "and it can now be asked")
    }

    /// **Everything that matched is reachable.** The model asked for one page and the view offered
    /// no continuation, so a library of 201 counted 201 and could show only 200 — and the 201st was
    /// reachable only by guessing a search term that narrowed to it.
    @Test func everyMatchingRowIsReachable() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let total = LibraryModel.pageSize + 1
        for index in 0..<total {
            try save(ledger, "word\(String(format: "%04d", index))")
        }
        let model = model(path)
        await model.reload()
        #expect(model.presentation.total == total)
        #expect(model.presentation.rows.count == LibraryModel.pageSize)
        #expect(model.presentation.hasMore, "no way to reach the rest")

        model.act(.showMore)
        try await settle { model.presentation.rows.count == total }
        #expect(!model.presentation.hasMore, "and nothing offers more than there is")
        #expect(model.presentation.rows.contains { $0.word == "word0000" }, "the oldest is reachable")
    }
}

/// **WI-007's surfaces, at the wire.** Tags, export and suggestions are Core features with library
/// controls; each of these asserts the control reaches the ledger, because a feature nothing calls
/// is not one.
@MainActor
struct LibraryOrganisationWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-org-\(UUID().uuidString).sqlite").path
        return (path, { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } })
    }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .reader, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    /// A scratch directory for this suite's exports. **Never the reader's own Downloads**: the
    /// export test used to write there and then delete what it found, so every `make test` on any
    /// Mac destroyed an export its owner had made.
    private func exportScratch() -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-export-\(UUID().uuidString)", isDirectory: true)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    private func model(_ path: String, exportTo directory: URL? = nil,
                       at when: Date? = nil) -> LibraryModel {
        // **Always somewhere disposable**, even when a test does not care: a default that reached
        // the real Downloads folder is exactly how this went wrong the first time.
        let exports = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-export-\(UUID().uuidString)", isDirectory: true)
        let clock = when ?? now
        return LibraryModel(store: { Task { try LedgerStore(path: path) } },
                            studyScripts: { [.latin] }, clock: { clock },
                            exportDirectory: { exports })
    }

    @Test func taggingTheSelectionReachesTheLedger() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        model.act(.tag("law"))
        try await settle { (try? Ledger(path: path).tags(of: note.id)) == ["law"] }
        #expect(try Ledger(path: path).tags(of: note.id) == ["law"])
    }

    /// **The file lands where the reader is told it lands**, and holds no publisher gloss.
    @Test func exportingWritesAfileAndSaysWhere() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let (exports, cleanExports) = exportScratch()
        defer { cleanExports() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        let model = model(path, exportTo: exports)
        await model.reload()
        model.act(.export)
        try await settle { model.presentation.exported != nil }

        let written = try #require(model.presentation.exported)
        // **Inside the scratch directory, not the reader's.** Asserted rather than assumed: the
        // destination is injected now, and a default that leaked back would put this test's
        // writes — and its cleanup — into someone's Downloads folder again.
        #expect(written.hasPrefix(exports.path), "wrote outside the scratch directory: \(written)")
        #expect(FileManager.default.fileExists(atPath: written), "no file at \(written)")
        let text = try String(contentsOfFile: written, encoding: .utf8)
        #expect(text.contains("what fine means"), "the reader's own answer should travel")
        #expect(text.contains("#columns:XiaolaiDictID"))
    }

    /// **No export replaces another.** One fixed filename meant a second export silently
    /// destroyed the first, and an atomic write is still a replacement.
    @Test func asecondExportDoesNotReplaceTheFirst() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let (exports, cleanExports) = exportScratch()
        defer { cleanExports() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")

        let first = model(path, exportTo: exports)
        await first.reload()
        first.act(.export)
        try await settle { first.presentation.exported != nil }
        let one = try #require(first.presentation.exported)

        // A later sitting: the name carries the instant, so a second export is a second file.
        let second = model(path, exportTo: exports, at: now.addingTimeInterval(60))
        await second.reload()
        second.act(.export)
        try await settle { second.presentation.exported != nil }
        let two = try #require(second.presentation.exported)

        #expect(one != two, "both exports went to \(one)")
        #expect(FileManager.default.fileExists(atPath: one), "the first export was destroyed")
        #expect(FileManager.default.fileExists(atPath: two))
    }

    /// Suggestions appear under their own filter and are **offered, never enrolled**.
    @Test func suggestionsAreOfferedAndTakingOneEnrolsNothing() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        for offset in [0.0, 86_400.0] {
            _ = try ledger.record(LookupRecord(
                surface: "recondite", lemma: "recondite", context: "A recondite point.",
                lemmaBasis: .tagger, language: "en", contextRange: nil,
                place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
                lookedUpAt: now.addingTimeInterval(offset), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
        }
        let model = model(path)
        model.act(.filter(.suggested))
        try await settle { !model.presentation.suggestions.isEmpty
            || model.presentation.problem != nil }
        #expect(model.presentation.problem == nil, "reload failed: \(model.presentation.problem ?? "")")
        #expect(model.presentation.suggestions.first?.lemma == "recondite")
        #expect(model.presentation.suggestions.first?.days == 2)

        model.act(.study(lemma: "recondite"))
        #expect(model.takeSuggestion() == "recondite", "the app is handed the word to look up")
        #expect(model.takeSuggestion() == nil, "and it cannot be taken up twice by a redraw")
        #expect(try Ledger(path: path).notes().isEmpty, "a suggestion enrolled something")

        model.act(.ignore(lemma: "recondite", language: "en"))
        try await settle { model.presentation.suggestions.isEmpty }
        #expect(try Ledger(path: path).notes().isEmpty, "\"already know\" made a card")
        #expect(try Ledger(path: path).history(of: "recondite").count == 2, "and erased nothing")
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}
