import DictionaryModel
import Foundation
@testable import XiaolaiDictCore
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
