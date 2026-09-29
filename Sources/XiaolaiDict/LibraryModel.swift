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
        case .search(let text): search = text
        case .filter(let value): filter = value
        case .filterScripts(let on): scriptFiltered = on
        case .select(let ids): selection = ids
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
            let answers = try await ledger.answers(of: rows.map(\.id))
            presentation = LibraryPresentation(
                rows: rows.map { Self.row($0, answer: answers[$0.id]?.text ?? "", at: now) },
                total: total, search: search, filter: filter, scriptFiltered: scriptFiltered,
                // A selection that no longer exists is dropped: a bulk action must not carry an id
                // the reader can no longer see.
                selection: selection.intersection(Set(rows.map(\.id))))
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
        LibraryQuery(
            text: search,
            enrollment: {
                switch filter {
                case .all: nil
                case .due, .needsAttention: [.active]
                case .paused: [.active]
                case .archived: [.archived]
                }
            }(),
            scripts: scriptFiltered ? scripts : nil,
            limit: Self.pageSize)
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
