import DictionaryModel
import Foundation
import SwiftUI
import XiaolaiDictCore

/// **The library: everything the reader has saved, and the operations that change it.**
///
/// A list and an inspector, not a wall of cards. The drawer is the surface for glancing at recent
/// reading; this is the one for finding something from March, seeing why it is not being asked, and
/// putting a dozen things away at once.
///
/// **The preview starts on the question side.** A reader managing their collection is not reviewing
/// it, but a list that prints every meaning is one they cannot skim without being taught — so the
/// answer is behind the same deliberate reveal the review surface uses, per card, never persisted.
public struct LibraryView: View {
    @Environment(\.scale) private var scale
    public let state: LibraryPresentation
    public let act: @MainActor (LibraryAction) -> Void

    @State private var revealed: Set<UUID> = []

    public init(state: LibraryPresentation, act: @escaping @MainActor (LibraryAction) -> Void) {
        self.state = state
        self.act = act
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if state.rows.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
    }

    // MARK: - Finding

    private var toolbar: some View {
        HStack(spacing: scale.space.inline) {
            TextField("Search", text: Binding(
                get: { state.search },
                set: { act(.search($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: Token.Library.searchWidth)
            Picker("Show", selection: Binding(
                get: { state.filter },
                set: { act(.filter($0)) })) {
                ForEach(LibraryPresentation.Filter.allCases, id: \.self) { filter in
                    Text(filter.name).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
            // **Offered, off by default.** The reader's study-scripts setting filters their reading;
            // applying it here unasked would hide scheduled work, and a filtered library and an
            // empty one look exactly alike.
            Toggle("Only my study scripts", isOn: Binding(
                get: { state.scriptFiltered },
                set: { act(.filterScripts($0)) }))
                .toggleStyle(.checkbox)
        }
        .padding(scale.space.padAcross)
    }

    private var list: some View {
        List(state.rows, selection: Binding(
            get: { state.selection },
            set: { act(.select($0)) })) { row in
            LibraryRowView(row: row, isRevealed: revealed.contains(row.id),
                           reveal: { revealed.insert(row.id) })
                .tag(row.id)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: scale.space.line) {
            // **Two different nothings**, said differently: a reader who has saved nothing is not a
            // reader whose search found nothing.
            if state.search.isEmpty && state.filter == .all {
                Text("You have not saved any meanings yet.")
                Text("A meaning you save while reading appears here.")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing matches.")
                Button("Clear the search") { act(.search("")) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Changing

    private var footer: some View {
        HStack(spacing: scale.space.inline) {
            // **The scope is on the button**, because a bulk action the reader misjudged is the one
            // they cannot see the extent of until it has happened.
            Text(state.selection.isEmpty
                 ? "\(state.total) cards"
                 : "\(state.selection.count) selected")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !state.selection.isEmpty {
                Button("Pause \(state.selection.count)") { act(.pause) }
                Button("Archive \(state.selection.count)") { act(.archive) }
                // **Two different deletions, named apart.** Removing from study keeps the reading;
                // deleting the reading keeps the card. A single "Delete" would mean whichever the
                // reader assumed.
                Button("Remove \(state.selection.count) from study", role: .destructive) {
                    act(.removeFromStudy)
                }
            }
        }
        .padding(scale.space.padAcross)
    }
}

/// One row: the word, the reader's own sentence, and why it is or is not being asked.
struct LibraryRowView: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    let row: LibraryPresentation.Row
    let isRevealed: Bool
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: row.word)
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(ReadingPalette.accent(for: row.word).color(in: scheme))
                if let status = row.status {
                    Text(status.name)
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let due = row.due {
                    Text(verbatim: due)
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.tertiary)
                }
            }
            if !row.excerpt.isEmpty {
                Text(verbatim: row.excerpt)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(Token.Limit.excerptLines)
            }
            // Behind a deliberate reveal, like every other surface that could answer the question.
            if isRevealed {
                Text(verbatim: row.answer)
                    .font(.system(size: scale.text.small))
                    .textSelection(.enabled)
            } else {
                Button("Show the meaning", action: reveal)
                    .buttonStyle(.link)
                    .font(.system(size: scale.text.micro))
            }
        }
        .padding(.vertical, scale.space.tight)
    }
}

public enum LibraryAction: Sendable, Equatable {
    case search(String)
    case filter(LibraryPresentation.Filter)
    case filterScripts(Bool)
    case select(Set<UUID>)
    case pause
    case archive
    case removeFromStudy
}

/// What the library draws.
public struct LibraryPresentation: Sendable, Equatable {
    public let rows: [Row]
    public let total: Int
    public let search: String
    public let filter: Filter
    public let scriptFiltered: Bool
    public let selection: Set<UUID>

    public init(rows: [Row], total: Int, search: String = "", filter: Filter = .all,
                scriptFiltered: Bool = false, selection: Set<UUID> = []) {
        self.rows = rows
        self.total = total
        self.search = search
        self.filter = filter
        self.scriptFiltered = scriptFiltered
        self.selection = selection
    }

    /// The sidebar's states, as one control. **Archived and paused are here**, because the library is
    /// where a reader goes to find what they put away.
    public enum Filter: String, Sendable, CaseIterable {
        case all, due, needsAttention, paused, archived

        public var name: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .due: "Due"
            case .needsAttention: "Needs attention"
            case .paused: "Paused"
            case .archived: "Archived"
            }
        }
    }

    /// Why a card is not being asked.
    public enum Status: Sendable, Equatable, CaseIterable {
        case needsConfirmation
        case needsRepair
        case paused
        case archived
        case ignored

        var name: LocalizedStringKey {
            switch self {
            case .needsConfirmation: "Confirm the meaning"
            case .needsRepair: "Needs attention"
            case .paused: "Paused"
            case .archived: "Archived"
            case .ignored: "Already known"
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let word: String
        public let excerpt: String
        /// The answer, which the row shows only when the reader asks.
        public let answer: String
        /// Why it is not being asked, where it is not. Nil when it is simply due or waiting.
        ///
        /// **A case, not a string.** Reader-facing text belongs in the catalog, and a model that
        /// carried the sentence would be a model choosing the words.
        public let status: Status?
        /// When it comes back, in the reader's words.
        public let due: String?

        public init(id: UUID, word: String, excerpt: String, answer: String,
                    status: Status?, due: String?) {
            self.id = id
            self.word = word
            self.excerpt = excerpt
            self.answer = answer
            self.status = status
            self.due = due
        }
    }
}
