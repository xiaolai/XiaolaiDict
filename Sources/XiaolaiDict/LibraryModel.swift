import DictionaryModel
import Foundation
import Observation
import SwiftUI
import XiaolaiDictCore
import XiaolaiDictUI

/// **The Library window's model.** WI-005's wire.
///
/// Its whole job is to turn the reader's filter into a `LibraryQuery` and the ledger's rows into
/// something drawable, and then to apply their bulk actions to exactly the set they selected.
///
/// **Every filter goes into the query, never into a `filter` on the result.** A page narrowed in
/// Swift after the ledger's `LIMIT` is a page short of what was asked for, and a reader paging
/// through would watch rows disappear between pages with nothing to explain it.
@MainActor
@Observable
final class LibraryModel {
    private(set) var layout: LibraryLayout
    /// Whether the inspector column is open. **The reader's choice, kept in the defaults suite the
    /// layout is kept in** — the scene has restoration turned off, so scene storage would forget it.
    /// Open the first time, so the details a selection used to bring with it are still there.
    private(set) var inspectorShown: Bool
    private var archiveSelections: [LibraryPane: Set<Int>] = [:]
    private var extendingArchive: Int?
    /// How many pages of the archive the reader has opened. **A refresh re-reads all of them**:
    /// every ledger change reloads the pane, and reloading one page dropped the older readings they
    /// had paged to, and the selection with them. One again whenever the pane or the search changes.
    private var archivePages = 1
    private(set) var pane: LibraryPane = .history
    private(set) var archive = ArchivePresentation()
    private let defaults: UserDefaults
    private var archiveRows: [ReadingEntry] = []
    private var archiveSearch = ""
    private var archiveGeneration = 0
    private var archivePublishedGeneration = 0
    private var archiveUndo: DispositionResult?
    private var focusedLookup: Int?
    private var imported = false
    private(set) var reviewProblem: String?
    private(set) var reviewCount = 0
    private(set) var reviewHeldBack = 0
    /// How many saved meanings are waiting for the reader to choose or confirm them. What decides
    /// whether Review offers the way to them at all.
    private(set) var reviewUnconfirmed = 0
    private(set) var reviewDictionary: String?
    private let primaryName: @MainActor (String?) -> String?
    private let primary: @MainActor () -> PrimaryDictionary
    /// The scripts the reader studies, or nil for every script. **The setting the drawer reads**:
    /// History is the reading history too, and the two must agree about what was read.
    private let studying: @MainActor () -> Set<ProbeScript>?
    private(set) var presentation = LibraryPresentation(rows: [], total: 0)
    private var search = ""
    private var filter = LibraryPresentation.Filter.all
    /// One of the reader's own tags, or nil for all. Part of the query, never a filter on the page.
    private var tag: String?
    private var selection: Set<UUID> = []
    /// How many pages the reader has asked for. **Grown rather than offset**, so a card enrolled
    /// while they are reading does not shift a boundary underneath them.
    private var pages = 1
    private var savedPageTask: Task<Void, Never>?
    private var exported: String?
    /// The last bulk pause or archive, while it can still be put back. **One level**: an undo that
    /// outlives the reader's memory of what it reverses is a worse control than none.
    private var undoable: Undo?
    /// Why the last change did not land, until the next one is attempted. **Not the reload's
    /// `problem`**, which is about reading; this one is about writing, and both reach the same
    /// field on the presentation.
    private var problem: String?
    private var retrySaved: (@MainActor () -> Void)?
    /// Which action is the latest. **Not the reload's generation**: a reload is about what is
    /// read and this is about what was written, and an action can outlive several reloads.
    private var actions = 0
    /// Which reload is the current one. **Every reload suspends several times** — opening the
    /// store, the page, the count, the answers, the timeline — and the reader can type, filter or
    /// select during any of them. An older reload resuming last wrote its rows over newer ones,
    /// pruned a selection made since, and could hand A's timeline to B's inspector. Bumped on
    /// entry; a reload whose number is no longer current commits nothing.
    ///
    /// **Defensive, and said so.** The race was raised by an audit and could not be reproduced
    /// through this model's API — separately created `Task`s on the main actor happen to resume
    /// in order here, and `thelastRequestIsTheOneOnScreen` passes with this guard removed. That
    /// ordering is not a guarantee Swift makes, so the assumption is made explicit rather than
    /// relied on; it is not a fix for a demonstrated defect.
    private var generation = 0

    /// What a bulk action changed, and enough to change it back.
    ///
    /// **The prior state of each row**, not the inverse of the action: resuming everything after a
    /// bulk pause would be a second change wearing a reversal's label, and promoting a candidate
    /// to active by way of un-archiving it would enrol the reader in something.
    private enum Undo {
        case pause([UUID: Bool])
        case archive([UUID: StudyEnrollment])

        var presentable: LibraryPresentation.Undoable {
            switch self {
            case .pause(let states): .pause(states.count)
            case .archive(let dispositions): .archive(dispositions.count)
            }
        }
    }
    /// The word the reader asked to study from a suggestion. **Read and cleared** by whoever acts
    /// on it, so a redraw cannot take the same suggestion up twice.
    private(set) var suggestionTaken: String?

    func takeSuggestion() -> String? {
        defer { suggestionTaken = nil }
        return suggestionTaken
    }

    /// Looks a word up, as the reader pressing **Study** on a suggestion asks for.
    ///
    /// **Nothing read this before.** `suggestionTaken` was set and `takeSuggestion` was called by
    /// the tests alone, so the button did nothing at all — a control that refuses its own click,
    /// silently, which is worse than one that is disabled. C06 says a suggestion is *offered*,
    /// never enrolled: this hands the word to the lookup path and the reader decides from the
    /// card, exactly as if they had met it while reading.
    private let reopen: @MainActor (ReadingEntry) -> Void
    private let lookUp: @MainActor (String) -> Void

    /// How many rows one page holds. The library is paged rather than capped: a reader looking for
    /// something from March must be able to reach March.
    static let pageSize = 200
    /// **Five, and no more.** C06: a suggestion list long enough to feel like a backlog is one,
    /// and an unopened suggestion is supposed to cost the reader nothing.
    static let suggestionCount = 5

    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    private let clock: @MainActor () -> Date
    /// Where an export is written. **A parameter, like the clock**, because a test that exercised
    /// the real path wrote into the reader's own Downloads folder and then deleted what it found
    /// there — every `make test` on any Mac, destroying an export they had made.
    private let exportDirectory: @MainActor () -> URL

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         clock: @escaping @MainActor () -> Date = { .now },
         exportDirectory: @escaping @MainActor () -> URL = {
             FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
         },
         lookUp: @escaping @MainActor (String) -> Void = { _ in },
         reopen: @escaping @MainActor (ReadingEntry) -> Void = { _ in },
         defaults: UserDefaults = .standard,
         primary: @escaping @MainActor () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
         primaryName: @escaping @MainActor (String?) -> String? = { _ in nil },
         studying: @escaping @MainActor () -> Set<ProbeScript>? = { nil }) {
        self.reopen = reopen
        self.defaults = defaults
        layout = defaults.string(forKey: "libraryLayout").flatMap(LibraryLayout.init(rawValue:)) ?? .grid
        inspectorShown = defaults.object(forKey: "libraryInspector") as? Bool ?? true
        self.primary = primary
        self.primaryName = primaryName
        self.studying = studying
        pane = defaults.string(forKey: "libraryPane").flatMap(LibraryPane.init(rawValue:)) ?? .history
        self.store = store
        self.clock = clock
        self.exportDirectory = exportDirectory
        self.lookUp = lookUp
    }

    func setLayout(_ layout: LibraryLayout) {
        self.layout = layout
        defaults.set(layout.rawValue, forKey: "libraryLayout")
    }

    func setInspector(_ shown: Bool) {
        inspectorShown = shown
        defaults.set(shown, forKey: "libraryInspector")
    }

    func show(_ pane: LibraryPane, lookup: Int? = nil) {
        archiveGeneration += 1
        archivePublishedGeneration = archiveGeneration
        // **Another pane's rows go at once, not when the new ones arrive.** The controls change with
        // the pane, so Discarded's Restore and permanent delete stood over History's kept readings —
        // and their selection — for as long as the read took.
        if pane != self.pane {
            archiveRows = []
            archivePages = 1
            archive = ArchivePresentation(search: archiveSearch, undoCount: archiveUndo?.affected ?? 0)
        }
        self.pane = pane
        defaults.set(pane.rawValue, forKey: "libraryPane")
        focusedLookup = lookup
        Task { await refreshPane() }
    }
    /// Goes to the saved meanings waiting to be chosen or confirmed: the Saved pane, narrowed to
    /// Needs Attention. One spelling, for the toolbar button and the empty state's.
    func findUnconfirmed() {
        show(.saved)
        act(.filter(.needsAttention))
    }

    func refreshPane() async {
        if pane == .saved { await reload() }
        else if pane != .review { await reloadArchive() }
        await refreshReviewCount()
    }
    func refreshReviewCount() async {
        guard let opening = store() else { return }
        do {
            let ledger = try await opening.value
            let scope = primary().chosen; let now = clock()
            let counts = try await ledger.queueCounts(at: now, dictionary: scope,
                newAllowance: ReviewModel.newCardsPerDay, dayStart: StudyDay.standard.start(containing: now))
            let unconfirmed = try await ledger.attentionCount(dictionary: scope)
            reviewProblem = nil
            reviewCount = counts.due; reviewHeldBack = counts.heldBack; reviewDictionary = primaryName(scope)
            reviewUnconfirmed = unconfirmed
        } catch { reviewProblem = error.localizedDescription; publishArchiveProblem(error.localizedDescription) }
    }
    func importLegacy() async {
        guard !imported, LookupKeepPolicyStore(defaults: defaults).load() == .automatic, let opening = store() else { return }
        imported = true
        defer { imported = false }
        do {
            let ledger = try await opening.value
            while !Task.isCancelled, LookupKeepPolicyStore(defaults: defaults).load() == .automatic {
                let count = try await ledger.backfillKeptDrafts(limit: Self.pageSize)
                if count == 0 { break }
                LedgerChanges.shared.committed()
                await Task.yield()
            }
        } catch { publishArchiveProblem(error.localizedDescription) }
    }
    private func archiveQuery(after: ReadingArchiveCursor? = nil, pages: Int = 1) -> ReadingArchiveQuery {
        ReadingArchiveQuery(text: archiveSearch, disposition: pane == .discarded ? .discarded : .kept,
            scripts: studying(), after: after, limit: pages * Self.pageSize)
    }
    func reloadArchive(extending: Bool = false) async {
        guard let opening = store() else { return }
        if extending, extendingArchive != nil { return }
        archiveGeneration += 1; let mine = archiveGeneration
        let requestedPane = pane
        let requestedSearch = archiveSearch
        let requestedFocus = focusedLookup
        if extending { extendingArchive = mine }
        defer { if extendingArchive == mine { extendingArchive = nil } }
        let query = extending
            ? archiveQuery(after: archiveRows.last.map { ReadingArchiveCursor(at: $0.at, id: $0.id) })
            : archiveQuery(pages: archivePages)
        do {
            let ledger = try await opening.value
            let rows = try await ledger.readingArchive(query)
            var focus: ReadingEntry?
            // **Asked through the pane's own query**, so a focused reading obeys every filter the list
            // does — disposition and studied scripts alike, narrowed to the focus by id: it comes
            // back exactly when the focus passes them.
            if let id = requestedFocus, requestedSearch.isEmpty, let row = try await ledger.reading(ofLookup: id) {
                var probe = query
                probe.after = nil
                probe.only = id
                probe.limit = 1
                if try await ledger.readingArchive(probe).first?.id == id { focus = row }
            }
            let total = try await ledger.readingArchiveCount(query)
            guard mine >= archivePublishedGeneration, requestedPane == pane, requestedSearch == archiveSearch else { return }
            archivePublishedGeneration = mine
            if extending {
                let existing = Set(archiveRows.map(\.id))
                archiveRows += rows.filter { !existing.contains($0.id) }
                archivePages += 1
            } else { archiveRows = rows }
            var shown = Self.cards(from: archiveRows, now: clock())
            // A focus beyond the pages read is put first, as a card of its own, where the reader
            // sent there will see it; one already on a page is on the card that stands for it.
            if let focus, !shown.contains(where: { $0.lookupIDs.contains(focus.id) }) { shown.insert(focus, at: 0) }
            let visible = Set(shown.map(\.id))
            var selected = (archiveSelections[pane] ?? []).intersection(visible)
            // **The card the focused lookup is drawn on**, which need not be the lookup's own: a
            // reading made three times is one card, fronted by one of the three.
            let focusedCard = requestedFocus.flatMap { id in shown.first { $0.lookupIDs.contains(id) }?.id }
            if let focusedCard { selected = [focusedCard] }
            archiveSelections[pane] = selected
            archive = ArchivePresentation(rows: shown, total: total, search: requestedSearch,
                hasMore: archiveRows.count < total, undoCount: archiveUndo?.affected ?? 0,
                focused: focusedCard, selection: selected)
        } catch {
            guard mine >= archivePublishedGeneration, requestedPane == pane, requestedSearch == archiveSearch else { return }
            publishArchiveProblem(error.localizedDescription)
        }
    }
    /// One card per reading rather than per lookup, newest first — **the drawer's rule, not a second
    /// one**: `ReadingHistory.days` groups by calendar day and folds the lookups a card would draw
    /// identically, and this is its days laid end to end. The archive drew a card per lookup, which
    /// on a real ledger was sixty-four identical cards for one word in one sentence.
    ///
    /// `archiveRows` stays one per lookup: the paging cursor and "is there more" are both counted
    /// in lookups, which is what the ledger pages by.
    static func cards(from lookups: [ReadingEntry], now: Date, calendar: Calendar = .current) -> [ReadingEntry] {
        ReadingHistory.days(from: lookups, now: now, calendar: calendar).flatMap(\.entries)
    }

    private func publishArchiveProblem(_ problem: String) {
        archive = ArchivePresentation(rows: archive.rows, total: archive.total, search: archiveSearch,
            hasMore: archive.hasMore, problem: problem, undoCount: archiveUndo?.affected ?? 0,
            focused: archive.focused, selection: archiveSelections[pane] ?? [])
    }
    private var failedArchiveAction: ArchiveAction?
    func actArchive(_ action: ArchiveAction) {
        switch action {
        case .retry: if let failedArchiveAction { actArchive(failedArchiveAction) } else { Task { await reloadArchive() } }
        case .search(let text): archiveGeneration += 1; archivePublishedGeneration = archiveGeneration; focusedLookup = nil; archiveSearch = text; archivePages = 1; Task { await reloadArchive() }
        case .select(let ids):
            let selected = ids.intersection(Set(archive.rows.map(\.id)))
            archiveSelections[pane] = selected
            archive = ArchivePresentation(rows: archive.rows, total: archive.total, search: archive.search,
                hasMore: archive.hasMore, problem: archive.problem, undoCount: archive.undoCount,
                focused: archive.focused, selection: selected)
        case .more: Task { await reloadArchive(extending: true) }
        case .clarify(let id): if let row = archive.rows.first(where: { $0.id == id }) { reopen(row) }
        default: runArchive(action)
        }
    }

    /// A write, then what it changed: the commit is announced and the pane and the review count are
    /// read again. A failure is kept for Retry and said on the pane.
    private func runArchive(_ action: ArchiveAction) {
        guard let opening = store() else { return }
        Task {
            do {
                guard try await mutateArchive(action, in: try await opening.value) else { return }
                failedArchiveAction = nil
                LedgerChanges.shared.committed()
                await reloadArchive()
                await refreshReviewCount()
            } catch {
                failedArchiveAction = action
                publishArchiveProblem(error.localizedDescription)
            }
        }
    }

    /// The ledger write an archive action asks for. **False where nothing was written** — a reading
    /// with no evidence to keep, which is handed back to the reader to clarify instead.
    private func mutateArchive(_ action: ArchiveAction, in ledger: LedgerStore) async throws -> Bool {
        switch action {
        case .confirm(let id): try await ledger.confirm(noteID: id, at: clock())
        case .discard(let ids):
            let receipt = try await ledger.changeDisposition(.discarded, lookups: ids, operation: UUID())
            if receipt.affected > 0 { archiveUndo = receipt }
        case .restore(let ids): _ = try await ledger.changeDisposition(.kept, lookups: ids, operation: UUID())
        case .undo:
            guard let receipt = archiveUndo else { break }
            let result = try await ledger.undoDisposition(operation: receipt.operation)
            archiveUndo = nil
            if result.skipped > 0 { throw LedgerError.corruptRow("undo skipped newer dispositions: \(result.skipped)") }
        case .keep(let id):
            guard try await ledger.keepHistory(id) != nil else {
                if let row = archive.rows.first(where: { $0.id == id }) { reopen(row) }
                return false
            }
        case .erase(let ids):
            let report = try await ledger.eraseReadings(ids)
            if !report.isComplete { throw LedgerError.corruptRow("incomplete erasure: \(report.backupsLeft)") }
        case .retry, .search, .select, .more, .clarify: break
        }
        return true
    }

    func act(_ action: LibraryAction) {
        problem = nil
        switch action {
        case .retry:
            if let retrySaved { retrySaved() } else { Task { await reload() } }
            return
        // Any change to what is being looked at starts the paging over: a page count carried
        // across a new search is a "show more" button that reveals rows from the old one.
        case .search(let text): search = text; pages = 1
        // **Suggested is the one filter that clears the selection**, because it is the one that
        // does not narrow the list — it replaces it. Every other narrowing is handled by pruning
        // the selection to the rows that survive (ADR-0035), which keeps the footer's count
        // honest while letting the reader keep a selection through a search. Under Suggested the
        // library query still matches every row, so pruning keeps them all selected while none is
        // on screen: the footer counted, and Remove was armed over, rows nobody could see.
        case .filter(let value):
            if value == .suggested || filter == .suggested { selection = [] }
            filter = value
            pages = 1
        case .filterTag(let name): tag = name; pages = 1
        // **The one action that reads nothing.** Selecting writes nothing, so the rows, the
        // count, the answers, the retention scan and the tag vocabulary are all still true;
        // only the open row's history has to be fetched.
        case .select(let ids):
            selection = ids
            Task { await reselect() }
            return
        // **One page, after the last row on screen** — never the whole prefix again. Growing
        // the limit and re-reading from the top meant the fifth Show more read five pages to
        // add one, and every page already drawn was decoded again to produce the same rows.
        // `pages` still governs what a *reload* re-reads, because a reload must show writes
        // that landed anywhere in what is on screen.
        case .showMore:
            guard savedPageTask == nil else { return }
            pages += 1
            savedPageTask = Task {
                await extend()
                savedPageTask = nil
            }
            return
        // **One transaction, like every other bulk action.** A loop of separately committed
        // writes leaves an arbitrary subset changed when one fails part-way, and the reader has
        // no way to see which — the same all-or-nothing the pause and archive helpers already
        // give, which these two were the only bulk actions not to have.
        case .confirm:
            let ids = Array(selection)
            let when = clock()
            return apply { try await $0.confirm(noteIDs: ids, at: when) }
        case .tag(let text):
            let ids = Array(selection), trimmed = text
            return apply(keepingSelection: true) { try await $0.tag(noteIDs: ids, trimmed) }
        case .untag(let id, let tag):
            return apply(keepingSelection: true) { try await $0.untag(noteID: id, tag) }
        case .unignore(let lemma, let language):
            return apply { try await $0.unignoreSuggestion(lemma: lemma, language: language) }
        case .setAnswer(let id, let text):
            // **The row the inspector was showing**, which the view names — not `selection.first`,
            // which has already moved on by the time a reload is in flight.
            let when = clock()
            return apply(keepingSelection: true) {
                try await $0.setReaderAnswer(text, of: id, at: when)
            }
        case .export:
            Task { await export() }
            return
        case .study(let lemma):
            // **Taken up by hand, not enrolled from here.** Enrolling needs the sense the reader
            // met, which comes from a lookup and not from a list — so this hands the word to the
            // app and they decide, which is what C06 says a suggestion is.
            suggestionTaken = lemma
            lookUp(lemma)
            return
        case .ignore(let lemma, let language):
            let when = clock()
            return apply { try await $0.ignoreSuggestion(lemma: lemma, language: language, at: when) }
        case .pause:
            return applyReversible(Array(selection)) { store, ids in
                // **One hop, so nothing can write between the read and the change.** Two awaits
                // let another operation move the same rows in between, and the undo recorded a
                // state that had already gone.
                .pause(try await store.pauseAndRemember(true, ofNotes: ids))
            }
        case .resume:
            let ids = Array(selection)
            return apply { try await $0.setPaused(false, ofNotes: ids) }
        case .archive:
            return applyReversible(Array(selection)) { store, ids in
                .archive(try await store.setEnrollmentAndRemember(.archived, ofNotes: ids))
            }
        case .unarchive:
            // **`.active`, and deliberately so.** This is the reader saying "put it back in the
            // collection", which an undo is not — see `Undo`.
            let ids = Array(selection)
            return apply { try await $0.setEnrollment(.active, ofNotes: ids) }
        case .undo:
            guard let undo = undoable else { return }
            undoable = nil
            switch undo {
            case .pause(let states):
                return apply { try await $0.restorePauseStates(states) }
            case .archive(let dispositions):
                return apply { try await $0.restoreEnrollments(dispositions) }
            }
        case .removeFromStudy:
            let ids = Array(selection)
            return apply { try await $0.removeFromStudy(ids) }
        case .deleteReading:
            let ids = Array(selection)
            return apply { try await $0.deleteReading(ofNotes: ids) }
        }
        Task { await reload() }
    }

    /// **What one read of the ledger produced**, kept so that changing the selection does not
    /// have to produce it again. Selecting a row changes nothing in the ledger, and re-running
    /// the page query, the count, the answers, the retention scan and the tag vocabulary for it
    /// made clicking through a library as expensive as searching it.
    private struct Reading {
        var rows: [LibraryRow]
        var total: Int
        var answers: [UUID: StudyAnswer]
        var suggested: [Ledger.Suggestion]
        var setAside: [IgnoredLemma]
        var retention: Ledger.RetentionReport
        var vocabulary: [LibraryPresentation.TagUse]
        var at: Date
    }

    /// The last complete read, or nil before the first one.
    private var reading: Reading?

    func reload() async {
        guard let opening = store() else { return }
        generation += 1
        let mine = generation
        do {
            let ledger = try await opening.value
            let query = self.query()
            let rows = try await ledger.library(query)
            let total = try await ledger.libraryCount(query)
            let now = clock()
            // **Pruned here, in the model — not on the way out to the presentation.** Narrowing it
            // only for display left the model holding ids the reader could no longer see, and the
            // bulk actions read the model: selecting two rows and searching until one was visible
            // showed "Remove 1" over a command that removed both. A count and a button that mean
            // different sets is the worst shape a destructive control can have.
            // **Nothing is written before this point.** A reload that has been overtaken must
            // not prune a selection the reader has made since, nor replace newer rows with its
            // own — it simply stops, and the reload that overtook it commits instead.
            guard mine == generation else { return }
            selection.formIntersection(Set(rows.map(\.id)))
            // One query for the page's answers, not one per row: the list is redrawn on every
            // keystroke of the search field, and two hundred round trips through an actor per
            // keystroke is a search field that stutters.
            let answers = try await ledger.answers(of: rows.map(\.id))
            // Only under the suggested filter: a list nobody is looking at is a query nobody
            // should pay for on every keystroke.
            // Search also narrows suggestions, before the visible limit.
            var suggested: [Ledger.Suggestion] = []
            if filter == .suggested {
                let narrowing = search.trimmingCharacters(in: .whitespaces).lowercased()
                let all = try await ledger.suggestions(
                    limit: Self.suggestionCount * 4, language: nil,
                    studying: [])
                suggested = Array(all.lazy
                    .filter { narrowing.isEmpty || $0.lemma.lowercased().contains(narrowing) }
                    .prefix(Self.suggestionCount))
            }
            // Beside the suggestions, and only there: setting a word aside enrols nothing, so
            // this list is the only place the declaration is visible — and the only place it can
            // be taken back.
            let setAside = filter == .suggested ? try await ledger.ignoredSuggestions() : []
            let measured = try await ledger.retention(dictionary: nil)
            let vocabulary = try await ledger.allTags()
                .map { LibraryPresentation.TagUse(tag: $0.tag, count: $0.count) }
            // **A filter cannot outlive the thing it filters by.** Removing the last use of the
            // active tag emptied the vocabulary, which hid the picker — and left `tag` set, so
            // the library stayed empty with no control on screen to clear it.
            if let active = tag, !vocabulary.contains(where: { $0.tag == active }) {
                tag = nil
                await reload()
                return
            }
            // Read again: the reads between the prune and here suspend too.
            guard mine == generation else { return }
            reading = Reading(rows: rows, total: total, answers: answers, suggested: suggested,
                              setAside: setAside, retention: measured, vocabulary: vocabulary,
                              at: now)
            await inspect(ledger, generation: mine)
        } catch {
            // **Said, not swallowed.** An empty list and a list that could not be read are the same
            // screen otherwise, and the reader is owed the difference. Still only for the current
            // reload: an overtaken one's failure is not this screen's.
            guard mine == generation else { return }
            problem = String(describing: error)
            if reading != nil { republish() }
            else {
                presentation = LibraryPresentation(rows: [], total: 0, search: search, filter: filter,
                                                   problem: problem)
            }
        }
    }

    /// Reads the page after the last row on screen and appends it.
    ///
    /// Falls back to a full reload when there is nothing to page from — no reading yet, or a
    /// reading with no rows, in which case there is no cursor and nothing to append to.
    private func extend() async {
        guard let reading, let last = reading.rows.last, let opening = store() else {
            return await reload()
        }
        generation += 1
        let mine = generation
        do {
            let ledger = try await opening.value
            var next = query()
            next.after = last.cursor
            next.limit = Self.pageSize
            let rows = try await ledger.library(next)
            let answers = try await ledger.answers(of: rows.map(\.id))
            guard mine == generation, var grown = self.reading else { return }
            grown.rows += rows
            grown.answers.merge(answers) { _, new in new }
            self.reading = grown
            await inspect(ledger, generation: mine)
        } catch {
            guard mine == generation else { return }
            problem = String(describing: error)
            republish()
        }
    }

    /// **What a selection change costs.** The rows, the count, the answers, the retention scan
    /// and the tag vocabulary are all unchanged by it — selecting a row writes nothing — so this
    /// reads the one open row's history and republishes the last reading around it.
    ///
    /// Falls back to a full reload when there is no reading to republish, which is the first
    /// selection after a failure.
    private func reselect() async {
        guard reading != nil, let opening = store() else { return await reload() }
        generation += 1
        let mine = generation
        do {
            await inspect(try await opening.value, generation: mine)
        } catch {
            guard mine == generation else { return }
            problem = String(describing: error)
            republish()
        }
    }

    /// Reads the open row's history — **one row, or none**, so a history is read for the row the
    /// reader opened and not for two hundred of them — and publishes.
    private func inspect(_ ledger: LedgerStore, generation mine: Int) async {
        guard let reading else { return }
        let open = selection.count == 1 ? selection.first : nil
        var timeline: NoteTimeline?
        var tags: [String] = []
        if let open {
            do {
                timeline = try await ledger.timeline(of: open)
                tags = try await ledger.tags(of: open)
            } catch {
                guard mine == generation else { return }
                problem = String(describing: error)
            }
        }
        guard mine == generation else { return }
        publish(reading, tags: tags, timeline: timeline)
    }

    private func publish(_ reading: Reading, tags: [String], timeline: NoteTimeline?) {
        let rows = reading.rows
        presentation = LibraryPresentation(
            rows: rows.map { Self.row($0, answer: reading.answers[$0.id]?.text ?? "", at: reading.at) },
            total: reading.total, search: search, filter: filter, selection: selection,
            // **Offered only when there is more.** The count is of everything that matched, so
            // a library of exactly one page must not show a button that does nothing.
            hasMore: reading.total > rows.count,
            // Whether any of the selection can be confirmed, so the control is present only
            // when it would do something.
            canConfirm: rows.contains { selection.contains($0.id) && $0.readiness == .needsConfirmation },
            suggestions: reading.suggested.map {
                LibraryPresentation.Suggestion(lemma: $0.lemma, language: $0.language,
                                               days: $0.distinctDays,
                                               sources: $0.distinctSources)
            },
            exported: exported,
            // **What this selection is**, so the control is named for what it will do rather
            // than for what its category is called.
            selectionIsPaused: !selection.isEmpty && rows.allSatisfy {
                !selection.contains($0.id) || $0.card?.isPaused == true
            },
            selectionIsArchived: !selection.isEmpty && rows.allSatisfy {
                !selection.contains($0.id) || $0.note.enrollment == .archived
            },
            undoable: undoable?.presentable,
            setAside: reading.setAside,
            tagVocabulary: reading.vocabulary, tag: tag,
            // **Nil over an empty denominator.** A rate nobody has is not 0%.
            retention: LibraryPresentation.Retention(
                attempts: reading.retention.attempts, successes: reading.retention.successes,
                cards: reading.retention.cards),
            // **One row, or none.** An inspector over several would have to choose which one
            // an edit reaches, and the reader cannot see which it chose.
            inspector: Self.inspector(of: rows, selection: selection, answers: reading.answers,
                                      tags: tags, timeline: timeline),
            problem: problem)
    }

    /// A change that cannot be put back. **Retires the undo**, because a button offering to
    /// reverse something older than the reader's last action is one they will press by mistake.
    ///
    /// `keepingSelection` is for changes the reader makes *to* the open row rather than to a set
    /// of rows: clearing after one would close the inspector they are working in, which reads as
    /// the edit having thrown them out.
    private func apply(keepingSelection: Bool = false,
                       _ change: @escaping @Sendable (LedgerStore) async throws -> Void) {
        let priorUndo = undoable
        undoable = nil
        actions += 1
        let mine = actions
        guard let opening = store() else { return }
        Task { [self] in
            do {
                try await change(try await opening.value)
                LedgerChanges.shared.committed()
                guard mine == actions else { return }
                retrySaved = nil
                if !keepingSelection { selection = [] }
                await reload()
            } catch {
                guard mine == actions else { return }
                undoable = priorUndo
                problem = error.localizedDescription
                retrySaved = { [weak self] in self?.apply(keepingSelection: keepingSelection, change) }
                republish()
            }
        }
    }

    /// A bulk action that records what it changed, so it can be changed back.
    ///
    /// **Nothing is remembered if the write did not happen.** An undo offered over a failed action
    /// would put rows back to a state they never left.
    private func applyReversible(
        _ ids: [UUID],
        _ change: @escaping @Sendable (LedgerStore, [UUID]) async throws -> Undo
    ) {
        let priorUndo = undoable
        undoable = nil
        guard let opening = store(), !ids.isEmpty else { return }
        actions += 1
        let mine = actions
        Task { [self] in
            do {
                let recorded = try await change(try await opening.value, ids)
                LedgerChanges.shared.committed()
                guard mine == actions else { return }
                undoable = recorded
                retrySaved = nil
                selection = []
                await reload()
            } catch {
                guard mine == actions else { return }
                undoable = priorUndo
                problem = error.localizedDescription
                retrySaved = { [weak self] in self?.applyReversible(ids, change) }
                republish()
            }
        }
    }

    /// Puts `problem` on the presentation the reload just built.
    ///
    /// **A reload overwrites it**, because it constructs a whole new presentation — so a failure
    /// recorded before the reload was drawn over by the reload that followed it.
    private func republish() {
        guard let problem else { return }
        presentation = LibraryPresentation(
            rows: presentation.rows, total: presentation.total, search: presentation.search,
            filter: presentation.filter, selection: presentation.selection, hasMore: presentation.hasMore,
            canConfirm: presentation.canConfirm, suggestions: presentation.suggestions,
            exported: presentation.exported,
            selectionIsPaused: presentation.selectionIsPaused,
            selectionIsArchived: presentation.selectionIsArchived,
            undoable: presentation.undoable, setAside: presentation.setAside,
            tagVocabulary: presentation.tagVocabulary, tag: presentation.tag,
            retention: presentation.retention, inspector: presentation.inspector,
            problem: problem)
    }

    /// Writes the collection out and remembers where it went.
    ///
    /// **The path is shown**, because an export the reader cannot find did not happen for them.
    ///
    /// **Dated, so no export can destroy another.** One fixed filename meant every export silently
    /// replaced the last one — and an atomic write is still a replacement. A reader who exported
    /// on Monday, edited the file, and exported again on Friday lost Monday's work with nothing
    /// said. The name carries the instant it was taken, which is also what a reader looking at two
    /// of them needs to tell them apart.
    private func export() async {
        guard let opening = store(), let ledger = try? await opening.value else { return }
        let directory = exportDirectory()
        do {
            let written = try await ledger.export(dictionary: nil)
            let url = directory.appending(path: "XiaolaiDict-cards-\(Self.stamp(clock())).txt")
            // **Formatted and written off this actor.** Joining a few thousand rows into one
            // string and putting it on disk are both unbounded work, and doing them here stopped
            // the menu bar, the panel and every hot key until the file was closed.
            try await Self.write(written, to: url, in: directory)
            exported = url.path
        } catch {
            exported = error.localizedDescription
        }
        await reload()
    }

    nonisolated private static func write(_ cards: StudyExport,
                                          to url: URL, in directory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try cards.tabSeparated().write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    /// `2026-09-30-051351`: sortable, filename-safe, and second-resolution so two exports in one
    /// sitting are two files. Fixed to a neutral locale and timezone — a filename is not prose,
    /// and one built from the reader's locale would sort differently on their next Mac.
    static func stamp(_ when: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: when)
    }

    private func query() -> LibraryQuery {
        // **Each filter is its own predicate.** They were once all `enrollment = 'active'`, so
        // Paused listed unpaused cards and Due listed cards due next year — and the bulk actions
        // then operated on a set the label had described wrongly.
        LibraryQuery(
            text: search,
            enrollment: filter == .archived ? [.archived] : nil,

            tag: tag,
            state: {
                switch filter {
                case .all, .archived, .suggested: nil
                case .due: .due
                case .paused: .paused
                case .needsAttention: .needsAttention
                case .struggling: .struggling
                }
            }(),
            now: clock(),
            // One page more than is shown, so "show more" can be offered only when there is more.
            limit: pages * Self.pageSize)
    }

    static func row(_ row: LibraryRow, answer: String,
                    at now: Date) -> LibraryPresentation.Row {
        LibraryPresentation.Row(
            id: row.id, word: row.word, accentKey: row.lemma, excerpt: row.excerpt, marks: row.excerptMarks, answer: answer,
            status: status(of: row), due: due(of: row, at: now))
    }

    /// The open row, when exactly one is selected and it is on this page.
    ///
    /// **Built from the same `answers` the rows use**, not a second read: the answer the inspector
    /// edits and the answer the row reveals have to be the same string, and two queries are two
    /// chances for them not to be.
    static func inspector(of rows: [LibraryRow], selection: Set<UUID>,
                          answers: [UUID: StudyAnswer], tags: [String],
                          timeline: NoteTimeline?) -> LibraryPresentation.Inspector? {
        guard selection.count == 1, let id = selection.first,
              let row = rows.first(where: { $0.id == id }) else { return nil }
        let answer = answers[id]
        return LibraryPresentation.Inspector(
            id: id, word: row.word, accentKey: row.lemma, answer: answer?.text ?? "",
            isReaders: answer?.origin == .reader,
            tags: tags,
            readings: (timeline?.readings ?? []).map {
                LibraryPresentation.ReadingMark(id: $0.id, at: $0.at, sentence: $0.sentence,
                                                source: $0.place.name)
            },
            reviews: (timeline?.reviews ?? []).map {
                LibraryPresentation.ReviewMark(id: $0.id, at: $0.reviewedAt, grade: $0.grade,
                                               isPractice: $0.kind == .practice,
                                               isVoided: $0.voidedAt != nil)
            })
    }

    /// Why a card is not being asked, or nil when it simply is.
    static func status(of row: LibraryRow) -> LibraryPresentation.Status? {
        switch row.note.enrollment {
        case .archived: return .archived
        case .ignored: return .ignored
        case .candidate, .active: break
        }
        if row.card?.isPaused == true { return .paused }
        switch row.readiness {
        case .needsConfirmation: return .needsConfirmation
        case .needsRepair: return .needsRepair
        case .ready: return nil
        }
    }

    /// When it comes back. **"Due" for one already overdue**, rather than a negative interval or a
    /// date in the past dressed as a plan.
    static func due(of row: LibraryRow, at now: Date) -> String? {
        guard let card = row.card else { return nil }
        // **Put off beats the schedule.** `hiddenUntil` is what the queue filters on, so a card
        // the reader set aside is not offered today whatever its due date says — and the row
        // drew "Due" or "New" over it, which is the list telling them work is waiting that
        // nothing will hand them.
        if let hidden = card.hiddenUntil, hidden > now {
            return String(localized: "Hidden until \(hidden.formatted(date: .abbreviated, time: .omitted))",
                          comment: "A library row for a card the reader set aside until a date")
        }
        guard let due = card.scheduled.due else { return String(localized: "New",
            comment: "A library row for a card that has never been reviewed") }
        if due <= now { return String(localized: "Due", comment: "A library row for an overdue card") }
        return due.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The Library window's content. A view, not scene-body code — see `ReviewSceneView`.
struct LibrarySceneView: View {
    let model: LibraryModel
    let review: ReviewModel
    var body: some View {
        LearningLibraryView(pane: model.pane, saved: model.presentation, archive: model.archive,
            layout: model.layout, chooseLayout: { model.setLayout($0) },
            inspectorShown: model.inspectorShown, showInspector: { model.setInspector($0) },
            choose: { model.show($0) }, savedAction: { model.act($0) }, archiveAction: { model.actArchive($0) }) {
            LibraryReviewPane(due: model.reviewCount, dictionary: model.reviewDictionary,
                              problem: model.reviewProblem, heldBack: model.reviewHeldBack,
                              unconfirmed: model.reviewUnconfirmed,
                              canUndo: review.canUndo, undo: { review.act(.undo) },
                              findUnconfirmed: { model.findUnconfirmed() }) {
                ReviewSceneView(model: review, findUnconfirmed: { model.findUnconfirmed() })
            }
        }
        .task { await model.refreshPane(); await model.importLegacy() }
        .onChange(of: LedgerChanges.shared.revision) { _, _ in Task { await model.refreshPane() } }
    }
}
