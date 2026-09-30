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
    private(set) var presentation = LibraryPresentation(rows: [], total: 0)
    private var search = ""
    private var filter = LibraryPresentation.Filter.all
    private var scriptFiltered = false
    /// One of the reader's own tags, or nil for all. Part of the query, never a filter on the page.
    private var tag: String?
    private var selection: Set<UUID> = []
    /// How many pages the reader has asked for. **Grown rather than offset**, so a card enrolled
    /// while they are reading does not shift a boundary underneath them.
    private var pages = 1
    private var exported: String?
    /// The last bulk pause or archive, while it can still be put back. **One level**: an undo that
    /// outlives the reader's memory of what it reverses is a worse control than none.
    private var undoable: Undo?
    /// Why the last change did not land, until the next one is attempted. **Not the reload's
    /// `problem`**, which is about reading; this one is about writing, and both reach the same
    /// field on the presentation.
    private var problem: String?
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
    private let lookUp: @MainActor (String) -> Void
    private var scripts: Set<ProbeScript> = []

    /// How many rows one page holds. The library is paged rather than capped: a reader looking for
    /// something from March must be able to reach March.
    static let pageSize = 200
    /// **Five, and no more.** C06: a suggestion list long enough to feel like a backlog is one,
    /// and an unopened suggestion is supposed to cost the reader nothing.
    static let suggestionCount = 5

    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    private let studyScripts: @MainActor () -> Set<ProbeScript>
    private let clock: @MainActor () -> Date
    /// Where an export is written. **A parameter, like the clock**, because a test that exercised
    /// the real path wrote into the reader's own Downloads folder and then deleted what it found
    /// there — every `make test` on any Mac, destroying an export they had made.
    private let exportDirectory: @MainActor () -> URL

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         studyScripts: @escaping @MainActor () -> Set<ProbeScript> = { HoverPolicyStore().load().scripts },
         clock: @escaping @MainActor () -> Date = { .now },
         exportDirectory: @escaping @MainActor () -> URL = {
             FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
         },
         lookUp: @escaping @MainActor (String) -> Void = { _ in }) {
        self.store = store
        self.studyScripts = studyScripts
        self.clock = clock
        self.exportDirectory = exportDirectory
        self.lookUp = lookUp
    }

    func act(_ action: LibraryAction) {
        problem = nil
        switch action {
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
        case .filterScripts(let on): scriptFiltered = on; pages = 1
        case .filterTag(let name): tag = name; pages = 1
        case .select(let ids): selection = ids
        case .showMore: pages += 1
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

    func reload() async {
        guard let opening = store() else { return }
        generation += 1
        let mine = generation
        do {
            let ledger = try await opening.value
            scripts = studyScripts()
            let query = self.query()
            let rows = try await ledger.library(query)
            let total = try await ledger.libraryCount(query)
            let now = clock()
            // One query for the page's answers, not one per row: the list is redrawn on every
            // keystroke of the search field, and two hundred round trips through an actor per
            // keystroke is a search field that stutters.
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
            let answers = try await ledger.answers(of: rows.map(\.id))
            // Only under the suggested filter: a list nobody is looking at is a query nobody
            // should pay for on every keystroke.
            // **The controls on screen govern what is on screen.** Suggestions ignored the
            // search box entirely and applied the study-scripts narrowing whether or not the
            // toggle was on — so the two visible controls were quietly filtering the *library*
            // rows behind this list while appearing to do nothing, and the toggle did the
            // opposite of what it said.
            var suggested: [Ledger.Suggestion] = []
            if filter == .suggested {
                let narrowing = search.trimmingCharacters(in: .whitespaces).lowercased()
                let all = try await ledger.suggestions(
                    limit: Self.suggestionCount * 4, language: nil,
                    studying: scriptFiltered ? scripts : [])
                suggested = Array(all.lazy
                    .filter { narrowing.isEmpty || $0.lemma.lowercased().contains(narrowing) }
                    .prefix(Self.suggestionCount))
            }
            // Beside the suggestions, and only there: setting a word aside enrols nothing, so
            // this list is the only place the declaration is visible — and the only place it can
            // be taken back.
            let setAside = filter == .suggested ? try await ledger.ignoredSuggestions() : []
            // **One row, or none**, so a history is read for the row the reader opened and not
            // for two hundred of them on every keystroke of the search field.
            let open = selection.count == 1 ? selection.first : nil
            var timeline: NoteTimeline?
            var tags: [String] = []
            if let open {
                timeline = try await ledger.timeline(of: open)
                tags = try await ledger.tags(of: open)
            }
            let measured = try await ledger.retention(dictionary: nil)
            let vocabulary = try await ledger.allTags()
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
            presentation = LibraryPresentation(
                rows: rows.map { Self.row($0, answer: answers[$0.id]?.text ?? "", at: now) },
                total: total, search: search, filter: filter, scriptFiltered: scriptFiltered,
                selection: selection,
                // **Offered only when there is more.** The count is of everything that matched, so
                // a library of exactly one page must not show a button that does nothing.
                hasMore: total > rows.count,
                // Whether any of the selection can be confirmed, so the control is present only
                // when it would do something.
                canConfirm: rows.contains { selection.contains($0.id) && $0.readiness == .needsConfirmation },
                suggestions: suggested.map {
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
                setAside: setAside,
                tagVocabulary: vocabulary, tag: tag,
                // **Nil over an empty denominator.** A rate nobody has is not 0%.
                retention: LibraryPresentation.Retention(
                    attempts: measured.attempts, successes: measured.successes,
                    cards: measured.cards),
                // **One row, or none.** An inspector over several would have to choose which one
                // an edit reaches, and the reader cannot see which it chose.
                inspector: Self.inspector(of: rows, selection: selection, answers: answers,
                                          tags: tags, timeline: timeline))
        } catch {
            // **Said, not swallowed.** An empty list and a list that could not be read are the same
            // screen otherwise, and the reader is owed the difference. Still only for the current
            // reload: an overtaken one's failure is not this screen's.
            guard mine == generation else { return }
            presentation = LibraryPresentation(rows: [], total: 0, search: search, filter: filter,
                                               scriptFiltered: scriptFiltered,
                                               problem: String(describing: error))
        }
    }

    /// A change that cannot be put back. **Retires the undo**, because a button offering to
    /// reverse something older than the reader's last action is one they will press by mistake.
    ///
    /// `keepingSelection` is for changes the reader makes *to* the open row rather than to a set
    /// of rows: clearing after one would close the inspector they are working in, which reads as
    /// the edit having thrown them out.
    private func apply(keepingSelection: Bool = false,
                       _ change: @escaping @Sendable (LedgerStore) async throws -> Void) {
        undoable = nil
        actions += 1
        guard let opening = store() else { return }
        Task {
            // **A write that did not happen is said, not dropped.** `try?` on both calls meant a
            // failed archive, pause, tag or removal cleared the selection and redrew a list that
            // looked exactly as if it had worked — the reader believing a change landed is worse
            // than the change not landing.
            var failure: String?
            do {
                try await change(try await opening.value)
            } catch {
                failure = error.localizedDescription
            }
            if !keepingSelection { selection = [] }
            await reload()
            if let failure { problem = failure; republish() }
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
        undoable = nil
        guard let opening = store(), !ids.isEmpty else { return }
        // **This action's turn.** An earlier reversible task finishing after a later one had
        // retired the undo reinstalled its own, stale record — pressing Undo then put rows back
        // to a state two actions ago. Two overlapping ones could also publish in completion
        // order rather than in the order the reader pressed them.
        actions += 1
        let mine = actions
        Task {
            var failure: String?
            do {
                let recorded = try await change(try await opening.value, ids)
                if mine == actions { undoable = recorded }
            } catch {
                failure = error.localizedDescription
            }
            selection = []
            await reload()
            if let failure { problem = failure; republish() }
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
            filter: presentation.filter, scriptFiltered: presentation.scriptFiltered,
            selection: presentation.selection, hasMore: presentation.hasMore,
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try written.tabSeparated().write(to: url, atomically: true, encoding: .utf8)
            exported = url.path
        } catch {
            exported = error.localizedDescription
        }
        await reload()
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
            scripts: scriptFiltered ? scripts : nil,
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
            id: row.id, word: row.word, excerpt: row.excerpt, answer: answer,
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
            id: id, word: row.word, answer: answer?.text ?? "",
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
            return String(localized: "Put off until \(hidden.formatted(date: .abbreviated, time: .omitted))",
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

    var body: some View {
        LibraryView(state: model.presentation) { model.act($0) }
            .task { await model.reload() }
    }
}
