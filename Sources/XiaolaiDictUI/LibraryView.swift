import Foundation
import ReviewKit
import StudyKit
import StudyPresentation
import SwiftUI

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
    /// The caret in the tag field.
    @FocusState private var tagFocused: Bool
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
            .focused($tagFocused)
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
                ForEach(LibraryPresentation.ReadingLine.lines(of: inspector.readings)) { line in
                    let reading = line.mark
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: reading.sentence)
                            .font(.system(size: scale.text.small))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                            Text(reading.at, format: .dateTime.year().month().day())
                            if let source = reading.source { Text(verbatim: source) }
                            // The card's own way of saying it was met more than once.
                            if line.times > 1 {
                                Text(verbatim: "×\(line.times)")
                                    .accessibilityLabel(Text("^[\(line.times) reading](inflect: true)"))
                            }
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
    /// **Tagging, from where the other selection actions are.** The field is in the inspector and
    /// the inspector can be closed, which left a tag with no route to it at all. This selects what
    /// was clicked — the field labels the selection — opens the inspector and hands it the caret.
    private func beginTagging(_ ids: Set<UUID>) {
        if ids != state.selection { act(.select(ids)) }
        inspectorShown = true
        takeTagFocus(attemptsLeft: Token.Library.focusAttempts)
    }

    /// **Asked until it takes, a bounded number of times.** A field in a column that is still
    /// sliding in refuses the caret, and `FocusState` reads back false when it does: set once in
    /// `onAppear`, and once more a turn later, the collection kept the keyboard both times and
    /// the Return meant for the tag closed the inspector instead (E2E Mac, 2026-10-02). Nor can
    /// it wait for the field's `onAppear`: a closed inspector's content has already appeared, so
    /// opening it again fires nothing. Asked from the action itself, whichever way it started.
    private func takeTagFocus(attemptsLeft: Int) {
        tagFocused = true
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Token.Library.focusInterval) {
            if !tagFocused { takeTagFocus(attemptsLeft: attemptsLeft - 1) }
        }
    }

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
        // **Counted by what it changes**, not by the selection: the model confirms only these.
        let confirming = target.confirmable.count
        if confirming > 0 {
            IconButton(.confirmMeaning, title: "Confirm ^[\(confirming) Meaning](inflect: true)", size: size) { perform(.confirm, on: target.ids) }
        }
        // **A sitting over the selection, in Review** (review-module-plan §8.2) — counted by what it
        // can ask, as listed or in a random order. The rest of the selection goes too, and the end of
        // the sitting says why each was left out. **Disabled, with the reason as its name, when
        // nothing selected can be asked**: a menu row has no tooltip, so the name has to say it.
        let reviewing = target.reviewable.count
        if reviewing > 0 {
            IconButton(.reviewSelected, title: "Review ^[\(reviewing) Meaning](inflect: true)",
                       hint: "as they are listed; due ones are scheduled, the rest are practice",
                       shortcut: KeyboardShortcut("r", modifiers: .command), size: size) {
                perform(.reviewSelected(.asListed), on: target.ids)
            }
            IconButton(.reviewShuffled, title: "Review ^[\(reviewing) Meaning](inflect: true) in Random Order",
                       shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]), size: size) {
                perform(.reviewSelected(.shuffled), on: target.ids)
            }
        } else if target.heldBack > 0 {
            // **Waiting, not wrong** (WI-8): today's allowance of new meanings is spent, and a sitting
            // over these would ask nothing. Said as the sitting's end says it, so the two agree.
            IconButton(.reviewSelected, title: "New Meanings Wait Until Tomorrow",
                       help: Text("""
                                  Today's new meanings have all been introduced. \
                                  ^[\(target.heldBack) new meaning](inflect: true) will be introduced tomorrow.
                                  """),
                       size: size, isEnabled: false) {}
        } else {
            IconButton(.reviewSelected, title: "Nothing Selected Can Be Reviewed Now",
                       help: Text("""
                                  Each selected meaning is paused, put off, archived, waiting for you in \
                                  Needs Attention, or saved under another study dictionary.
                                  """),
                       size: size, isEnabled: false) {}
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
        // An ellipsis: it needs the tag typed before anything happens.
        IconButton(.addTag, title: "Tag ^[\(count) Meaning](inflect: true)…", size: size) { beginTagging(target.ids) }
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
    /// The ones confirming would change — what Confirm counts and reaches.
    let confirmable: Set<UUID>
    /// The ones a Selected sitting could ask now — what Review Selected counts.
    var reviewable: Set<UUID> = []
    /// The new meanings among them today's allowance would hold back — what a disabled Review Selected
    /// names as its reason.
    var heldBack = 0
}

extension LibraryPresentation {
    /// The selection, as the toolbar acts on it.
    var selectionTarget: LibrarySelectionTarget {
        LibrarySelectionTarget(ids: selection, isPaused: selectionIsPaused, isArchived: selectionIsArchived,
                               confirmable: confirmable, reviewable: reviewable, heldBack: reviewHeldBack)
    }

    /// What a right-click on `row` acts on: the selection when the row is part of it, and the row
    /// alone when it is not — described from the row itself, since the selection's facts are about
    /// other cards.
    func target(of row: Row) -> LibrarySelectionTarget {
        guard !selection.contains(row.id) else { return selectionTarget }
        return LibrarySelectionTarget(ids: [row.id], isPaused: row.status == .paused,
                                      isArchived: row.status == .archived,
                                      confirmable: row.isConfirmable ? [row.id] : [],
                                      reviewable: row.isReviewable ? [row.id] : [],
                                      heldBack: row.review == .heldBack ? 1 : 0)
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
            StatusLabel(.unconfirmed, text: Text(status.name), size: scale.text.micro, prominence: .secondary)
        case .needsRepair:
            StatusLabel(.caution, text: Text(status.name), size: scale.text.micro, prominence: .secondary)
        case .paused, .archived, .ignored:
            Label { Text(status.name) } icon: { status.action.image }
                .font(.system(size: scale.text.micro))
                .foregroundStyle(.secondary)
        }
    }
}
