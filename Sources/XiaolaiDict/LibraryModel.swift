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
    private var selection: Set<UUID> = []
    /// How many pages the reader has asked for. **Grown rather than offset**, so a card enrolled
    /// while they are reading does not shift a boundary underneath them.
    private var pages = 1
    private var exported: String?
    /// The last bulk pause or archive, while it can still be put back. **One level**: an undo that
    /// outlives the reader's memory of what it reverses is a worse control than none.
    private var undoable: Undo?

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

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         studyScripts: @escaping @MainActor () -> Set<ProbeScript> = { HoverPolicyStore().load().scripts },
         clock: @escaping @MainActor () -> Date = { .now }) {
        self.store = store
        self.studyScripts = studyScripts
        self.clock = clock
    }

    func act(_ action: LibraryAction) {
        switch action {
        // Any change to what is being looked at starts the paging over: a page count carried
        // across a new search is a "show more" button that reveals rows from the old one.
        case .search(let text): search = text; pages = 1
        case .filter(let value): filter = value; pages = 1
        case .filterScripts(let on): scriptFiltered = on; pages = 1
        case .select(let ids): selection = ids
        case .showMore: pages += 1
        case .confirm:
            let ids = Array(selection)
            let when = clock()
            return apply { store in for id in ids { try await store.confirm(noteID: id, at: when) } }
        case .tag(let text):
            let ids = Array(selection), trimmed = text
            return apply(keepingSelection: true) { store in
                for id in ids { try await store.tag(noteID: id, trimmed) }
            }
        case .untag(let text):
            guard let id = selection.first, selection.count == 1 else { return }
            return apply(keepingSelection: true) { try await $0.untag(noteID: id, text) }
        case .unignore(let lemma, let language):
            return apply { try await $0.unignoreSuggestion(lemma: lemma, language: language) }
        case .setAnswer(let text):
            // **Exactly the row the inspector is showing**, which is the only row there is: the
            // pane is absent unless the selection is one.
            guard let id = selection.first, selection.count == 1 else { return }
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
            return
        case .ignore(let lemma, let language):
            let when = clock()
            return apply { try await $0.ignoreSuggestion(lemma: lemma, language: language, at: when) }
        case .pause:
            return applyReversible(Array(selection)) { store, ids in
                // Read before the write, in this order, so what is remembered is what was there.
                let before = try await store.pauseStates(ofNotes: ids)
                try await store.setPaused(true, ofNotes: ids)
                return .pause(before)
            }
        case .resume:
            let ids = Array(selection)
            return apply { try await $0.setPaused(false, ofNotes: ids) }
        case .archive:
            return applyReversible(Array(selection)) { store, ids in
                let before = try await store.enrollments(ofNotes: ids)
                try await store.setEnrollment(.archived, ofNotes: ids)
                return .archive(before)
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
        }
        Task { await reload() }
    }

    func reload() async {
        guard let opening = store() else { return }
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
            selection.formIntersection(Set(rows.map(\.id)))
            let answers = try await ledger.answers(of: rows.map(\.id))
            // Only under the suggested filter: a list nobody is looking at is a query nobody
            // should pay for on every keystroke.
            let suggested = filter == .suggested
                ? try await ledger.suggestions(limit: Self.suggestionCount, language: nil,
                                               studying: scripts)
                : []
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
            // screen otherwise, and the reader is owed the difference.
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
        guard let opening = store() else { return }
        Task {
            if let ledger = try? await opening.value { try? await change(ledger) }
            if !keepingSelection { selection = [] }
            await reload()
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
        Task {
            if let ledger = try? await opening.value,
               let recorded = try? await change(ledger, ids) {
                undoable = recorded
            }
            selection = []
            await reload()
        }
    }

    /// Writes the collection out and remembers where it went.
    ///
    /// **The path is shown**, because an export the reader cannot find did not happen for them.
    private func export() async {
        guard let opening = store(), let ledger = try? await opening.value else { return }
        do {
            let written = try await ledger.export(dictionary: nil)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Downloads/XiaolaiDict-cards.txt")
            try written.tabSeparated().write(to: url, atomically: true, encoding: .utf8)
            exported = url.path
        } catch {
            exported = error.localizedDescription
        }
        await reload()
    }

    private func query() -> LibraryQuery {
        // **Each filter is its own predicate.** They were once all `enrollment = 'active'`, so
        // Paused listed unpaused cards and Due listed cards due next year — and the bulk actions
        // then operated on a set the label had described wrongly.
        LibraryQuery(
            text: search,
            enrollment: filter == .archived ? [.archived] : nil,
            scripts: scriptFiltered ? scripts : nil,
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
