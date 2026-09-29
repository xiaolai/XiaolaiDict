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
    @State private var tag = ""

    public init(state: LibraryPresentation, act: @escaping @MainActor (LibraryAction) -> Void) {
        self.state = state
        self.act = act
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if state.filter == .suggested {
                suggestions
            } else if state.rows.isEmpty {
                empty
            } else {
                list
                if state.hasMore {
                    Button("Show more") { act(.showMore) }
                        .padding(.bottom, scale.space.line)
                }
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

    /// **Offered, never enrolled.** An unopened suggestion costs the reader nothing, and neither
    /// button here grades anything — "already know" is a declaration about this word, not a
    /// measurement of it.
    @ViewBuilder
    private var suggestions: some View {
        if state.suggestions.isEmpty {
            VStack(spacing: scale.space.line) {
                Text("Nothing to suggest yet.")
                Text("A word you look up on more than one day appears here.")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(state.suggestions) { suggestion in
                HStack(spacing: scale.space.inline) {
                    VStack(alignment: .leading, spacing: scale.space.tight) {
                        Text(verbatim: suggestion.lemma)
                            .font(.system(size: scale.text.body, weight: .medium))
                        // The evidence, so the ranking is legible rather than trusted.
                        Text("Looked up on \(suggestion.days) days, in \(suggestion.sources) places")
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Study") { act(.study(lemma: suggestion.lemma)) }
                    Button("Already know") {
                        act(.ignore(lemma: suggestion.lemma, language: suggestion.language))
                    }
                }
                .padding(.vertical, scale.space.tight)
            }
            .listStyle(.inset)
        }
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
            if let problem = state.problem {
                Text(verbatim: problem)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Changing

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                if state.canConfirm {
                    Button("Confirm \(state.selection.count)") { act(.confirm) }
                }
                Button("Pause \(state.selection.count)") { act(.pause) }
                Button("Archive \(state.selection.count)") { act(.archive) }
                // **Two different deletions, named apart.** Removing from study keeps the reading;
                // deleting the reading keeps the card. A single "Delete" would mean whichever the
                // reader assumed.
                Button("Remove \(state.selection.count) from study", role: .destructive) {
                    act(.removeFromStudy)
                }
                TextField("Tag", text: $tag)
                    .frame(maxWidth: Token.Library.tagWidth)
                    .onSubmit {
                        act(.tag(tag))
                        tag = ""
                    }
            }
            Button("Export…") { act(.export) }
        }
        .padding(scale.space.padAcross)
        if let exported = state.exported {
            // The path, because an export the reader cannot find did not happen for them.
            Text(verbatim: exported)
                .font(.system(size: scale.text.micro))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, scale.space.padAcross)
                .padding(.bottom, scale.space.line)
        }
        }
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
    /// One more page. **Grown, not offset**: a card enrolled while the reader is reading must not
    /// shift a boundary underneath them.
    case showMore
    /// The reader agrees these are the meanings they met. The library showed "Confirm the meaning"
    /// as a status with no way to act on it — a diagnosis with no remedy.
    case confirm
    case filter(LibraryPresentation.Filter)
    case filterScripts(Bool)
    case select(Set<UUID>)
    case pause
    case archive
    case removeFromStudy
    /// Label the selection. **Organisation, not a fact about memory** — nothing reschedules.
    case tag(String)
    /// Write the collection out. What may leave is decided in `StudyExport`, not here.
    case export
    /// Take up a suggestion, or refuse it. Both are the reader's declaration and both are
    /// reversible; neither grades anything.
    case study(lemma: String)
    /// The language travels with it: a reader who knows English *pain* has said nothing about the
    /// French one, and silencing the wrong pair silences nothing at all.
    case ignore(lemma: String, language: String)
}

/// What the library draws.
public struct LibraryPresentation: Sendable, Equatable {
    public let rows: [Row]
    public let total: Int
    public let search: String
    public let filter: Filter
    public let scriptFiltered: Bool
    public let selection: Set<UUID>
    /// Whether anything matched beyond what is listed.
    public let hasMore: Bool
    /// Whether the selection holds anything a confirmation would change.
    public let canConfirm: Bool
    /// What the reader keeps looking up and has not saved. Only read under the `suggested` filter.
    public let suggestions: [Suggestion]
    /// Where the last export went, once one has been written.
    public let exported: String?
    /// Why the list is empty, when the reason is a failure rather than an empty collection.
    ///
    /// **Without this the two are the same screen.** A library that could not be read drew exactly
    /// as one with nothing in it, which is the silent-failure shape this project spends its time
    /// removing — and it hid a real defect for the length of one debugging session.
    public let problem: String?

    public init(rows: [Row], total: Int, search: String = "", filter: Filter = .all,
                scriptFiltered: Bool = false, selection: Set<UUID> = [],
                hasMore: Bool = false, canConfirm: Bool = false,
                suggestions: [Suggestion] = [], exported: String? = nil,
                problem: String? = nil) {
        self.rows = rows
        self.total = total
        self.search = search
        self.filter = filter
        self.scriptFiltered = scriptFiltered
        self.selection = selection
        self.hasMore = hasMore
        self.canConfirm = canConfirm
        self.suggestions = suggestions
        self.exported = exported
        self.problem = problem
    }

    /// The sidebar's states, as one control. **Archived and paused are here**, because the library is
    /// where a reader goes to find what they put away.
    public enum Filter: String, Sendable, CaseIterable {
        case all, due, needsAttention, paused, archived, suggested

        public var name: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .due: "Due"
            case .needsAttention: "Needs attention"
            case .paused: "Paused"
            case .archived: "Archived"
            case .suggested: "Suggested"
            }
        }
    }

    /// A word the reader keeps looking up and has not saved.
    ///
    /// **Not a card, and drawn as a different thing.** It carries its own evidence — how many days,
    /// how many places — so the surface can say *why* it is being offered rather than presenting a
    /// ranking the reader has to take on trust.
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public let lemma: String
        public let language: String
        public let days: Int
        public let sources: Int

        public var id: String { "\(lemma)\u{1F}\(language)" }

        public init(lemma: String, language: String, days: Int, sources: Int) {
            self.lemma = lemma
            self.language = language
            self.days = days
            self.sources = sources
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
