import CaptureModel
import DictionaryModel
import Foundation
@testable import StudyKit
import Testing
import XiaolaiDictTestSupport
import XiaolaiDictUI
@testable import XiaolaiDict

@MainActor
struct LearningLibraryWiringTests {
    @Test func panesShareOneLibraryAndRememberChoice() throws {
        let defaults = TemporaryDefaults.suite()
        let model = LibraryModel(store: { nil }, defaults: defaults)
        #expect(model.pane == .history)
        model.show(.review)
        #expect(model.pane == .review)
        let reopened = LibraryModel(store: { nil }, defaults: defaults)
        #expect(reopened.pane == .review)
        reopened.show(.discarded)
        #expect(reopened.pane == .discarded)
    }
    @Test func repeatedArchiveDiscardKeepsOriginalUndoReceipt() async throws {
        let (path, clean) = Wiring.scratch("archive-discard"); defer { clean() }
        let ledger = try Ledger(path:path)
        let id = try ledger.record(LookupRecord(surface:"fine",lemma:"fine",context:"A fine day.",language:"en",
            lookedUpAt:.now,result:.found,answeredBy:.dictionaryService,quality:nil))
        let model = LibraryModel(store:Wiring.store(path),defaults:TemporaryDefaults.suite())
        await model.reloadArchive()
        model.actArchive(.discard([id])); model.actArchive(.discard([id]))
        try await Wiring.settle { model.archive.undoCount == 1 && model.archive.rows.isEmpty }
        model.actArchive(.undo)
        try await Wiring.settle { model.archive.rows.count == 1 }
        #expect(try ledger.disposition(ofLookup:id) == .kept)
        #expect(model.archive.problem == nil)
    }

    @Test func criterion8RepeatedOutstandingArchivePagesDoNotDuplicateRows() async throws {
        let (path, clean) = Wiring.scratch("archive-page-coalescing"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0...LibraryModel.pageSize {
            try ledger.record(LookupRecord(surface: "word\(index)", lemma: "word\(index)",
                context: "A word\(index) example.", language: "en",
                lookedUpAt: now.addingTimeInterval(Double(-index)), result: .found,
                answeredBy: .dictionaryService, quality: nil))
        }
        let opening = try #require(Wiring.store(path)())
        let opened = try await opening.value
        let gate = ArchiveReadGate()
        var requests = 0
        let model = LibraryModel(store: {
            requests += 1
            let number = requests
            return Task { if number > 1 { await gate.wait() }; return opened }
        }, defaults: TemporaryDefaults.suite())
        await model.reloadArchive()
        #expect(model.archive.rows.count == LibraryModel.pageSize)
        #expect(model.archive.hasMore)
        let first = Task { await model.reloadArchive(extending: true) }
        try await Wiring.settle { requests >= 2 }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await model.reloadArchive(extending: true)
        }
        try await Wiring.settle { secondStarted }
        // Await both explicit operations, rather than assuming a dispatched task has finished.
        await gate.open()
        await first.value
        await second.value
        #expect(model.archive.rows.count == LibraryModel.pageSize + 1,
                "criterion 8: outstanding page requests must not append the same page twice")
        #expect(Set(model.archive.rows.map(\.id)).count == model.archive.rows.count,
                "criterion 8: archive pages must retain unique encounter identities")
        #expect(model.archive.rows.last?.lemma == "word\(LibraryModel.pageSize)")
    }

    @Test func criterion8OvertakenArchiveQueryCannotReplaceCurrentSearch() async throws {
        let (path, clean) = Wiring.scratch("archive-query-overtaking"); defer { clean() }
        let ledger = try Ledger(path: path)
        for word in ["first", "second"] {
            try ledger.record(LookupRecord(surface: word, lemma: word, context: "A \(word) example.",
                language: "en", lookedUpAt: .now, result: .found, answeredBy: .dictionaryService, quality: nil))
        }
        let opening = try #require(Wiring.store(path)())
        let opened = try await opening.value
        let gate = ArchiveReadGate()
        var requests = 0
        let model = LibraryModel(store: {
            requests += 1
            let number = requests
            return Task { if number == 1 { await gate.wait() }; return opened }
        }, defaults: TemporaryDefaults.suite())
        let old = Task { await model.reloadArchive() }
        try await Wiring.settle { requests == 1 }
        model.actArchive(.search("second"))
        await model.reloadArchive()
        #expect(model.archive.rows.map(\.lemma) == ["second"], "positive control: newest query arrived")
        await gate.open()
        await old.value
        #expect(model.archive.search == "second")
        #expect(model.archive.rows.map(\.lemma) == ["second"],
                "criterion 8: an overtaken archive reply must not reinstall the old query rows")
        #expect(model.archive.total == 1)
    }

    /// **A permanent delete that could not reach a copy still deleted the reading, and the pane says
    /// both** (audit-fix round 1's verification, #33). The incomplete report was thrown after the rows
    /// had gone, past the reload and the announcement, so Discarded went on listing a reading that no
    /// longer existed under an error about a "row" the schema did not allow. A folder that can be
    /// written and not listed is the shape: the erase cannot know which copies are left.
    @Test func anIncompletePermanentDeleteDropsTheReadingAndSaysWhatItMissed() async throws {
        let (path, clean) = Wiring.scratch("archive-erase-incomplete"); defer { clean() }
        let ledger = try Ledger(path: path)
        let gone = try record(ledger, "fine")
        let kept = try record(ledger, "hold")
        _ = try ledger.changeDisposition(.discarded, lookups: [gone, kept], operation: UUID())
        try ledger.backUp(to: path + ".schema7.backup")
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite())
        model.show(.discarded)
        await model.reloadArchive()
        try #require(Set(model.archive.rows.map(\.id)) == [gone, kept])
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: directory)) == nil,
                     "the folder can still be listed, so this cannot show anything")

        model.actArchive(.erase([gone]))
        try await Wiring.settle("the deleted reading stayed listed, or the pane said nothing of what it missed") {
            model.archive.rows.map(\.id) == [kept] && model.archive.problem != nil
        }
        let problem = try #require(model.archive.problem)
        #expect(problem.contains("could not be read"), "the pane did not say what the erase missed: \(problem)")
        #expect(!problem.contains("LedgerError"), "an incomplete erase was reported as a damaged row: \(problem)")
    }

    /// **Selecting a row does not cancel the read a search started** (audit-fix round 2). One generation
    /// counted both, so a selection made while the search's read was suspended overtook it: the read
    /// stopped, and the selection republished the rows from before the search under the new search's
    /// name — and they stayed, because nothing was reading any more.
    @Test func aSelectionDuringASuspendedReadKeepsThatRead() async throws {
        let (path, clean) = Wiring.scratch("library-select-during-read"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Wiring.save(ledger, "alpha", at: now)
        let beta = try Wiring.save(ledger, "beta", at: now)
        let opening = try #require(Wiring.store(path)())
        let opened = try await opening.value
        let gate = ArchiveReadGate()
        let gated = Setting(false), requests = Setting(0)
        let model = LibraryModel(store: {
            requests.value += 1
            let wait = gated.value
            return Task { if wait { await gate.wait() }; return opened }
        }, clock: { now }, defaults: TemporaryDefaults.suite(), primary: { PrimaryDictionary(chosen: "noad") })
        model.show(.saved)
        try await Wiring.settle("the Saved pane never drew") { model.presentation.rows.count == 2 }
        gated.value = true
        let asked = requests.value
        model.act(.search("beta"))
        try await Wiring.settle("the search never began its read") { requests.value > asked }
        model.act(.select([beta.id]))
        await gate.open()
        try await Wiring.settle("the search's rows never arrived") { model.presentation.rows.map(\.id) == [beta.id] }
        #expect(model.presentation.search == "beta")
        #expect(model.presentation.selection == [beta.id], "the selection made during the read was lost")
    }

    /// **An undo that could put back only some readings still shows what it put back** (audit-fix round 3,
    /// #2). Readings changed since they were discarded are left as they are, which is the ledger working:
    /// the undo committed the rest and then threw "corrupt row" for the count it skipped — so nothing was
    /// announced, the pane was not read again, the readings it had restored stayed missing from History,
    /// and Retry, with the receipt already cleared, had nothing left to do. The commit is shown, and the
    /// skip is said as what it is.
    @Test func aPartialUndoShowsWhatItPutBackAndSaysWhatItLeft() async throws {
        let (path, clean) = Wiring.scratch("archive-undo-partial"); defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try record(ledger, "fine"), hold = try record(ledger, "hold")
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite())
        await model.reloadArchive()
        try #require(model.archive.rows.count == 2)
        model.actArchive(.discard([fine, hold]))
        try await Wiring.settle("the discard never landed") { model.archive.undoCount == 2 && model.archive.rows.isEmpty }
        // Restored since, by another route: the undo must leave it to that later change.
        _ = try ledger.changeDisposition(.kept, lookups: [fine], operation: UUID())

        model.actArchive(.undo)
        // **Both, because the sentence is written an await after the rows** (the review count is read
        // between them): waiting for the rows alone and then reading the sentence raced it under load.
        try await Wiring.settle("the pane never showed the readings the undo put back, and said what it left") {
            Set(model.archive.rows.flatMap(\.lookupIDs)) == [fine, hold] && model.archive.problem != nil
        }
        #expect(try ledger.disposition(ofLookup: hold) == .kept, "the undo did not put back what it could")
        let said = try #require(model.archive.problem, "the reading the undo left alone was not mentioned")
        #expect(!said.contains("LedgerError") && !said.contains("corrupt"), "a skip was reported as damage: \(said)")
        #expect(said.contains("1"), "the count left alone is not said: \(said)")
        #expect(model.archive.undoCount == 0, "the spent undo is still offered")
    }

    /// **A selection made after a read has pruned cannot reach a row that read does not list** (audit-fix
    /// round 3, C1). The read prunes the selection to its rows and then suspends four more times before it
    /// publishes; a click on a row still drawn from the last read, landing in one of those, was left
    /// standing — the read published its rows with the clicked row selected but no longer listed, and
    /// Remove from Study deleted a note the reader could not see. ADR-0035: a destructive control reaches
    /// exactly what its label counts.
    ///
    /// The clock is the read's own: asked once to build the query, and again after the rows are counted
    /// and straight before the prune, with no suspension between that call and the prune. A task made at
    /// the second runs at the read's next suspension — after the prune and before the publish, where a
    /// reader's click lands while the answers are being read.
    @Test func aSelectionMadeAfterTheReadPrunedCannotReachARowItDropped() async throws {
        let (path, clean) = Wiring.scratch("library-select-after-prune"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alpha = try Wiring.save(ledger, "alpha", at: now)
        let beta = try Wiring.save(ledger, "beta", at: now)
        let click = Setting<(@MainActor () -> Void)?>(nil), asked = Setting(0)
        let model = LibraryModel(store: Wiring.store(path), clock: {
            asked.value += 1
            if asked.value == 2, let pending = click.value {
                click.value = nil
                Task { @MainActor in pending() }
            }
            return now
        }, defaults: TemporaryDefaults.suite(), primary: { PrimaryDictionary(chosen: "noad") })
        // **The read alone**, not `show`: showing a pane also counts the review queue, which asks the clock
        // too, and a click fired by that would land before the search and prove nothing.
        await model.reload()
        try #require(model.presentation.rows.count == 2)

        click.value = { model.act(.select([beta.id])) }
        asked.value = 0
        model.act(.search("alpha"))
        try await Wiring.settle("the search's rows never arrived") { model.presentation.rows.map(\.id) == [alpha.id] }
        try #require(click.value == nil, "the click was never made during the read, so this shows nothing")
        #expect(model.presentation.selection.isSubset(of: [alpha.id]),
                "a row the read no longer lists is still selected: \(model.presentation.selection)")

        // **What the control reaches, not only what is drawn.** Removing again with the listed row selected
        // is the positive control, and the point at which both writes have landed.
        model.act(.removeFromStudy)
        model.act(.select([alpha.id]))
        model.act(.removeFromStudy)
        try await Wiring.settle("the listed row was never removed") {
            (try? Ledger(path: path).notes().contains { $0.id == alpha.id }) == false
        }
        #expect(try Ledger(path: path).notes().contains { $0.id == beta.id },
                "Remove from Study deleted a note the reader could not see")
    }

    /// **And a selection naming a row that is not listed selects nothing, before any read publishes**
    /// (audit-fix round 3, C1). The prune at publish is too late for an action taken in the same turn as
    /// the click: Remove from Study reads the selection as soon as it is pressed.
    @Test func aSelectionOfARowNotListedReachesNothing() async throws {
        let (path, clean) = Wiring.scratch("library-select-unlisted"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alpha = try Wiring.save(ledger, "alpha", at: now)
        let beta = try Wiring.save(ledger, "beta", at: now)
        let model = LibraryModel(store: Wiring.store(path), clock: { now }, defaults: TemporaryDefaults.suite(),
                                 primary: { PrimaryDictionary(chosen: "noad") })
        model.act(.search("alpha"))
        try await Wiring.settle("the search's rows never arrived") { model.presentation.rows.map(\.id) == [alpha.id] }

        model.act(.select([beta.id]))
        model.act(.removeFromStudy)
        // The positive control, and the point at which both writes have landed.
        model.act(.select([alpha.id]))
        model.act(.removeFromStudy)
        try await Wiring.settle("the listed row was never removed") {
            (try? Ledger(path: path).notes().contains { $0.id == alpha.id }) == false
        }
        #expect(try Ledger(path: path).notes().contains { $0.id == beta.id },
                "Remove from Study deleted a note that was not listed")
    }

    // MARK: - What Suggested lists (closing pass after round 3, C1)

    /// A Saved pane over three meanings whose reads wait at a gate the test opens, and the model.
    private struct GatedLibrary {
        let path: String, clean: () -> Void
        let alpha: StudyNote, beta: StudyNote, gamma: StudyNote
        let model: LibraryModel, gate: ArchiveReadGate, gated: Setting<Bool>, requests: Setting<Int>
    }

    private func gatedLibrary(_ label: String) async throws -> GatedLibrary {
        let (path, clean) = Wiring.scratch(label)
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alpha = try Wiring.save(ledger, "alpha", at: now)
        let beta = try Wiring.save(ledger, "beta", at: now)
        let gamma = try Wiring.save(ledger, "gamma", at: now)
        let opening = try #require(Wiring.store(path)())
        let opened = try await opening.value
        let gate = ArchiveReadGate()
        let gated = Setting(false), requests = Setting(0)
        let model = LibraryModel(store: {
            requests.value += 1
            let wait = gated.value
            return Task { if wait { await gate.wait() }; return opened }
        }, clock: { now }, defaults: TemporaryDefaults.suite(), primary: { PrimaryDictionary(chosen: "noad") })
        return GatedLibrary(path: path, clean: clean, alpha: alpha, beta: beta, gamma: gamma,
                            model: model, gate: gate, gated: gated, requests: requests)
    }

    /// **What the control reached, read off the ledger.** Remove from Study is pressed over whatever the
    /// model holds selected; then, back on the list, Gamma is removed as the positive control — the point
    /// at which both writes have landed, since the store takes them in order. Alpha and Beta must survive.
    private func removeReachesNothingUnlisted(_ library: GatedLibrary) async throws {
        let model = library.model
        model.act(.removeFromStudy)
        model.act(.search(""))
        model.act(.filter(.all))
        try await Wiring.settle("the list never came back") {
            model.presentation.filter == .all && model.presentation.search.isEmpty
                && model.presentation.rows.contains { $0.id == library.gamma.id }
        }
        model.act(.select([library.gamma.id]))
        model.act(.removeFromStudy)
        try await Wiring.settle("the listed row was never removed") {
            (try? Ledger(path: library.path).notes().contains { $0.id == library.gamma.id }) == false
        }
        let left = Set(try Ledger(path: library.path).notes().map(\.id))
        #expect(left.isSuperset(of: [library.alpha.id, library.beta.id]),
                "Remove from Study deleted a meaning Suggested does not list: \(left.count) of 2 left")
    }

    /// **A selection made while Suggested is being read is dropped when Suggested lists** (closing pass
    /// after round 3, C1). Round 3 pruned at the publish against the rows the read *returned*, and under
    /// Suggested those are every row — its query does not narrow — while the pane draws suggestions in
    /// their place. Alpha and Beta, clicked on the list still drawn while the switch's read was out, were
    /// published selected and unlisted, and Remove from Study, which reads the selection, removed both.
    @Test func aSelectionMadeWhileSuggestedIsReadIsDroppedWhenItLists() async throws {
        let library = try await gatedLibrary("library-select-during-suggested"); defer { library.clean() }
        let model = library.model
        await model.reload()
        try #require(model.presentation.rows.count == 3)

        library.gated.value = true
        let asked = library.requests.value
        model.act(.filter(.suggested))
        try await Wiring.settle("the switch never began its read") { library.requests.value > asked }
        // On the list still drawn — both are listed there, so the click takes.
        model.act(.select([library.alpha.id, library.beta.id]))
        library.gated.value = false
        await library.gate.open()
        try await Wiring.settle("Suggested never drew") { model.presentation.filter == .suggested }
        #expect(model.presentation.selection.isEmpty,
                "Suggested lists no meaning and still holds \(model.presentation.selection.count) selected")
        #expect(model.presentation.rows.isEmpty, "Suggested listed rows it draws suggestions in place of")
        try await removeReachesNothingUnlisted(library)
    }

    /// **The same through a pane switch** (C1). Leaving Saved and coming back while the switch to
    /// Suggested is still being read draws the list from before it again, and starts a read of its own;
    /// a click there was published into Suggested selected and unlisted, by whichever read landed last.
    @Test func aPaneRoundTripDuringTheSuggestedReadKeepsNoSelection() async throws {
        let library = try await gatedLibrary("library-pane-during-suggested"); defer { library.clean() }
        let model = library.model
        model.show(.saved)
        try await Wiring.settle("the Saved pane never drew") { model.presentation.rows.count == 3 }

        library.gated.value = true
        let asked = library.requests.value
        model.act(.filter(.suggested))
        try await Wiring.settle("the switch never began its read") { library.requests.value > asked }
        model.show(.history)
        model.show(.saved)
        // History's read, then Saved's own: the read that coming back starts is the one that publishes,
        // the switch's having been overtaken by it.
        try await Wiring.settle("coming back never began a read") { library.requests.value >= asked + 3 }
        model.act(.select([library.alpha.id, library.beta.id]))
        library.gated.value = false
        await library.gate.open()
        try await Wiring.settle("Suggested never drew") {
            model.pane == .saved && model.presentation.filter == .suggested
        }
        #expect(model.presentation.selection.isEmpty,
                "Suggested lists no meaning and still holds \(model.presentation.selection.count) selected")
        try await removeReachesNothingUnlisted(library)
    }

    /// **And a search under Suggested lists nothing to click** (C1). The search's read narrowed the rows
    /// Suggested does not draw, the presentation carried them, and `.select` admitted any of them — so a
    /// click naming Alpha, with a Remove pressed in the same turn, removed a meaning nobody could see.
    @Test func aSearchUnderSuggestedListsNoRowAClickCanReach() async throws {
        let library = try await gatedLibrary("library-search-under-suggested"); defer { library.clean() }
        let model = library.model
        model.act(.filter(.suggested))
        try await Wiring.settle("Suggested never drew") { model.presentation.filter == .suggested }
        model.act(.search("alpha"))
        try await Wiring.settle("the search never landed") { model.presentation.search == "alpha" }
        #expect(model.presentation.rows.isEmpty, "Suggested listed \(model.presentation.rows.count) row(s) it does not draw")

        // The click and the Remove in one turn: the prune at the next publish would be too late for it.
        model.act(.select([library.alpha.id]))
        try await removeReachesNothingUnlisted(library)
    }

    private func record(_ ledger: Ledger, _ word: String, script: ProbeScript? = .latin, at: Date = .now) throws -> Int {
        try ledger.record(LookupRecord(surface: word, lemma: word, context: "A \(word) example.", language: "en",
            lookedUpAt: at, result: .found, answeredBy: .dictionaryService, quality: nil, script: script))
    }

    /// **The History pane is the reading history, so the studied-scripts setting filters it** — the
    /// same setting the drawer reads, or the two surfaces disagree about what the reader has read.
    @Test func historyIsFilteredByTheScriptsTheReaderStudies() async throws {
        let (path, clean) = Wiring.scratch("archive-scripts"); defer { clean() }
        let ledger = try Ledger(path: path)
        _ = try record(ledger, "fine")
        _ = try record(ledger, "好", script: .han)
        _ = try record(ledger, "42", script: nil)
        let studying = Setting<Set<ProbeScript>>([.latin])
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite(),
                                 studying: { studying.value })
        await model.reloadArchive()
        #expect(Set(model.archive.rows.map(\.lemma)) == ["fine", "42"], "a script the reader does not study was shown")
        #expect(model.archive.total == 2)
        studying.value = [.latin, .han]
        await model.reloadArchive()
        #expect(model.archive.total == 3, "positive control: widening the setting shows the rest")
    }

    /// **A focused reading obeys the pane's filter too.** It is fetched by id rather than paged to,
    /// and that fetch put a reading in a script the reader does not study at the top of History —
    /// shown and selected, though the count beneath it said it was not there.
    @Test func aFocusedReadingOutsideTheStudiedScriptsIsNotPrepended() async throws {
        let (path, clean) = Wiring.scratch("archive-focus-scripts"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let han = try record(ledger, "好", script: .han, at: now.addingTimeInterval(-Double(LibraryModel.pageSize + 1)))
        var latin = 0
        for index in 0...LibraryModel.pageSize {
            latin = try record(ledger, "word\(index)", at: now.addingTimeInterval(Double(-index)))
        }
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite(),
                                 studying: { [.latin] })
        model.show(.history, lookup: latin)
        await model.reloadArchive()
        #expect(model.archive.rows.first?.id == latin, "positive control: a studied focus beyond the page is shown")
        #expect(model.archive.selection == [latin])
        model.show(.history, lookup: han)
        await model.reloadArchive()
        #expect(!model.archive.rows.contains { $0.id == han }, "an unstudied reading was prepended by its focus")
        #expect(model.archive.selection.isEmpty)
        #expect(model.archive.total == LibraryModel.pageSize + 1)
    }

    /// **The largest id SQLite can hand out is still an id.** Focusing it must not overflow — a trap
    /// is a crash, and a guard on our own arithmetic is never fatal (ADR-0043).
    @Test func focusingTheLargestPossibleIDNeitherTrapsNorHidesIt() async throws {
        let (path, clean) = Wiring.scratch("archive-focus-max"); defer { clean() }
        let ledger = try Ledger(path: path)
        let id = try record(ledger, "fine")
        try ledger.run("UPDATE lookups SET id = ? WHERE id = ?", bind: [.integer(Int.max), .integer(id)]) { _ in }
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite(),
                                 studying: { [.latin] })
        model.show(.history, lookup: Int.max)
        await model.reloadArchive()
        #expect(model.archive.rows.map(\.id) == [Int.max])
        #expect(model.archive.selection == [Int.max])
    }

    /// **The same focus past the first page, at an instant `Date` cannot step past by itself.** One row
    /// on the first page is shown whatever the probe answers, so the test above cannot see the probe
    /// at all. At Unix time 1, `Date(timeIntervalSince1970: 1.nextUp)` rounds back to 1 — `Date`
    /// keeps its time from 2001, where 1970 + 1 s has no neighbour that close — and an exclusive
    /// cursor at the focus's own instant excludes the focus.
    @Test func aLargestIDFocusPastTheFirstPageIsStillShown() async throws {
        let (path, clean) = Wiring.scratch("archive-focus-max-deep"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<LibraryModel.pageSize {
            _ = try record(ledger, "word\(index)", at: now.addingTimeInterval(Double(-index)))
        }
        let id = try record(ledger, "fine", at: Date(timeIntervalSince1970: 1))
        try ledger.run("UPDATE lookups SET id = ? WHERE id = ?", bind: [.integer(Int.max), .integer(id)]) { _ in }
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite(),
                                 studying: { [.latin] })
        model.show(.history, lookup: Int.max)
        await model.reloadArchive()
        #expect(model.archive.rows.first?.id == Int.max, "the focus past the first page was hidden")
        #expect(model.archive.selection == [Int.max])
    }

    /// **A pane's controls never stand over another pane's rows.** Discarded offers Restore and a
    /// permanent delete; drawn over History's rows and selection, those reached kept readings.
    @Test func switchingArchivePanesClearsTheOldRowsAtOnce() async throws {
        let (path, clean) = Wiring.scratch("archive-pane-switch"); defer { clean() }
        let ledger = try Ledger(path: path)
        let id = try record(ledger, "fine")
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite())
        await model.reloadArchive()
        model.actArchive(.select([id]))
        #expect(model.archive.selection == [id], "positive control: the kept reading is selected")
        model.show(.discarded)
        #expect(model.pane == .discarded)
        #expect(model.archive.rows.isEmpty, "History's rows were left under Discarded's controls")
        #expect(model.archive.selection.isEmpty)
    }

    /// **A refresh keeps the pages the reader opened.** Every ledger change reloads the archive, and
    /// reloading only the first page dropped older readings they had paged to — and their selection.
    @Test func aRefreshKeepsEveryPageAlreadyShown() async throws {
        let (path, clean) = Wiring.scratch("archive-refresh-depth"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var oldest = 0
        for index in 0...LibraryModel.pageSize {
            oldest = try record(ledger, "word\(index)", at: now.addingTimeInterval(Double(-index)))
        }
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite())
        await model.reloadArchive()
        await model.reloadArchive(extending: true)
        #expect(model.archive.rows.count == LibraryModel.pageSize + 1, "positive control: the second page landed")
        model.actArchive(.select([oldest]))
        await model.reloadArchive()
        #expect(model.archive.rows.count == LibraryModel.pageSize + 1, "a refresh dropped the page the reader opened")
        #expect(model.archive.selection == [oldest])
        model.actArchive(.search("word"))
        await model.reloadArchive()
        #expect(model.archive.rows.count == LibraryModel.pageSize, "a new search starts from one page")
        #expect(model.archive.hasMore)
    }

    // MARK: - One card per reading

    /// **The archive folds repeats the way the drawer does**, by `ReadingHistory`'s rule: the same
    /// word in the same sentence on the same day is one card, and the card answers for every
    /// lookup behind it. It drew a card per lookup — sixty-four identical cards on a real ledger.
    @Test func aReadingLookedUpThreeTimesIsOneCardThatAnswersForAllThree() async throws {
        let (path, clean) = Wiring.scratch("archive-fold"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repeats = try (0..<3).map { try record(ledger, "fine", at: now.addingTimeInterval(Double(-$0))) }
        let other = try record(ledger, "delirium", at: now.addingTimeInterval(-10))
        let model = LibraryModel(store: Wiring.store(path), clock: { now }, defaults: TemporaryDefaults.suite())
        await model.reloadArchive()
        #expect(model.archive.rows.map(\.lemma) == ["fine", "delirium"])
        let card = try #require(model.archive.rows.first)
        #expect(card.times == 3)
        #expect(Set(card.lookupIDs) == Set(repeats))
        // The count is still of readings: four were made, on two cards.
        #expect(model.archive.total == 4)
        #expect(!model.archive.hasMore)
        // One card selected is three readings, and discarding the selection takes all three.
        model.actArchive(.select([card.id]))
        #expect(model.archive.selection.count == 1)
        #expect(model.archive.selectedLookupIDs == repeats.sorted())
        model.actArchive(.discard(model.archive.selectedLookupIDs))
        try await Wiring.settle { model.archive.rows.map(\.id) == [other] }
        for id in repeats { #expect(try ledger.disposition(ofLookup: id) == .discarded) }
        #expect(model.archive.undoCount == 3)
    }

    /// The fold is the drawer's rule and not a second one: a different sentence, or another day,
    /// is another card.
    @Test func differentSentencesAndDifferentDaysStayApart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        func entry(_ id: Int, _ sentence: String, at: Date) -> ReadingEntry {
            ReadingEntry(id: id, lemma: "fine", surface: "fine", sentence: sentence, sentenceRange: nil,
                         place: ReadingPlace(bundleID: nil, name: nil), at: at, result: .found, quality: nil)
        }
        let cards = LibraryModel.cards(from: [
            entry(4, "A fine day.", at: noon),
            entry(3, "A fine day.", at: noon.addingTimeInterval(-60)),
            entry(2, "He paid the fine.", at: noon.addingTimeInterval(-120)),
            entry(1, "A fine day.", at: noon.addingTimeInterval(-86_400)),
        ], now: noon, calendar: calendar)
        #expect(cards.map(\.id) == [4, 2, 1])
        #expect(cards.map(\.times) == [2, 1, 1])
    }

    /// A lookup the reader was sent to is shown by selecting **the card it is drawn on**, which is
    /// fronted by the newest of the lookups it stands for.
    @Test func aFocusedLookupInsideAFoldedCardSelectsThatCard() async throws {
        let (path, clean) = Wiring.scratch("archive-fold-focus"); defer { clean() }
        let ledger = try Ledger(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newest = try record(ledger, "fine", at: now)
        let older = try record(ledger, "fine", at: now.addingTimeInterval(-5))
        let model = LibraryModel(store: Wiring.store(path), clock: { now }, defaults: TemporaryDefaults.suite())
        model.show(.history, lookup: older)
        try await Wiring.settle { model.archive.rows.count == 1 && model.archive.focused != nil }
        #expect(model.archive.focused == newest)
        #expect(model.archive.selection == [newest])
        #expect(model.archive.inspector?.lookupIDs.contains(older) == true)
    }

    // MARK: - The inspector

    /// **Open or closed is the reader's choice, and it is remembered.** It was derived from the
    /// selection, so it could not be closed over a selected card or opened over none.
    @Test func theInspectorStaysAsTheReaderLeftIt() {
        let defaults = TemporaryDefaults.suite()
        let model = LibraryModel(store: { nil }, defaults: defaults)
        #expect(model.inspectorShown, "open the first time, so a selection still shows its details")
        model.setInspector(false)
        #expect(!model.inspectorShown)
        #expect(!LibraryModel(store: { nil }, defaults: defaults).inspectorShown)
        model.setInspector(true)
        #expect(LibraryModel(store: { nil }, defaults: defaults).inspectorShown)
    }

    /// Selecting a card and letting go of it leave the inspector alone.
    @Test func selectingACardDoesNotOpenOrCloseTheInspector() async throws {
        let (path, clean) = Wiring.scratch("archive-inspector"); defer { clean() }
        let ledger = try Ledger(path: path)
        let id = try record(ledger, "fine")
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite())
        model.setInspector(false)
        await model.reloadArchive()
        model.actArchive(.select([id]))
        #expect(model.archive.inspector?.id == id, "positive control: one card is selected")
        #expect(!model.inspectorShown)
        model.setInspector(true)
        model.actArchive(.select([]))
        #expect(model.inspectorShown)
    }

    // MARK: - The way to what needs confirming

    /// **Review offers the way to unconfirmed meanings only when there are some**, so the model
    /// has to know how many. The control was there on every visit, over nothing.
    @Test func theModelCountsTheMeaningsWaitingToBeConfirmed() async throws {
        let (path, clean) = Wiring.scratch("archive-unconfirmed"); defer { clean() }
        let ledger = try Ledger(path: path)
        let model = LibraryModel(store: Wiring.store(path), defaults: TemporaryDefaults.suite(),
                                 primary: { PrimaryDictionary(chosen: "noad") })
        await model.refreshReviewCount()
        #expect(model.reviewUnconfirmed == 0)
        let lookup = try record(ledger, "fine")
        // Saved as the model proposed it: not yet the reader's.
        _ = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: .now)
        await model.refreshReviewCount()
        #expect(model.reviewUnconfirmed == 1)
        // And the way there is the Saved pane, narrowed to what needs attention.
        model.findUnconfirmed()
        #expect(model.pane == .saved)
        try await Wiring.settle { model.presentation.filter == .needsAttention && model.presentation.rows.count == 1 }
    }

    /// A setting the test changes after the model has captured how to read it.
    @MainActor private final class Setting<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private actor ArchiveReadGate {
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() {
            opened = true
            for continuation in continuations { continuation.resume() }
            continuations.removeAll()
        }
    }

}
