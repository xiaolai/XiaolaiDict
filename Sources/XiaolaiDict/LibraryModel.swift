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
    private var scripts: Set<ProbeScript> = []

    /// How many rows one page holds. The library is paged rather than capped: a reader looking for
    /// something from March must be able to reach March.
    static let pageSize = 200

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
        case .pause:
            let ids = Array(selection)
            return apply { try await $0.setPaused(true, ofNotes: ids) }
        case .archive:
            let ids = Array(selection)
            return apply { try await $0.setEnrollment(.archived, ofNotes: ids) }
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
            presentation = LibraryPresentation(
                rows: rows.map { Self.row($0, answer: answers[$0.id]?.text ?? "", at: now) },
                total: total, search: search, filter: filter, scriptFiltered: scriptFiltered,
                selection: selection,
                // **Offered only when there is more.** The count is of everything that matched, so
                // a library of exactly one page must not show a button that does nothing.
                hasMore: total > rows.count,
                // Whether any of the selection can be confirmed, so the control is present only
                // when it would do something.
                canConfirm: rows.contains { selection.contains($0.id) && $0.readiness == .needsConfirmation })
        } catch {
            presentation = LibraryPresentation(rows: [], total: 0, search: search, filter: filter,
                                               scriptFiltered: scriptFiltered)
        }
    }

    private func apply(_ change: @escaping @Sendable (LedgerStore) async throws -> Void) {
        guard let opening = store() else { return }
        Task {
            if let ledger = try? await opening.value { try? await change(ledger) }
            selection = []
            await reload()
        }
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
                case .all, .archived: nil
                case .due: .due
                case .paused: .paused
                case .needsAttention: .needsAttention
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
