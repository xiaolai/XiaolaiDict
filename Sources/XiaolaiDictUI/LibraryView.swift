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
    /// The inspector's editor, held here rather than in the model: an in-progress edit is not
    /// state the ledger has any business knowing about until the reader saves it.
    @State private var draft = ""

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
            if let inspector = state.inspector {
                Divider()
                self.inspector(inspector)
            }
            Divider()
            footer
        }
    }

    // MARK: - The one row that is open

    /// **The answer, and the reader's right to replace it.**
    ///
    /// Behind the same reveal the rows use: a reader tidying their collection is not reviewing it,
    /// and a pane that prints the meaning of whatever they click would teach them the answer on the
    /// way past. Once they have asked, it is an editor rather than a label — replacing the
    /// publisher's words with their own is the point, not a hidden capability.
    @ViewBuilder
    private func inspector(_ inspector: LibraryPresentation.Inspector) -> some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: inspector.word)
                    .font(.system(size: scale.text.body, weight: .medium))
                // **Whose words these are**, because replacing the publisher's for the first time
                // and editing your own read identically without it.
                Text(inspector.isReaders ? "Your own answer" : "From the dictionary")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if revealed.contains(inspector.id) {
                TextField("The answer", text: $draft, axis: .vertical)
                    .lineLimit(Token.Limit.answerLinesAtLeast...Token.Limit.answerLinesAtMost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: scale.text.small))
                HStack(spacing: scale.space.inline) {
                    Button("Save the answer") { act(.setAnswer(noteID: inspector.id, text: draft)) }
                        .disabled(!canSave(inspector))
                    // **Said, not merely disabled.** A button that refuses a click without a reason
                    // is a broken switch, and "blank" is not guessable from a greyed-out control.
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("An answer cannot be blank.")
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Button("Show the meaning") { revealed.insert(inspector.id) }
                    .buttonStyle(.link)
                    .font(.system(size: scale.text.micro))
            }
            if !inspector.tags.isEmpty {
                HStack(spacing: scale.space.inline) {
                    ForEach(inspector.tags, id: \.self) { tag in
                        // **Readable and removable.** A label the reader can add and never take
                        // off is a worse state than having no labels.
                        Button { act(.untag(noteID: inspector.id, tag: tag)) } label: {
                            Text(verbatim: tag)
                                .font(.system(size: scale.text.micro))
                        }
                        .buttonStyle(.bordered)
                        .help(Text("Remove this tag"))
                    }
                    Spacer(minLength: 0)
                }
            }
            timeline(inspector)
        }
        .padding(scale.space.padAcross)
        // **Reset when the row changes, never carried.** A draft left over from the previous
        // selection would be saved onto this word the moment the reader pressed the button.
        .onChange(of: inspector.id, initial: true) { draft = inspector.answer }
        .onChange(of: inspector.answer) { draft = inspector.answer }
    }

    /// **Where it was met, and what was done with the card — in two lists** (M05).
    ///
    /// Never interleaved. A reading is something the reader did with a text and a review is
    /// something they did with a card; one sequence invites reading a grade as evidence about the
    /// sentence beside it.
    @ViewBuilder
    private func timeline(_ inspector: LibraryPresentation.Inspector) -> some View {
        HStack(alignment: .top, spacing: scale.space.column) {
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("Where you met it")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(inspector.readings) { reading in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                        Text(reading.at, format: .dateTime.year().month().day())
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.tertiary)
                        Text(verbatim: reading.sentence)
                            .font(.system(size: scale.text.micro))
                            .lineLimit(Token.Limit.wrapLines)
                        if let source = reading.source {
                            Text(verbatim: source)
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("What you answered")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                if inspector.reviews.isEmpty {
                    Text("Not reviewed yet.")
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.tertiary)
                }
                ForEach(inspector.reviews) { review in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                        Text(review.at, format: .dateTime.year().month().day())
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.tertiary)
                        Text(review.grade.readerName)
                            .font(.system(size: scale.text.micro))
                        // **Said, not filtered out**: practice moved nothing, and an undone
                        // attempt is still part of the trail.
                        if review.isPractice {
                            Text("practice")
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.tertiary)
                        }
                        if review.isVoided {
                            Text("taken back")
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Saveable when there is something to save: not blank, and not what is already stored.
    private func canSave(_ inspector: LibraryPresentation.Inspector) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && draft != inspector.answer
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
            // **Absent until there is something to pick.** A tag menu over no tags is a control
            // that cannot do anything, which reads as one that is broken.
            if !state.tagVocabulary.isEmpty {
                Picker("Tag", selection: Binding(
                    get: { state.tag },
                    set: { act(.filterTag($0)) })) {
                    Text("Any tag").tag(String?.none)
                    ForEach(state.tagVocabulary, id: \.tag) { entry in
                        Text(verbatim: "\(entry.tag) (\(entry.count))").tag(String?.some(entry.tag))
                    }
                }
                .frame(maxWidth: Token.Library.tagWidth)
            }
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
        setAside
    }

    /// **What the reader set aside, and the way back.** Setting a word aside enrols nothing, so
    /// there is no library row to find it by — without this list "already know" is a declaration
    /// that cannot be seen and therefore cannot be taken back.
    @ViewBuilder
    private var setAside: some View {
        if !state.setAside.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("Words you already know")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(state.setAside) { lemma in
                    HStack(spacing: scale.space.inline) {
                        Text(verbatim: lemma.lemma)
                            .font(.system(size: scale.text.small))
                        Spacer(minLength: 0)
                        Button("Offer it again") {
                            act(.unignore(lemma: lemma.lemma, language: lemma.language))
                        }
                        .buttonStyle(.link)
                        .font(.system(size: scale.text.micro))
                    }
                }
            }
            .padding(scale.space.padAcross)
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
            // **The denominator, always beside the rate** (U03). A percentage on its own is the
            // one figure here nobody can check afterwards, and absent is what it is when there
            // has been nothing eligible to measure.
            if let retention = state.retention {
                Text("\(retention.rate, format: .percent.precision(.fractionLength(0))) recalled, over \(retention.attempts) reviews")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !state.selection.isEmpty {
                if state.canConfirm {
                    Button("Confirm \(state.selection.count)") { act(.confirm) }
                }
                // **Named for what it will do to this selection.** A Pause button over rows that
                // are all resting is a control whose label is wrong before it is pressed.
                if state.selectionIsPaused {
                    Button("Resume \(state.selection.count)") { act(.resume) }
                } else {
                    Button("Pause \(state.selection.count)") { act(.pause) }
                }
                if state.selectionIsArchived {
                    Button("Unarchive \(state.selection.count)") { act(.unarchive) }
                } else {
                    Button("Archive \(state.selection.count)") { act(.archive) }
                }
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
            // **Outside the selection block**, because putting a bulk action back is not an
            // operation on whatever happens to be selected now.
            if let undoable = state.undoable {
                Button(undoable.name) { act(.undo) }
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

/// **The words the reader actually pressed.**
///
/// The review surface offers two: *Forgot* and *Remembered*. A trail that reported "again" and
/// "good" would be showing someone the scheduler's vocabulary, which they have never seen. The
/// other two are named plainly against the day they are offered.
extension Grade {
    var readerName: LocalizedStringKey {
        switch self {
        case .again: "Forgot"
        case .hard: "Hard"
        case .good: "Remembered"
        case .easy: "Easy"
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
    /// **The way back.** `setPaused(false, …)` existed with nothing able to reach it, so pausing
    /// was a one-way door — worse than a missing undo, because no amount of care avoided it.
    case resume
    case archive
    case unarchive
    /// Put the last bulk pause or archive back, exactly as each row was. **One level**, and it is
    /// retired by the next change rather than kept around to reverse something older than the
    /// reader remembers.
    case undo
    case removeFromStudy
    /// Label the selection. **Organisation, not a fact about memory** — nothing reschedules.
    case tag(String)
    /// **The reader's own words, for the one row they have open.** Replaces what the card reveals
    /// and leaves the encounter's snapshot alone — the dictionary said what it said.
    ///
    /// **The note is named, not taken from the selection.** Selection changes at once and the
    /// inspector catches up after a reload; in that window the pane still shows A while the model
    /// has moved to B, and saving wrote A's answer onto B. The view knows which row it is
    /// drawing, so the view says so.
    case setAnswer(noteID: UUID, text: String)
    /// Take a tag off one row. **The reverse of `tag`**, which existed alone: a label the reader
    /// could add and never remove. Named for the same reason `setAnswer` is.
    case untag(noteID: UUID, tag: String)
    /// Offer a set-aside word again. "Already know" is a declaration, and a declaration the reader
    /// cannot take back is a trap rather than a preference.
    case unignore(lemma: String, language: String)
    /// Narrow to one of the reader's own tags, or nil for all of them. **A tag is for finding
    /// things again**; one that could be written and never searched was half a feature.
    case filterTag(String?)
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
    /// Hand-written because `tagVocabulary` is an array of tuples, which Swift will not synthesise
    /// equality for. Every stored property is compared — a hand-written `==` that forgets one is
    /// a view that stops redrawing for a change it cannot see.
    public static func == (a: LibraryPresentation, b: LibraryPresentation) -> Bool {
        a.rows == b.rows && a.total == b.total && a.search == b.search && a.filter == b.filter
            && a.scriptFiltered == b.scriptFiltered && a.selection == b.selection
            && a.hasMore == b.hasMore && a.canConfirm == b.canConfirm
            && a.suggestions == b.suggestions && a.exported == b.exported
            && a.selectionIsPaused == b.selectionIsPaused
            && a.selectionIsArchived == b.selectionIsArchived
            && a.undoable == b.undoable && a.setAside == b.setAside
            && a.tagVocabulary.map(\.tag) == b.tagVocabulary.map(\.tag)
            && a.tagVocabulary.map(\.count) == b.tagVocabulary.map(\.count)
            && a.tag == b.tag && a.retention == b.retention
            && a.inspector == b.inspector && a.problem == b.problem
    }

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
    /// Whether every selected row is already paused, so the control can say *Resume* instead of
    /// offering to pause what is resting.
    public let selectionIsPaused: Bool
    /// Whether every selected note is archived.
    public let selectionIsArchived: Bool
    /// The last bulk action, while it can still be put back.
    public let undoable: Undoable?
    /// What the reader has set aside. Read under the `suggested` filter, beside the suggestions.
    public let setAside: [IgnoredLemma]
    /// Every tag the reader has used, with how many notes carry it. **Empty until they tag
    /// something**, so the control is absent rather than present and useless.
    public let tagVocabulary: [(tag: String, count: Int)]
    /// The tag the list is narrowed to.
    public let tag: String?
    /// Delayed recall, **with its denominator**, or nil when nothing has been eligible yet.
    public let retention: Retention?
    /// The one row the reader has open, when exactly one is selected. **Nil for none and for
    /// several**: an inspector over a multiple selection has to choose a row to edit and the reader
    /// cannot see which one it chose.
    public let inspector: Inspector?
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
                selectionIsPaused: Bool = false, selectionIsArchived: Bool = false,
                undoable: Undoable? = nil, setAside: [IgnoredLemma] = [],
                tagVocabulary: [(tag: String, count: Int)] = [], tag: String? = nil,
                retention: Retention? = nil,
                inspector: Inspector? = nil, problem: String? = nil) {
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
        self.selectionIsPaused = selectionIsPaused
        self.selectionIsArchived = selectionIsArchived
        self.undoable = undoable
        self.setAside = setAside
        self.tagVocabulary = tagVocabulary
        self.tag = tag
        self.retention = retention
        self.inspector = inspector
        self.problem = problem
    }

    /// What the last bulk action was, so the control can name it.
    ///
    /// **A case with a count, not a sentence.** The reader has to know what pressing it reaches
    /// before they press it, and reader-facing words belong in the catalog.
    public enum Undoable: Sendable, Equatable {
        case pause(Int)
        case archive(Int)

        var name: LocalizedStringKey {
            switch self {
            case .pause(let count): "Undo pausing \(count)"
            case .archive(let count): "Undo archiving \(count)"
            }
        }
    }

    /// Delayed recall and what it was measured over.
    ///
    /// **The denominator travels with the rate**, always. A percentage with nothing beside it is
    /// the one figure here that cannot be checked afterwards, and the type is what stops a surface
    /// printing it alone.
    public struct Retention: Sendable, Equatable {
        public let attempts: Int
        public let successes: Int
        public let cards: Int

        public var rate: Double { Double(successes) / Double(attempts) }

        /// **Nil over an empty denominator**, so there is nothing to draw rather than a 0% nobody
        /// measured.
        public init?(attempts: Int, successes: Int, cards: Int) {
            guard attempts > 0 else { return nil }
            self.attempts = attempts
            self.successes = successes
            self.cards = cards
        }
    }

    /// One review, as the audit trail shows it.
    public struct ReviewMark: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let at: Date
        public let grade: Grade
        /// **Said, not filtered out.** Practice moved no schedule and enters no retention figure,
        /// and a trail that hid it would be a trail that disagrees with the reader's memory.
        public let isPractice: Bool
        /// Taken back. Shown, struck through — an audit trail that hides what was undone is not one.
        public let isVoided: Bool

        public init(id: UUID, at: Date, grade: Grade, isPractice: Bool, isVoided: Bool) {
            self.id = id
            self.at = at
            self.grade = grade
            self.isPractice = isPractice
            self.isVoided = isVoided
        }
    }

    /// One reading, as the audit trail shows it.
    public struct ReadingMark: Sendable, Equatable, Identifiable {
        public let id: Int
        public let at: Date
        public let sentence: String
        public let source: String?

        public init(id: Int, at: Date, sentence: String, source: String?) {
            self.id = id
            self.at = at
            self.sentence = sentence
            self.source = source
        }
    }

    /// One row, open for editing.
    ///
    /// **`isReaders` is the load-bearing field.** A reader looking at a definition needs to know
    /// whether they are about to replace the publisher's words with their own for the first time
    /// or edit something they already wrote, and the two read identically without it.
    public struct Inspector: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let word: String
        public let answer: String
        /// Whether the answer shown is the reader's own rather than the dictionary's.
        public let isReaders: Bool
        public let tags: [String]
        /// **Two lists, never merged** (M05). A reading is something the reader did with a text; a
        /// review is something they did with a card.
        public let readings: [ReadingMark]
        public let reviews: [ReviewMark]

        public init(id: UUID, word: String, answer: String, isReaders: Bool,
                    tags: [String] = [], readings: [ReadingMark] = [],
                    reviews: [ReviewMark] = []) {
            self.id = id
            self.word = word
            self.answer = answer
            self.isReaders = isReaders
            self.tags = tags
            self.readings = readings
            self.reviews = reviews
        }
    }

    /// The sidebar's states, as one control. **Archived and paused are here**, because the library is
    /// where a reader goes to find what they put away.
    public enum Filter: String, Sendable, CaseIterable {
        case all, due, needsAttention, struggling, paused, archived, suggested

        public var name: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .due: "Due"
            case .needsAttention: "Needs attention"
            case .struggling: "Struggling"
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
