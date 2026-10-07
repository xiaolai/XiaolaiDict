import CaptureModel
import DictionaryModel
import Foundation
import Observation
import ReviewKit
import StudyKit
import StudyPresentation
import SwiftUI
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
    /// How many saved meanings confirming would make askable — **not** every one needing attention,
    /// which counted 22 answerless notes on the measured ledger as meanings to confirm. What decides
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
    /// The read generation that has finished, succeeded or failed — **so a selection can tell a read in
    /// flight**, and leave the publishing to it rather than republish the rows it is replacing.
    private var settledGeneration = 0
    /// Which selection is the latest, **counted apart from the reads** (audit-fix round 2): one counter
    /// for both let a selection made while a search's read was suspended overtake that read, which then
    /// stopped — and the selection republished the old rows under the new search, for good.
    private var selectionGeneration = 0

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
    /// Looks a word up, as the reader pressing **Study** on a suggestion asks for.
    ///
    /// **Nothing read the old hand-off.** A `suggestionTaken` was set and a `takeSuggestion` was
    /// called by the tests alone, so the button did nothing at all — a control that refuses its own
    /// click, silently, which is worse than one that is disabled; the pair outlived the fix as state
    /// only a test read, and went (audit-fix round 1). C06 says a suggestion is *offered*, never
    /// enrolled: this hands the word to the lookup path and the reader decides from the card,
    /// exactly as if they had met it while reading.
    private let reopen: @MainActor (ReadingEntry) -> Void
    private let lookUp: @MainActor (String) -> Void
    /// Starts a Selected sitting in Review over these notes, as listed. **The app's `ReviewModel`**,
    /// which holds the sitting: this model only hands it the reader's choice and shows the pane.
    private let reviewSelected: @MainActor ([UUID], SittingOrder) -> Void

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
         reviewSelected: @escaping @MainActor ([UUID], SittingOrder) -> Void = { _, _ in },
         // **No default.** It was `.standard`, so every test that omitted it read and wrote the
         // runner's own domain — the layout, the pane, and now the cooldown experiment's switch —
         // and one run's pane was the next run's starting state. The app passes its suite.
         defaults: UserDefaults,
         primary: @escaping @MainActor () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
         primaryName: @escaping @MainActor (String?) -> String? = { _ in nil },
         studying: @escaping @MainActor () -> Set<ProbeScript>? = { nil }) {
        self.reopen = reopen
        self.reviewSelected = reviewSelected
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

    /// Whether the next reload opens the first row that needs an answer. Set by `findUnanswered`,
    /// taken by the reload that commits, and dropped by a reload that fails.
    private var opensFirstNeedingAnAnswer = false

    /// **The route to an answer of the reader's own**: Saved, narrowed to Needs Attention, with the
    /// first meaning that needs an answer selected and the inspector open — whose editor is the remedy.
    ///
    /// An answerless note becomes askable only once the reader writes an answer and it is confirmed;
    /// confirming first writes `confirmed_at` and changes nothing else. Narrowing the entry to one of
    /// its senses in place is not offered: whether that is the same note is an ADR-0029 identity
    /// question, the owner's (R1b).
    func findUnanswered() {
        opensFirstNeedingAnAnswer = true
        setInspector(true)
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
            // **Today's allowance as the sitting rations it**: the base and any one-day increase the
            // reader asked for (WI-5), from the same suite — or the badge and the sitting disagree.
            let increase = OneDayIncreaseStore(defaults: defaults).extra(in: .standard, at: now)
            let counts = try await ledger.queueCounts(at: now, dictionary: scope,
                newAllowance: SittingPlanner.allowance(newCardsPerDay: ReviewModel.newCardsPerDay, increaseToday: increase),
                dayStart: StudyDay.standard.start(containing: now))
            let waiting = try await ledger.attentionCounts(dictionary: scope)
            reviewProblem = nil
            reviewCount = counts.due; reviewHeldBack = counts.heldBack; reviewDictionary = primaryName(scope)
            reviewUnconfirmed = waiting.toConfirm
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
                let outcome = try await mutateArchive(action, in: try await opening.value)
                guard outcome != .nothingWritten else { return }
                LedgerChanges.shared.committed()
                await reloadArchive()
                await refreshReviewCount()
                // **Said after the reload, not instead of it** (audit-fix round 1's verification): a
                // permanent delete that could not reach a copy has still deleted the reading, and an
                // error thrown in place of the reload left the deleted row on the pane. Retry erases
                // again, which reaches whatever copies it can then.
                switch outcome {
                case .shortOf(let shortfall):
                    failedArchiveAction = action
                    publishArchiveProblem(String(localized: "Deleted, but not everything was reached.\n\(shortfall)"))
                case .leftAlone(let changed):
                    // **Nothing to retry**: what the undo left had changed after the discard, and a
                    // second undo would leave it again. Said, so the reader knows to look for it.
                    failedArchiveAction = nil
                    publishArchiveProblem(String(
                        localized: "Not everything was put back. Readings changed since they were discarded: \(changed)",
                        comment: "Shown when undoing a discard left the readings that had changed since, as they are"))
                case .nothingWritten, .written:
                    failedArchiveAction = nil
                }
            } catch {
                failedArchiveAction = action
                publishArchiveProblem(error.localizedDescription)
            }
        }
    }

    /// What an archive write did: nothing (a reading with no evidence to keep, handed back to the
    /// reader to clarify instead), all of it, or — for a permanent delete — the rows, short of copies
    /// or a rewrite it could not reach, in the surface's own sentences.
    private enum ArchiveOutcome: Equatable {
        case nothingWritten, written
        case shortOf(String)
        /// An undo that put back what nothing had changed since and left this many readings that a later
        /// change reached first — the ledger declining to reverse that change, not a damaged row.
        case leftAlone(Int)
    }

    /// The ledger write an archive action asks for.
    private func mutateArchive(_ action: ArchiveAction, in ledger: LedgerStore) async throws -> ArchiveOutcome {
        switch action {
        case .confirm(let id):
            // **A confirmation that showed the answer**: History's inspector draws Confirm beside the
            // revealed meaning and nowhere else, so this is the surface the cooldown experiment is
            // about. Off — the default — `cooldownUntil` is nil and the card is untouched.
            let when = clock()
            try await ledger.confirm(noteID: id, at: when,
                                     hidingCardsUntil: cooldownUntil(id, confirmedAt: when, exposure: .answerShown))
        case .discard(let ids):
            let receipt = try await ledger.changeDisposition(.discarded, lookups: ids, operation: UUID())
            if receipt.affected > 0 { archiveUndo = receipt }
        case .restore(let ids): _ = try await ledger.changeDisposition(.kept, lookups: ids, operation: UUID())
        case .undo:
            guard let receipt = archiveUndo else { break }
            let result = try await ledger.undoDisposition(operation: receipt.operation)
            archiveUndo = nil
            // **Committed, so announced and read again like any write** (audit-fix round 3, #2). Thrown as
            // a corrupt row, the restored readings stayed off the pane, nothing was told of the change,
            // and Retry found the receipt already spent.
            if result.skipped > 0 { return .leftAlone(result.skipped) }
        case .keep(let id):
            guard try await ledger.keepHistory(id) != nil else {
                if let row = archive.rows.first(where: { $0.id == id }) { reopen(row) }
                return .nothingWritten
            }
        case .erase(let ids):
            let report = try await ledger.eraseReadings(ids)
            if let shortfall = ErasePresentation.shortfall(of: ErasePresentation.Report(report)) {
                return .shortOf(shortfall)
            }
        case .retry, .search, .select, .more, .clarify: break
        }
        return .written
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
        // library query still matches every row, so pruning against the read kept them all selected
        // while none was on screen: the footer counted, and Remove was armed over, rows nobody could
        // see. The publish now prunes against what the pane lists (`listsRows`), which under
        // Suggested is nothing; this clears it at the switch rather than at the publish.
        case .filter(let value):
            if value == .suggested || filter == .suggested { selection = [] }
            filter = value
            pages = 1
        case .filterTag(let name): tag = name; pages = 1
        // **The one action that reads nothing.** Selecting writes nothing, so the rows, the
        // count, the answers, the retention scan and the tag vocabulary are all still true;
        // only the open row's history has to be fetched.
        //
        // **Only what is listed can be selected** (audit-fix round 3, C1): every action reads
        // `selection`, so an id the reader cannot see in it is a row a destructive control reaches
        // unseen (ADR-0035). What a read publishes later is pruned again when it publishes. The
        // presentation's rows are what the pane lists — none under Suggested — so a click there
        // reaches nothing (closing pass after round 3).
        case .select(let ids):
            selection = ids.intersection(presentation.rows.map(\.id))
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
        //
        // **Only what confirming changes** (ADR-0035: prune in the model). It reached every selected
        // row, so an answerless note had `confirmed_at` written and stayed exactly as unreviewable.
        // Saved shows no answer beside this control, so it never starts the cooldown experiment
        // (`ConfirmationCooldown.Exposure.answerNotShown`).
        case .confirm:
            let ids = Array(confirmable(in: selection))
            let when = clock()
            return apply { try await $0.confirm(noteIDs: ids, at: when) }
        // **The whole selection, as the reader sees it listed** — not only what can be asked: the
        // sitting leaves the rest out by reason and says so at its end. Refused, as the control is
        // disabled, when nothing in it can be asked; then nothing is started and the pane stays.
        case .reviewSelected(let order):
            guard !Self.asked(by: selectedPlan(of: selection)).isEmpty else { return }
            let listed = (reading?.rows ?? []).map(\.id).filter(selection.contains)
            reviewSelected(listed, order)
            show(.review)
            return
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
        /// New meanings introduced in the study day of `at`, under the study dictionary: what today's
        /// allowance has spent, which Review Selected is counted against (WI-8).
        var introducedToday: Int
        /// **The study dictionary those introductions were counted under** (audit-fix round 2), which a
        /// selection is planned for — never the one chosen since, whose allowance this read did not
        /// count. A selection after a switch reads again.
        var dictionary: String?
    }

    /// The last complete read, or nil before the first one.
    private var reading: Reading?

    func reload() async {
        guard let opening = store() else { return }
        generation += 1
        let mine = generation
        let scope = primary().chosen
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
            if opensFirstNeedingAnAnswer {
                opensFirstNeedingAnAnswer = false
                if let first = rows.first(where: { $0.obstacle == .answer }) { selection = [first.id] }
            }
            // Against what the pane will list (`listsRows`), as the publish prunes — so the open row the
            // inspector reads a history for is never one Suggested hides.
            selection.formIntersection(listsRows ? Set(rows.map(\.id)) : [])
            // One query for the page's answers, not one per row: the list is redrawn on every
            // keystroke of the search field, and two hundred round trips through an actor per
            // keystroke is a search field that stutters.
            let answers = try await ledger.answers(of: rows.map(\.id))
            // Only under the suggested filter: a list nobody is looking at is a query nobody
            // should pay for on every keystroke.
            // Search also narrows suggestions, **before** the visible limit: reading twenty and
            // narrowing those hid a match that ranked twenty-first however exactly it was typed
            // (audit-fix round 1). With a search, every candidate is read and narrowed here, by
            // Swift's case folding — SQLite's `lower` and `LIKE` fold ASCII alone, and SQL may not
            // judge what Swift defines.
            var suggested: [Ledger.Suggestion] = []
            if filter == .suggested {
                let narrowing = search.trimmingCharacters(in: .whitespaces).lowercased()
                let all = try await ledger.suggestions(
                    limit: narrowing.isEmpty ? Self.suggestionCount : .max, language: nil,
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
            let introducedToday = try await ledger.introductions(since: StudyDay.standard.start(containing: now),
                                                                 dictionary: scope)
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
                              at: now, introducedToday: introducedToday, dictionary: scope)
            settledGeneration = mine
            await inspect(ledger, generation: mine)
        } catch {
            // **Said, not swallowed.** An empty list and a list that could not be read are the same
            // screen otherwise, and the reader is owed the difference. Still only for the current
            // reload: an overtaken one's failure is not this screen's.
            guard mine == generation else { return }
            settledGeneration = mine
            opensFirstNeedingAnAnswer = false
            problem = String(describing: error)
            if reading != nil { republish() }
            else {
                // Nothing is listed, so nothing may stay selected (C1).
                selection = []
                // **The export's own outcome too**, or a failed export followed by a failed read
                // published nothing about the export at all (audit-fix round 1).
                presentation = LibraryPresentation(rows: [], total: 0, search: search, filter: filter,
                                                   exported: exported, problem: problem)
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
            guard mine == generation else { return }
            settledGeneration = mine
            guard var grown = self.reading else { return }
            grown.rows += rows
            grown.answers.merge(answers) { _, new in new }
            self.reading = grown
            await inspect(ledger, generation: mine)
        } catch {
            guard mine == generation else { return }
            settledGeneration = mine
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
    ///
    /// **And a read already in flight is left to publish** (audit-fix round 2): it reads the selection
    /// when it lands, and this would draw the rows it is about to replace. A study dictionary switched
    /// since the last read reads again, because the allowance a selection is planned against is that
    /// dictionary's own.
    private func reselect() async {
        guard let reading, reading.dictionary == primary().chosen, let opening = store() else {
            return await reload()
        }
        guard settledGeneration == generation else { return }
        let mine = generation
        selectionGeneration += 1
        let pick = selectionGeneration
        do {
            await inspect(try await opening.value, generation: mine)
        } catch {
            guard mine == generation, pick == selectionGeneration else { return }
            problem = String(describing: error)
            republish()
        }
    }

    /// Reads the open row's history — **one row, or none**, so a history is read for the row the
    /// reader opened and not for two hundred of them — and publishes.
    /// **Published only while both are current**: the read it belongs to, and the selection it read the
    /// history of. A newer selection publishes its own; a newer read inspects again when it lands.
    private func inspect(_ ledger: LedgerStore, generation mine: Int) async {
        guard let reading else { return }
        let pick = selectionGeneration
        let current = { mine == self.generation && pick == self.selectionGeneration }
        let open = selection.count == 1 ? selection.first : nil
        var timeline: NoteTimeline?
        var tags: [String] = []
        if let open {
            do {
                timeline = try await ledger.timeline(of: open)
                tags = try await ledger.tags(of: open)
            } catch {
                guard current() else { return }
                problem = String(describing: error)
            }
        }
        guard current() else { return }
        publish(reading, tags: tags, timeline: timeline)
    }

    /// **Whether this pane lists the library's rows at all — the one rule for what a selection may hold.**
    /// Suggested draws suggestions in the list's place, and its query still matches every row; so it lists
    /// none, and nothing in it can be selected or reached (closing pass after round 3, C1). The publish
    /// pruned against the rows the read *returned*: Alpha and Beta, clicked on the list still drawn while
    /// the switch to Suggested was being read, were published selected under a pane that showed neither,
    /// and Remove from Study, Discard and the deletions reached them. Read at the publish, from the same
    /// `filter` the presentation carries, so the rows it lists and the filter it draws by cannot disagree.
    private var listsRows: Bool { filter != .suggested }

    private func publish(_ reading: Reading, tags: [String], timeline: NoteTimeline?) {
        let rows = listsRows ? reading.rows : []
        // **Pruned to what this publish lists, at the moment it lists it** (audit-fix round 3, C1). The
        // read prunes when its rows arrive and then suspends four more times; a row clicked in that
        // window, still drawn from the last read, stayed selected after this one published without it
        // — and Remove from Study, which reads `selection`, deleted a note nobody could see. Here
        // nothing suspends between the prune and the presentation the actions are read against, and
        // `rows` is what the pane lists, which `.select` then admits from (`presentation.rows`).
        selection.formIntersection(rows.map(\.id))
        let plan = planner(for: reading)
        let selected = plan(rows.filter { selection.contains($0.id) })
        presentation = LibraryPresentation(
            rows: rows.map {
                Self.row($0, answer: reading.answers[$0.id]?.text ?? "", at: reading.at, review: Self.review(in: plan([$0])))
            },
            total: reading.total, search: search, filter: filter, selection: selection,
            // **Offered only when there is more.** The count is of everything that matched, so
            // a library of exactly one page must not show a button that does nothing — and a pane
            // that lists no rows has no more of them to show.
            hasMore: listsRows && reading.total > rows.count,
            // **What of the selection confirming would change**, so the control is present only when
            // it would do something and counts exactly what it reaches.
            confirmable: confirmable(in: selection),
            // **What of the selection a Selected sitting could ask now**, so Review Selected counts it
            // and is disabled, with its reason, when it is empty — the sitting's planner, allowance and
            // all, so the control is never offered over a sitting that would ask nothing.
            reviewable: Self.asked(by: selected), reviewHeldBack: selected.heldBack,
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
            confirmable: presentation.confirmable, reviewable: presentation.reviewable,
            reviewHeldBack: presentation.reviewHeldBack, suggestions: presentation.suggestions,
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
        guard let opening = store() else { return }
        let directory = exportDirectory()
        do {
            // **Inside the `do`**: a `try?` here dropped the opening's error, and the button did
            // nothing with no reason given (audit-fix round 1).
            let ledger = try await opening.value
            let written = try await ledger.export(dictionary: nil)
            // **Formatted and written off this actor.** Joining a few thousand rows into one
            // string and putting it on disk are both unbounded work, and doing them here stopped
            // the menu bar, the panel and every hot key until the file was closed.
            exported = try await Self.write(written, labels: Self.exportLabels,
                                            named: "XiaolaiDict-cards-\(Self.stamp(clock()))",
                                            in: directory).path
        } catch {
            exported = error.localizedDescription
        }
        await reload()
    }

    /// Writes the export to a name nothing holds, and answers where. **Never over a file**: the name
    /// carries the instant to the second, so two exports inside one second shared it and the second
    /// replaced the first (audit-fix round 1). Each attempt is created exclusively — the system
    /// refuses a name that exists, so even a file put there between two attempts is never replaced —
    /// and a taken name moves on to `-2`, `-3`.
    nonisolated private static func write(_ cards: StudyExport, labels: StudyExport.Labels, named stem: String,
                                          in directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data(cards.tabSeparated(labels: labels).utf8)
            for attempt in 1...Self.exportAttempts {
                let url = directory.appending(path: attempt == 1 ? "\(stem).txt" : "\(stem)-\(attempt).txt")
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    return url
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }.value
    }

    /// **What an exported row says where something could not travel, in the reader's language** (audit-fix
    /// round 3, #8). Core writes no display text, so the words are supplied from here, through the catalog.
    static var exportLabels: StudyExport.Labels {
        StudyExport.Labels(
            incomplete: String(localized: "(no meaning of your own yet — add one in XiaolaiDict)",
                               comment: "Written into an exported card whose meaning is still the dictionary's, which cannot be exported"),
            withoutAWord: String(localized: "(word not kept — its reading was deleted)",
                                 comment: "Written into an exported card in place of its word, once the reading the word came from was deleted"))
    }

    /// How many names one export tries before it gives up: a second's worth of exports, and more.
    nonisolated static let exportAttempts = 100

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

    static func row(_ row: LibraryRow, answer: String, at now: Date,
                    review: LibraryPresentation.Row.Review) -> LibraryPresentation.Row {
        LibraryPresentation.Row(
            id: row.id, word: row.word, accentKey: row.lemma, excerpt: row.excerpt, marks: row.excerptMarks, answer: answer,
            status: status(of: row), due: due(of: row, at: now), isConfirmable: row.obstacle == .confirmation,
            review: review)
    }

    /// **The Selected sitting `listed` would be, planned by the sitting's own planner** from what the
    /// page read (WI-8): askable is enrolled and ready — `thequeueAndReadinessAgree` holds `readiness`
    /// to the ledger's predicate — under the study dictionary; the planner then asks what the sitting
    /// asks of each card at the read's instant: paused, put off, one per meaning, and new meanings
    /// within today's allowance, spent by `introducedToday` and raised by any one-day increase. A
    /// second rule here, blind to introductions, enabled Review Selected over a sitting that then asked
    /// nothing.
    static func selectedPlan(of listed: [LibraryRow], at now: Date, scope: String?, introducedToday: Int,
                             increaseToday: Int) -> SelectedSittingPlan {
        let inScope = { (row: LibraryRow) in scope.map { $0 == row.note.target.dictionary } ?? true }
        let askable = listed.filter { inScope($0) && $0.note.enrollment == .active && $0.readiness == .ready }
        let planner = ReviewModel.planner(.standard, now, increaseToday: increaseToday)
        return planner.selectedSitting(
            from: SelectedCandidates(
                selection: listed.map(\.id),
                queue: SittingCandidates(cards: askable.compactMap(\.card), introducedToday: introducedToday),
                elsewhere: Set(listed.filter { !inScope($0) }.map(\.id))),
            order: .asListed)
    }

    /// What a sitting of one row alone would do with it.
    static func review(in plan: SelectedSittingPlan) -> LibraryPresentation.Row.Review {
        if !plan.batch.isEmpty { return .askable }
        return plan.heldBack > 0 ? .heldBack : .notAskable
    }

    /// The notes a plan asks — what Review Selected counts.
    static func asked(by plan: SelectedSittingPlan?) -> Set<UUID> {
        Set(plan?.batch.map(\.card.noteID) ?? [])
    }

    /// A Selected sitting over loaded rows, as they are listed, planned against the last read's
    /// instant, its introductions and today's one-day increase.
    private func planner(for reading: Reading) -> ([LibraryRow]) -> SelectedSittingPlan {
        let scope = reading.dictionary
        let increase = OneDayIncreaseStore(defaults: defaults).extra(in: .standard, at: reading.at)
        return { listed in
            Self.selectedPlan(of: listed, at: reading.at, scope: scope, introducedToday: reading.introducedToday,
                              increaseToday: increase)
        }
    }

    /// The Selected sitting the loaded rows of `ids` would be — nil before a read.
    private func selectedPlan(of ids: Set<UUID>) -> SelectedSittingPlan? {
        guard let reading else { return nil }
        return planner(for: reading)(reading.rows.filter { ids.contains($0.id) })
    }

    /// **The rows of `ids` that confirming would change**: loaded, and with nothing but the reader's
    /// agreement in the way. A row whose readiness is unknown because it is not on a loaded page is
    /// not one, and neither is a confirmed note or one that needs an answer first.
    private func confirmable(in ids: Set<UUID>) -> Set<UUID> {
        Set((reading?.rows ?? []).lazy.filter { ids.contains($0.id) && $0.obstacle == .confirmation }.map(\.id))
    }

    /// When a confirmation of `noteID` hides its card, or nil — always nil while the experiment is
    /// off, which is the default. Asked of the reader's own defaults suite at each confirmation.
    private func cooldownUntil(_ noteID: UUID, confirmedAt when: Date,
                               exposure: ConfirmationCooldown.Exposure) -> Date? {
        ConfirmationCooldownSetting(defaults: defaults).cooldown?
            .hiddenUntil(noteID: noteID, confirmedAt: when, exposure: exposure)
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
        // **By the remedy, not the verdict**, so "Confirm the meaning" is said only where confirming
        // is what it needs: an entry rung carrying the dictionary's text is `.needsConfirmation` and
        // needs the reader's own answer instead (ADR-0030).
        switch row.obstacle {
        case .confirmation: return .needsConfirmation
        case .answer, .readingDeleted, .senseMoved: return .needsRepair
        case nil: return nil
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
                              sittingOffersFind: review.presentation.offersFindUnconfirmed,
                              canUndo: review.canUndo, undo: { review.act(.undo) },
                              findUnconfirmed: { model.findUnconfirmed() }) {
                ReviewSceneView(model: review, findUnconfirmed: { model.findUnconfirmed() },
                                findUnanswered: { model.findUnanswered() })
            }
        }
        .task { await model.refreshPane(); await model.importLegacy() }
        .onChange(of: LedgerChanges.shared.revision) { _, _ in Task { await model.refreshPane() } }
    }
}
