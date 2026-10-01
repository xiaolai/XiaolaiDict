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
///
/// **A pane of the Library window, with no split view of its own.** Its filters are a section of
/// the window's sidebar; the branch that gave it a sidebar had no caller and still carried
/// `backgroundExtensionEffect`, which the window had already decided against (deleted 2026-10-02).
public struct LibraryView: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    public let state: LibraryPresentation
    public let act: @MainActor (LibraryAction) -> Void

    private let layout: LibraryLayout
    private let chooseLayout: @MainActor (LibraryLayout) -> Void
    @Binding private var inspectorShown: Bool
    @State private var interaction = LibraryCollectionInteraction<UUID>()
    private var revealed: Set<UUID> { interaction.revealed }
    @State private var tag = ""
    /// What is typed in the search field. See `LibrarySearch` for why it is not the model's copy.
    @State private var searchText = ""
    /// A removal that cannot be taken back, waiting for the reader to say they mean it.
    @State private var pending: PendingRemoval?
    /// The inspector's editor, held here rather than in the model: an in-progress edit is not
    /// state the ledger has any business knowing about until the reader saves it.
    @State private var draft = ""

    public init(state: LibraryPresentation, layout: LibraryLayout = .grid,
                chooseLayout: @escaping @MainActor (LibraryLayout) -> Void = { _ in },
                inspectorShown: Binding<Bool> = .constant(true),
                act: @escaping @MainActor (LibraryAction) -> Void) {
        self.layout = layout
        self.chooseLayout = chooseLayout
        _inspectorShown = inspectorShown
        self.state = state
        self.act = act
    }

    public var body: some View {
        Group {
            if state.filter == .suggested { suggestions }
            else if state.rows.isEmpty { empty }
            else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **The reader's to open and close**, and it stays as they left it. Selecting a card no
        // longer opens it, and closing it no longer lets go of the card.
        .inspector(isPresented: $inspectorShown) { inspectorColumn }
        .modifier(LibraryPaneChrome(showsNotice: state.problem != nil || state.exported != nil) { notice })
        // **The system's chrome, not a row of our own.** The title, the search field and the two
        // filters were drawn as content with a `Divider` under them — the pre-Big Sur shape, and
        // the reason this window read as old beside Notes or Finder. A real toolbar is also what
        // insets the sidebar: on macOS 26 and later `NavigationSplitView` gives its sidebar
        // floating Liquid Glass, and the detail's safe area is what it floats against.
        .navigationSubtitle(tally)
        .modifier(LibrarySearch(text: $searchText, current: state.search, prompt: "Search Saved") { act(.search($0)) })
        .toolbar {
            // Suggested is a plain list of words, with nothing to arrange.
            if state.filter != .suggested {
                LibraryLayoutToolbar(layout: layout, choose: chooseLayout)
            }
            LibrarySelectionToolbar(count: state.selection.isEmpty ? nil : LibrarySelectionCount(cards: state.selection.count)) {
                selectionActions(state.selectionTarget, inToolbar: true)
            }
            // **Apart from the selection's group**, because putting a bulk action back is not an
            // operation on whatever happens to be selected now.
            LibraryUndoToolbar(title: state.undoable?.name) { act(.undo) }
            // **A toolbar item of its own, because it acts on the collection and not on a
            // selection.** Beside the selection's own buttons it read as one of them.
            ToolbarItem {
                Button { act(.export) } label: { ActionSymbol.export.label }
                    .help("Export every saved meaning to a file in Downloads")
            }
            // **Absent until there is something to pick.** A tag menu over no tags is a control
            // that cannot do anything, which reads as one that is broken. Hidden under Suggested,
            // which has no tags: a control that appears to narrow what is on screen and silently
            // narrows something else is worse than one that refuses a click.
            if !state.tagVocabulary.isEmpty, state.filter != .suggested {
                ToolbarItem {
                    Picker("Tag", selection: Binding(
                        get: { state.tag },
                        set: { act(.filterTag($0)) })) {
                        Text("Any Tag").tag(String?.none)
                        ForEach(state.tagVocabulary) { entry in
                            Text(verbatim: "\(entry.tag) (\(entry.count))").tag(String?.some(entry.tag))
                        }
                    }
                    .help("Show only meanings with one tag")
                }
            }
            LibraryInspectorToolbar(isShown: $inspectorShown)
        }
        // **Asked first, because neither can be taken back.** Both ran on one click of an icon
        // that sat a few points from Archive and Pause in the same grey. The button is the
        // title's own verb, and Cancel is there.
        .confirmationDialog(pending?.title ?? Text(verbatim: ""), isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { removal in
                Button(role: .destructive) {
                    perform(removal.kind == .removeFromSaved ? .removeFromStudy : .deleteReading, on: removal.ids)
                } label: { removal.kind == .removeFromSaved ? Text("Remove") : Text(ActionSymbol.deletePermanently.title) }
                Button("Cancel", role: .cancel) {}
            } message: { removal in removal.message }
    }

    // MARK: - The one row that is open

    /// The inspector column: the open row, or what to do to open one.
    @ViewBuilder private var inspectorColumn: some View {
        if let inspector = state.inspector {
            self.inspector(inspector)
        } else if state.selection.isEmpty || state.filter == .suggested {
            LibraryInspectorPlaceholder(title: Text("No Selection"),
                                        description: Text("Select a meaning to see its details"))
        } else {
            // Several: nothing to show of any one of them, and the one thing that is done to
            // several at once here rather than from the toolbar — a tag needs typing.
            ContentUnavailableView {
                Text("^[\(state.selection.count) Meaning](inflect: true) Selected")
            } description: {
                Text("Select one meaning to see its details")
            } actions: {
                tagField
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(LibraryInspectorColumn())
        }
    }

    /// Labels the selection. **In the inspector**, where there is room to type; it was a bare
    /// field wedged among icons in the corner pill.
    private var tagField: some View {
        TextField("Add a tag", text: $tag)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: Token.Library.tagWidth)
            .onSubmit {
                act(.tag(tag))
                tag = ""
            }
    }

    /// **The answer, and the reader's right to replace it.**
    ///
    /// Behind the same reveal the review surface uses: a reader tidying their collection is not reviewing it,
    /// and a pane that prints the meaning of whatever they click would teach them the answer on the
    /// way past. Once they have asked, it is an editor rather than a label — replacing the
    /// publisher's words with their own is the point, not a hidden capability.
    @ViewBuilder
    private func inspector(_ inspector: LibraryPresentation.Inspector) -> some View {
        // **The lemma's colour**, so the word is the colour here that it is in History, the drawer
        // and the lookup card. Hashing the word as it was written made *meeting* orange in this
        // pane and pink in the one beside it.
        let accent = ReadingPalette.color(forLemma: inspector.accentKey, in: scheme, contrast: contrast)
        LibraryInspector(accent: accent) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: inspector.word)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                    .foregroundStyle(accent)
                // **Whose words these are**, because replacing the publisher's for the first time
                // and editing your own read identically without it.
                Text(inspector.isReaders ? "Your own answer" : "From the dictionary")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if revealed.contains(inspector.id) {
                TextField("Your answer", text: $draft, axis: .vertical)
                    .lineLimit(Token.Limit.answerLinesAtLeast...Token.Limit.answerLinesAtMost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: scale.text.small))
                HStack(spacing: scale.space.inline) {
                    IconButton(.saveAnswer, isEnabled: canSave(inspector)) { act(.setAnswer(noteID: inspector.id, text: draft)) }
                    // **Said, not merely disabled.** A button that refuses a click without a reason
                    // is a broken switch, and "blank" is not guessable from a greyed-out control.
                    if isDraftBlank {
                        Text("An answer cannot be blank.")
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                switch inspector.closedAnswer {
                case .reveal:
                    IconButton(.showMeaning) { interaction.revealed.insert(inspector.id) }
                case .write:
                    // **A remedy beside the diagnosis.** The editor was reachable only through the
                    // reveal, so the one answer that most needed writing could never be written.
                    // There is nothing here to give away, so opening the editor teaches nothing early.
                    Text("No meaning is recorded for this one yet.")
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                    IconButton(.writeAnswer) { interaction.revealed.insert(inspector.id) }
                }
            }
            HStack(spacing: scale.space.inline) {
                ForEach(inspector.tags, id: \.self) { tag in
                    // **Readable and removable.** A label the reader can add and never take
                    // off is a worse state than having no labels.
                    Button { act(.untag(noteID: inspector.id, tag: tag)) } label: { Text(verbatim: tag) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(Text("Remove this tag"))
                }
                tagField
                Spacer(minLength: 0)
            }
            // **In the inspector's own scroll view, at their full length.** They had a second
            // scroll view of their own, 220 pt tall, inside the one the column already is.
            timeline(inspector)
        }
        // **Reset when the row changes, never carried.** A draft left over from the previous
        // selection would be saved onto this word the moment the reader pressed the button.
        //
        // **And only when the row changes.** Following the stored answer as well meant the save
        // the reader had just made came back and overwrote whatever they had typed since — the
        // edit they were in the middle of, replaced by the edit before it.
        .onChange(of: inspector.id, initial: true) { draft = inspector.answer }
    }

    /// **Where it was met, and what was done with the card — in two lists** (M05).
    ///
    /// Never interleaved. A reading is something the reader did with a text and a review is
    /// something they did with a card; one sequence invites reading a grade as evidence about the
    /// sentence beside it.
    ///
    /// **One above the other, and the sentence on a line of its own.** Side by side in a 312 pt
    /// column the date wrapped to "Oct 1, / 2026", the sentence was cut to "The / meeti…" and the
    /// source broke mid-word (seen 2026-10-01): the reader's own sentence, unreadable in the one
    /// place that lists where the word was met. The sentence is not cut short here at all.
    @ViewBuilder
    private func timeline(_ inspector: LibraryPresentation.Inspector) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("Where You Met It")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                if inspector.readings.isEmpty {
                    Text("No reading is recorded.")
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
                }
                ForEach(inspector.readings) { reading in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: reading.sentence)
                            .font(.system(size: scale.text.small))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                            Text(reading.at, format: .dateTime.year().month().day())
                            if let source = reading.source { Text(verbatim: source) }
                        }
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("Your Reviews")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                if inspector.reviews.isEmpty {
                    Text("Not reviewed yet.")
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
                }
                ForEach(inspector.reviews) { review in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                        Text(review.at, format: .dateTime.year().month().day())
                            .font(.system(size: scale.text.micro))
                            .foregroundStyle(.secondary)
                        Text(review.grade.readerName)
                            .font(.system(size: scale.text.micro))
                        // **Said, not filtered out**: practice moved nothing, and an undone
                        // attempt is still part of the trail.
                        if review.isPractice {
                            StatusLabel(.practice, "Practice", size: scale.text.micro, prominence: .secondary)
                        }
                        if review.isVoided {
                            Text("Undone")
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **One rule for blank**, because the Save button and the sentence under it must agree:
    /// two copies of the trimming predicate is a control that refuses a click while the label
    /// beside it says nothing is wrong.
    private var isDraftBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saveable when there is something to save: not blank, and not what is already stored.
    private func canSave(_ inspector: LibraryPresentation.Inspector) -> Bool {
        !isDraftBlank && draft != inspector.answer
    }

    // MARK: - Finding

    private var list: some View {
        LibraryCollection(rows: state.rows, layout: layout, identifier: "library-saved-row",
                          selection: Binding(get: { state.selection }, set: { act(.select($0)) }),
                          interaction: $interaction,
                          keys: keys, more: more,
                          name: { Text(verbatim: $0.word) }) { row in
            LibraryRowView(row: row)
        } menu: { row in
            selectionActions(state.target(of: row), inToolbar: false)
        }
    }

    private var keys: LibraryCollectionKeys {
        var keys = LibraryCollectionKeys(toggleInspector: { inspectorShown.toggle() })
        // Archiving can be taken back, which is what makes it safe on a key.
        if !state.selectionIsArchived { keys.delete = { act(.archive) } }
        return keys
    }

    private var more: (@MainActor () -> Void)? {
        guard state.hasMore else { return nil }
        return { act(.showMore) }
    }

    /// **Offered, never saved from here.** An unopened suggestion costs the reader nothing, and
    /// neither button here grades anything — "already know" is a declaration about this word, not a
    /// measurement of it.
    private var suggestions: some View {
        VStack(spacing: 0) {
            if state.suggestions.isEmpty {
                LibraryEmptyState {
                    ContentUnavailableView {
                        Label("No Suggestions Yet", systemImage: ActionSymbol.suggestedFilter.symbol)
                    } description: {
                        Text("A word you look up on more than one day appears here.")
                    }
                }
            } else {
                List(state.suggestions) { suggestion in
                    HStack(spacing: scale.space.inline) {
                        VStack(alignment: .leading, spacing: scale.space.tight) {
                            // **Named with its language**, because Save and "already know" both act
                            // on the lemma *and* the language: two homographs read as one row.
                            Text(verbatim: suggestion.language.isEmpty
                                 ? suggestion.lemma : "\(suggestion.lemma) · \(suggestion.language)")
                                .font(.system(size: scale.text.body, weight: .medium))
                            // The evidence, so the ranking is legible rather than trusted.
                            Text("Looked up on ^[\(suggestion.days) day](inflect: true), in ^[\(suggestion.sources) place](inflect: true)")
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        IconButton(.saveSuggestion, hint: "looks the word up so you can choose its meaning") {
                            act(.study(lemma: suggestion.lemma))
                        }
                        IconButton(.alreadyKnow, hint: "stops suggesting this word") {
                            act(.ignore(lemma: suggestion.lemma, language: suggestion.language))
                        }
                    }
                    .padding(.vertical, scale.space.tight)
                }
                .listStyle(.inset)
            }
            setAside
        }
    }

    /// **What the reader set aside, and the way back.** Setting a word aside enrols nothing, so
    /// there is no library row to find it by — without this list "already know" is a declaration
    /// that cannot be seen and therefore cannot be taken back.
    @ViewBuilder
    private var setAside: some View {
        if !state.setAside.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: scale.space.tight) {
                Text("Words You Already Know")
                    .font(.system(size: scale.text.micro, weight: .medium))
                    .foregroundStyle(.secondary)
                // Scrollable because this list grows without bound, and the oldest "Offer Again"
                // went off the bottom of the window.
                ScrollView {
                    VStack(alignment: .leading, spacing: scale.space.tight) {
                        ForEach(state.setAside) { lemma in
                            HStack(spacing: scale.space.inline) {
                                // **With its language**, because the action is keyed by both:
                                // English and French *pain* are two rows that read as one.
                                Text(verbatim: lemma.language.isEmpty
                                     ? lemma.lemma : "\(lemma.lemma) · \(lemma.language)")
                                    .font(.system(size: scale.text.small))
                                Spacer(minLength: 0)
                                IconButton(.offerAgain) {
                                    act(.unignore(lemma: lemma.lemma, language: lemma.language))
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Token.Library.setAsideHeight)
            }
            .padding(scale.space.padAcross)
        }
    }

    /// **Two different nothings**, said differently: a reader who has saved nothing is not a
    /// reader whose search found nothing.
    ///
    /// **Every narrowing counts, not only the search.** The tag picker and the filter also hide
    /// rows, and ignoring them told a reader with a full collection that they had saved nothing —
    /// over a filter they could still see set.
    private var empty: some View {
        LibraryEmptyState {
            if state.isUnfiltered {
                ContentUnavailableView {
                    Label("Nothing Saved Yet", systemImage: ActionSymbol.savedPane.symbol)
                } description: {
                    Text("A meaning you save while reading appears here.")
                }
            } else if !state.search.isEmpty, state.tag == nil, state.filter == .all {
                // The search alone: the system's own words for it, naming what was looked for.
                ContentUnavailableView.search(text: state.search)
            } else {
                ContentUnavailableView {
                    Label("Nothing Matches", systemImage: state.filter.action.symbol)
                } description: {
                    Text("No saved meaning passes everything this list is narrowed by.")
                } actions: {
                    // **Only the narrowings that are actually on.** "Clear Search" over an empty
                    // search is a recovery button that changes nothing, which is the same broken
                    // switch as one that refuses its click.
                    HStack(spacing: scale.space.inline) {
                        if !state.search.isEmpty {
                            IconButton(.clearSearch) { searchText = "" }
                        }
                        if state.tag != nil {
                            IconButton(.showEveryTag) { act(.filterTag(nil)) }
                        }
                        if state.filter != .all {
                            IconButton(.showEverything) { act(.filter(.all)) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Changing

    /// **Above every branch, because a failure is not a state of the list.** `problem` was drawn
    /// only by the empty view, so a database error under the Suggested filter — or one that arrived
    /// while rows were on screen — read as "Nothing to suggest yet", or as nothing at all.
    @ViewBuilder private var notice: some View {
        if state.problem != nil || state.exported != nil {
            LibraryNotice {
                if let problem = state.problem {
                    StatusLabel(.error, text: Text(verbatim: problem), prominence: .secondary).textSelection(.enabled)
                    IconButton(.retry) { act(.retry) }
                }
                if let exported = state.exported {
                    // The path, because an export the reader cannot find did not happen for them.
                    Text(verbatim: exported)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: exported))
                }
            }
        }
    }

    /// What the reader is looking at, and how well they are remembering it — the window's subtitle.
    private var tally: Text {
        let meanings = Text("^[\(state.total) meaning](inflect: true)")
        // **The denominator, always beside the rate** (U03). A percentage on its own is the
        // one figure here nobody can check afterwards, and absent is what it is when there
        // has been nothing eligible to measure.
        guard let retention = state.retention else { return meanings }
        let recalled = Text("\(retention.rate, format: .percent.precision(.fractionLength(0))) recalled, over ^[\(retention.attempts) review](inflect: true)")
        return Text("\(meanings) · \(recalled)")
    }

    /// Selects `ids` if they are not what is selected, then acts. **A right-click on a card outside
    /// the selection acts on that card**, as it does in Finder, and the model acts on its own
    /// selection — so the selection is moved first, and the count on the menu row is the count the
    /// action reaches.
    private func perform(_ action: LibraryAction, on ids: Set<UUID>) {
        if ids != state.selection { act(.select(ids)) }
        act(action)
    }

    /// What can be done to `target`, each control named for what it will do to *this* one.
    ///
    /// **One builder for the toolbar and the right-click menu.** They were written twice and had
    /// drifted: the menu offered Pause and Resume together where the footer chose one, had no
    /// Confirm, Unarchive or Delete, and said "Remove from study 1" where the footer said "Remove 1
    /// from study".
    @ViewBuilder private func selectionActions(_ target: LibrarySelectionTarget, inToolbar: Bool) -> some View {
        let size: CGFloat? = inToolbar ? Token.Library.toolbarGlyph : nil
        let count = target.ids.count
        if target.canConfirm {
            IconButton(.confirmMeaning, title: "Confirm ^[\(count) Meaning](inflect: true)", size: size) { perform(.confirm, on: target.ids) }
        }
        // **Named for what it will do to this selection.** A Pause button over rows that
        // are all resting is a control whose label is wrong before it is pressed.
        if target.isPaused {
            IconButton(.resume, title: "Resume ^[\(count) Meaning](inflect: true)", size: size) { perform(.resume, on: target.ids) }
        } else {
            IconButton(.pause, title: "Pause ^[\(count) Meaning](inflect: true)", size: size) { perform(.pause, on: target.ids) }
        }
        if target.isArchived {
            IconButton(.unarchive, title: "Unarchive ^[\(count) Meaning](inflect: true)", size: size) { perform(.unarchive, on: target.ids) }
        } else {
            IconButton(.archive, title: "Archive ^[\(count) Meaning](inflect: true)",
                       hint: inToolbar ? "or press Delete" : nil, size: size) { perform(.archive, on: target.ids) }
        }
        // **Two different deletions, named apart.** Removing from Saved keeps the reading;
        // deleting the readings keeps the meaning. A single "Delete" would mean whichever the
        // reader assumed. Each ends in an ellipsis because each asks before it acts.
        IconButton(.removeFromSaved, title: "Remove ^[\(count) Meaning](inflect: true) from Saved…", size: size) {
            pending = PendingRemoval(kind: .removeFromSaved, ids: target.ids)
        }
        IconButton(.deletePermanently, title: "Delete the Readings Behind ^[\(count) Meaning](inflect: true)…",
                   hint: "keeps what is saved and deletes the sentences it was saved from", size: size) {
            pending = PendingRemoval(kind: .deleteReadings, ids: target.ids)
        }
    }
}

/// A removal waiting on the reader's confirmation, with the cards it will reach.
struct PendingRemoval: Identifiable, Equatable {
    enum Kind: Equatable { case removeFromSaved, deleteReadings }
    let kind: Kind
    let ids: Set<UUID>
    var id: Set<UUID> { ids }

    var title: Text {
        switch kind {
        case .removeFromSaved: Text("Remove ^[\(ids.count) meaning](inflect: true) from Saved?")
        case .deleteReadings: Text("Delete the readings behind ^[\(ids.count) meaning](inflect: true) permanently?")
        }
    }

    var message: Text {
        switch kind {
        case .removeFromSaved:
            Text("The readings stay in History, but review progress is lost. This cannot be undone.")
        case .deleteReadings:
            Text("What is saved stays in Saved, but loses the sentences it was saved from and will need attention. This cannot be undone.")
        }
    }
}

/// The cards an action will reach, and what they are — so a control can be named for what it will
/// do to exactly them.
struct LibrarySelectionTarget: Equatable {
    let ids: Set<UUID>
    /// Every one is paused, so the control says Resume.
    let isPaused: Bool
    /// Every one is archived, so the control says Unarchive.
    let isArchived: Bool
    /// At least one is waiting for the reader to confirm its meaning.
    let canConfirm: Bool
}

extension LibraryPresentation {
    /// The selection, as the toolbar acts on it.
    var selectionTarget: LibrarySelectionTarget {
        LibrarySelectionTarget(ids: selection, isPaused: selectionIsPaused, isArchived: selectionIsArchived,
                               canConfirm: canConfirm)
    }

    /// What a right-click on `row` acts on: the selection when the row is part of it, and the row
    /// alone when it is not — described from the row itself, since the selection's facts are about
    /// other cards.
    func target(of row: Row) -> LibrarySelectionTarget {
        guard !selection.contains(row.id) else { return selectionTarget }
        return LibrarySelectionTarget(ids: [row.id], isPaused: row.status == .paused,
                                      isArchived: row.status == .archived,
                                      canConfirm: row.status == .needsConfirmation)
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
    @Environment(\.colorSchemeContrast) private var contrast
    let row: LibraryPresentation.Row

    /// **Keyed by the lemma, as History, the drawer and the lookup card key it.** Hashing the word
    /// as written gave one reading two colours in two panes of one window.
    private var accent: Color { ReadingPalette.color(forLemma: row.accentKey, in: scheme, contrast: contrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                // The same face as a History or Review card's word: one reading, one look.
                Text(verbatim: row.word)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                    .foregroundStyle(accent)
                if let status = row.status { mark(status) }
                Spacer(minLength: 0)
                if let due = row.due {
                    Text(verbatim: due)
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
                }
            }
            if !row.excerpt.isEmpty {
                ReadingSentence(sentence: row.excerpt, ranges: row.marks, accent: accent)
            }
            HStack(spacing: scale.space.inline) {
                ReadingPronunciation(word: row.word, sentence: row.excerpt)
                Spacer(minLength: 0)
            }

        }
        .padding(scale.space.pad)
        .modifier(ReadingCardChrome(accent: CardSurface.border(accent: accent, contrast: contrast)))
    }

    /// **A symbol and ordinary text, never coloured text.** The status was orange words beside a
    /// word that could itself be orange, and orange on a light card measured about 2.2:1. What
    /// needs the reader is marked as a question or a caution; what is merely put away wears the
    /// symbol of the filter that lists it.
    @ViewBuilder private func mark(_ status: LibraryPresentation.Status) -> some View {
        switch status {
        case .needsConfirmation:
            StatusLabel(.unconfirmed, status.name, size: scale.text.micro, prominence: .secondary)
        case .needsRepair:
            StatusLabel(.caution, status.name, size: scale.text.micro, prominence: .secondary)
        case .paused, .archived, .ignored:
            Label { Text(status.name) } icon: { status.action.image }
                .font(.system(size: scale.text.micro))
                .foregroundStyle(.secondary)
        }
    }
}

public enum LibraryAction: Sendable, Equatable {
    case retry
    case search(String)
    /// One more page. **Grown, not offset**: a card enrolled while the reader is reading must not
    /// shift a boundary underneath them.
    case showMore
    /// The reader agrees these are the meanings they met. The library showed "Confirm the meaning"
    /// as a status with no way to act on it — a diagnosis with no remedy.
    case confirm
    case filter(LibraryPresentation.Filter)
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
    /// **The other deletion** (ADR-0033), and never the same as the one above: this keeps the
    /// card and takes the reading that evidences it, leaving the note repairable. The ledger had
    /// it from the start and nothing offered it, so tidying reading history meant losing cards.
    case deleteReading
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
    /// **A tag and how many notes carry it.** A named type rather than a tuple, because a tuple
    /// is not `Equatable` — which forced a hand-written `==` over every stored property of the
    /// presentation, and a hand-written one that forgets a property is a view that stops
    /// redrawing for a change it cannot see. The compiler writes it now.
    public struct TagUse: Sendable, Equatable, Identifiable {
        public let tag: String
        public let count: Int
        public var id: String { tag }
        public init(tag: String, count: Int) { self.tag = tag; self.count = count }
    }

    public let rows: [Row]
    public let total: Int
    public let search: String
    public let filter: Filter
    public let selection: Set<UUID>
    /// Whether anything matched beyond what is listed.
    public let hasMore: Bool
    /// Whether the selection holds anything a confirmation would change.
    public let canConfirm: Bool

    /// Whether anything is narrowing the list. **Every narrowing**, so an empty result can only
    /// claim "you have saved nothing" when nothing is hiding rows.
    public var isUnfiltered: Bool {
        search.isEmpty && filter == .all && tag == nil
    }
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
    public let tagVocabulary: [TagUse]
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
                selection: Set<UUID> = [],
                hasMore: Bool = false, canConfirm: Bool = false,
                suggestions: [Suggestion] = [], exported: String? = nil,
                selectionIsPaused: Bool = false, selectionIsArchived: Bool = false,
                undoable: Undoable? = nil, setAside: [IgnoredLemma] = [],
                tagVocabulary: [TagUse] = [], tag: String? = nil,
                retention: Retention? = nil,
                inspector: Inspector? = nil, problem: String? = nil) {
        self.rows = rows
        self.total = total
        self.search = search
        self.filter = filter
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
            case .pause(let count): "Undo Pausing ^[\(count) Meaning](inflect: true)"
            case .archive(let count): "Undo Archiving ^[\(count) Meaning](inflect: true)"
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
        /// What the word's colour is hashed from: the lemma, the same key its row uses.
        public let accentKey: String
        public let answer: String
        /// Whether the answer shown is the reader's own rather than the dictionary's.
        public let isReaders: Bool
        public let tags: [String]
        /// **Two lists, never merged** (M05). A reading is something the reader did with a text; a
        /// review is something they did with a card.
        public let readings: [ReadingMark]
        public let reviews: [ReviewMark]

        public init(id: UUID, word: String, accentKey: String? = nil, answer: String, isReaders: Bool,
                    tags: [String] = [], readings: [ReadingMark] = [],
                    reviews: [ReviewMark] = []) {
            self.id = id
            self.word = word
            self.accentKey = accentKey ?? word
            self.answer = answer
            self.isReaders = isReaders
            self.tags = tags
            self.readings = readings
            self.reviews = reviews
        }

        /// What the answer area offers before the reader has opened it.
        public enum ClosedAnswer: Sendable, Equatable {
            /// There is an answer, and it stays unseen until asked for.
            case reveal
            /// There is none to hide, so the control is the editor's door.
            case write
        }

        /// Blank by the Save button's own rule, `.whitespacesAndNewlines`, so a stored answer of
        /// only an ideographic space is offered for writing rather than revealed as nothing.
        public var closedAnswer: ClosedAnswer {
            answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .write : .reveal
        }
    }

    /// The sidebar's states, as one control. **Archived and paused are here**, because the library is
    /// where a reader goes to find what they put away.
    public enum Filter: String, Sendable, CaseIterable {
        case all, due, needsAttention, struggling, paused, archived, suggested

        /// The sidebar row's symbol and name, from the one table every symbol comes from — so a
        /// filter cannot wear a pane's symbol, as All wore Saved's and Due wore History's.
        public var action: ActionSymbol {
            switch self {
            case .all: .allFilter
            case .due: .dueFilter
            case .needsAttention: .needsAttentionFilter
            case .struggling: .strugglingFilter
            case .paused: .pausedFilter
            case .archived: .archivedFilter
            case .suggested: .suggestedFilter
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

        /// The mark beside the name: the symbol of the list this state puts the card in.
        var action: ActionSymbol {
            switch self {
            case .needsConfirmation, .needsRepair: .needsAttentionFilter
            case .paused: .pausedFilter
            case .archived: .archivedFilter
            case .ignored: .alreadyKnow
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let word: String
        /// What the word's colour is hashed from: **the lemma**, as on every other surface.
        public let accentKey: String
        public let excerpt: String
        /// Where the word sits in `excerpt` — `LibraryRow.excerptMarks`, decided below the view.
        public let marks: [NSRange]
        /// The answer, which the row shows only when the reader asks.
        public let answer: String
        /// Why it is not being asked, where it is not. Nil when it is simply due or waiting.
        ///
        /// **A case, not a string.** Reader-facing text belongs in the catalog, and a model that
        /// carried the sentence would be a model choosing the words.
        public let status: Status?
        /// When it comes back, in the reader's words.
        public let due: String?

        public init(id: UUID, word: String, accentKey: String? = nil, excerpt: String, marks: [NSRange],
                    answer: String, status: Status?, due: String?) {
            self.id = id
            self.word = word
            // The word itself where no lemma was recorded — a card the reader wrote, which was
            // never looked up.
            self.accentKey = accentKey ?? word
            self.excerpt = excerpt
            self.marks = marks
            self.answer = answer
            self.status = status
            self.due = due
        }
    }
}
