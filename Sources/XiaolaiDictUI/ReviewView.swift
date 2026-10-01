import Foundation
import SwiftUI
import XiaolaiDictCore

/// **The review surface: the reader's own sentence, and a question about it.**
///
/// C2, which is the whole design: *a review surface never answers the question unasked*. Here that is
/// structural rather than remembered — `answer` is nil until the reader asks, so before the reveal the
/// answer is not in the view, not in the layout, and not in the accessibility tree. There is nothing to
/// hide because there is nothing here.
///
/// Nothing reserves space for it either. A gap the size of a definition is the definition's shape, and
/// a reader who can see how long the answer is has been told something about it.
public struct ReviewView: View {
    @Environment(\.scale) private var scale
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    public let state: ReviewPresentation
    /// What the reader did. The view decides nothing: it reports, and the model commits.
    public let act: @MainActor (ReviewAction) -> Void
    /// Goes to the saved meanings that are waiting to be confirmed. Nil where this view is shown
    /// outside the Library, which has nowhere to go.
    private let findUnconfirmed: (@MainActor () -> Void)?

    public init(state: ReviewPresentation, findUnconfirmed: (@MainActor () -> Void)? = nil,
                act: @escaping @MainActor (ReviewAction) -> Void) {
        self.state = state
        self.findUnconfirmed = findUnconfirmed
        self.act = act
    }

    public var body: some View {
        switch state.stage {
        case .empty(let reason):
            // **Centred in the pane, like every other pane's nothing.** It sat in a
            // leading-aligned stack, so the message hugged the upper left of an empty window.
            LibraryEmptyState { emptyState(reason) }
        case .asking(let asking):
            sitting { card(asking) }
        case .finished(let summary):
            sitting {
                VStack(alignment: .leading, spacing: scale.space.stack) { finishedState(summary) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// **Scrollable, because the content is the reader's own writing.** A long sentence and a
    /// long answer shared a fixed stack with the controls, so past a certain length neither
    /// could be read to the end and the buttons went off the bottom of the window.
    private func sitting(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, scale.space.padAcross)
                .padding(.vertical, scale.space.padDown)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// **The word's colour comes from the curated palette**, chosen here rather than carried in from
    /// the model: a colour is a design value, and a model that held one would be deciding how the
    /// card looks. Hashed the same way the drawer hashes it, so one word is one colour everywhere.
    private func accent(for question: ReviewPresentation.Question) -> Color {
        // **The lemma, which is what the lookup and the drawer hash.** Hashing the captured
        // surface gave *ran* and *run* different colours on different surfaces, which is exactly
        // the consistency the comment above claims.
        ReadingPalette.color(forLemma: question.accentKey, in: scheme, contrast: contrast)
    }

    // MARK: - Asking

    /// **The question is a card, like every other reading in this window.** Review was a window of
    /// its own once, and the window was the card; as a pane of the Library its content sat bare on
    /// the background beside panes full of cards. The same paper, edge and lift as theirs, in the
    /// word's own colour, and edge to edge as a History card in a list is.
    ///
    /// Nothing here reserves room for the answer: the card is as tall as what it shows, and grows
    /// when the reader asks.
    private func card(_ question: ReviewPresentation.Question) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) { asking(question) }
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ReadingCardChrome(accent: CardSurface.border(accent: accent(for: question), contrast: contrast)))
    }

    /// **The front of a card, and its back only once asked for** — laid out as every other card in
    /// this window is: the word and a small detail beside it, the reader's sentence with the word
    /// marked, where it was met, and a last row with the voice on the left and what can be done on
    /// the right. The same components draw them, so a reading looks the same whether it is being
    /// browsed or asked.
    @ViewBuilder
    private func asking(_ question: ReviewPresentation.Question) -> some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: question.word)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                    .foregroundStyle(accent(for: question))
                Spacer(minLength: 0)
                // Where in the batch this is — the place the other cards give their date.
                Text("\(question.position) of \(question.batchSize)")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
            }
            // **The reader's own sentence, with the word marked** — the cue, and the only thing on
            // the front that is prose. A capture that produced no real sentence shows none rather
            // than the word echoed back and dressed as context. **The reader's emphasis setting**
            // goes through, as it does on the lookup card and the drawer.
            if let sentence = question.sentence {
                ReadingSentence(sentence: sentence.text, ranges: sentence.range.map { [$0] } ?? [],
                                accent: accent(for: question), emphasis: options.emphasis)
            }
            Text(verbatim: question.source)
                .font(.system(size: scale.text.micro))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // One line, so the whole of it is a pointer away.
                .help(Text(verbatim: question.source))
            if question.isPractice {
                StatusLabel(.practice, "Practice. Nothing is scheduled", size: scale.text.micro, prominence: .secondary)
            }
        }

        switch question.prompt {
        case .meaningHere:
            Text("What does this mean here?")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }

        // Present only after the reveal. Not hidden, not zero-height, not `.opacity(0)`: absent.
        if let answer = question.answer {
            revealed(answer)
        }

        controls(question)
    }

    @ViewBuilder
    private func revealed(_ answer: ReviewPresentation.Answer) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text(verbatim: answer.text)
                .font(.system(size: scale.text.body))
                .textSelection(.enabled)
            if let dictionary = answer.dictionary {
                // A card attributes its answer. The reader's own words are attributed to nobody,
                // which is why this is absent rather than saying "you".
                Text(verbatim: dictionary)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Icons, each with its key in its tooltip.** Space, 1, 2, S and T were bound and written
    /// down nowhere a reader could find; `shortcut:` binds the key and names it from one value.
    /// The grades are thumbs because `xmark` beside `checkmark` reads as Cancel and OK.
    @ViewBuilder
    private func controls(_ question: ReviewPresentation.Question) -> some View {
        // **Disabled while a grade is committing**, every one of them: a reveal started then could
        // finish after the sitting had advanced and put this card's answer on the next one.
        let ready = !question.isCommitting
        HStack(spacing: scale.space.inline) {
            // The word aloud is not its meaning, so the voice is on the front like any other card's.
            ReadingPronunciation(word: question.word, sentence: question.sentence?.text ?? "")
            if question.answer == nil {
                IconButton(.showMeaning, shortcut: KeyboardShortcut(.space, modifiers: []), isEnabled: ready) { act(.reveal) }
            }
            Spacer(minLength: 0)
            // **Forgot first, always.** The order is the same on every card, so a reader answering
            // quickly is answering the question and not hunting for the button.
            IconButton(.forgot, shortcut: KeyboardShortcut("1", modifiers: []), isEnabled: ready) { act(.grade(.again)) }
            IconButton(.remembered, hint: "you recalled it before showing the meaning",
                       shortcut: KeyboardShortcut("2", modifiers: []), isEnabled: ready) { act(.grade(.good)) }
            IconButton(.skip, hint: "still due today; the next batch can have it",
                       shortcut: KeyboardShortcut("s", modifiers: []), isEnabled: ready) { act(.skip) }
            // **"Not Today" is not "Skip".** A skipped card comes back in this evening's next
            // batch; this one is gone until tomorrow, and the reader has to be able to say which
            // they mean.
            IconButton(.notToday, hint: "hidden until tomorrow; nothing about your memory is recorded",
                       shortcut: KeyboardShortcut("t", modifiers: []), isEnabled: ready) { act(.postpone) }
        }
        if let problem = question.problem {
            // **A failed write stays on screen.** The reader answered; if the ledger did not take it,
            // saying nothing would leave them believing it did.
            StatusLabel(.error, text: Text(verbatim: problem))
        }
    }

    // MARK: - The ends

    /// **One message, the pane's own symbol, and the next step as a button where there is one.**
    /// "Choose or confirm their meanings in Saved" was a sentence with no way to do it: the route
    /// was an unlabelled warning triangle in the far corner, there whether or not anything needed
    /// confirming.
    @ViewBuilder
    private func emptyState(_ reason: ReviewPresentation.Empty) -> some View {
        switch reason {
        case .nothingDue:
            ContentUnavailableView {
                Label("Nothing Due", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                Text("Saved meanings come back here when they are due.")
            }
        case .needsConfirmation(let count):
            ContentUnavailableView {
                Label("Meanings to Confirm", systemImage: ActionSymbol.findUnconfirmed.symbol)
            } description: {
                Text("^[\(count) saved meaning](inflect: true) cannot be reviewed until you choose or confirm what was meant.")
            } actions: {
                if let findUnconfirmed {
                    Button("Show in Saved") { findUnconfirmed() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("review-show-in-saved")
                }
            }
        case .nothingEnrolled:
            ContentUnavailableView {
                Label("Nothing Saved Yet", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                Text("Save a meaning while reading, and it comes back here when it is due.")
            }
        case .couldNotBeRead(let problem):
            ContentUnavailableView {
                Label("Saved Meanings Could Not Be Read", systemImage: ActionSymbol.failure.symbol)
            } description: {
                Text(verbatim: problem).textSelection(.enabled)
            } actions: {
                Button { act(.anotherBatch) } label: { Text(ActionSymbol.retry.title) }
            }
        case .heldBackUntilTomorrow(let count):
            ContentUnavailableView {
                Label("Nothing Due", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                // **The specific sentence instead of the general one**, never both: "they come back
                // when they are due" is a vaguer restatement of exactly this.
                Text("^[\(count) new meaning](inflect: true) will be introduced tomorrow.")
            }
        }
    }

    @ViewBuilder
    private func finishedState(_ summary: ReviewSession.Summary) -> some View {
        Text("\(summary.graded) reviewed")
            .font(.system(size: scale.text.heading, weight: .medium))
        // **Never "all done".** A batch bounds a sitting, not the reader's debt, and a surface that
        // hides the remainder teaches them it is smaller than it is.
        if summary.stillDue > 0 {
            Text("\(summary.stillDue) more due")
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
        }
        if summary.skipped > 0 {
            // **Practice includes cards that are not due at all**, so "still due" was a claim
            // about the schedule that a practice sitting cannot make.
            Text(summary.wasPractice ? "\(summary.skipped) skipped"
                                     : "\(summary.skipped) skipped, still due")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **A different sentence from "skipped".** One is still due this evening and the other is
        // not, and a reader who cannot tell them apart cannot plan the rest of the sitting.
        if summary.postponed > 0 {
            Text("\(summary.postponed) hidden until tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **Said, and said differently from "more due".** New words the day's allowance is holding
        // are not late; without this line a reader who saved thirty and answered five sees twenty-
        // five words go quiet with no explanation.
        if summary.heldBack > 0 {
            Text("^[\(summary.heldBack) new meaning](inflect: true) will be introduced tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        HStack(spacing: scale.space.inline) {
            // **Skipped cards are still due**, and were left out of `stillDue` — so skipping
            // the last batch ended the sitting with work outstanding and no way to go on.
            if summary.stillDue > 0 || summary.skipped > 0 {
                IconButton(.anotherBatch) { act(.anotherBatch) }
            }
            // **Offered when there is nothing due**, which is when a reader who wants to keep
            // going would otherwise have nothing to do but wait.
            if summary.stillDue == 0 && summary.skipped == 0 {
                IconButton(.practise, hint: "nothing is scheduled by it") { act(.practise) }
            }
            IconButton(.done, shortcut: .defaultAction) { act(.done) }
        }
    }
}

/// What the reader can do to a card. **The view reports; the model commits** — a view that wrote to the
/// ledger would be one that advanced before the write landed.
public enum ReviewAction: Sendable, Equatable {
    case reveal
    case grade(Grade)
    case skip
    /// Out of the way until the next study day (R05). **Not `skip`**, which leaves it due now.
    case postpone
    case undo
    case anotherBatch
    /// An unscheduled sitting. **Recorded and inert**: no schedule moves and no retention figure
    /// counts it, which is why it is a separate action and a separate label rather than a mode
    /// the reader might not notice they are in.
    case practise
    case done
}

/// Everything the review surface draws, and nothing it does not.
///
/// **The answer is `nil` before the reveal, at this boundary.** Not a flag beside it, not a string the
/// view is trusted to skip — absent, so the rule holds by construction rather than by everyone
/// remembering it on every future change.
public struct ReviewPresentation: Sendable, Equatable {
    public let stage: Stage

    public init(stage: Stage) { self.stage = stage }

    public enum Stage: Sendable, Equatable {
        case empty(Empty)
        case asking(Question)
        case finished(ReviewSession.Summary)
    }

    public enum Empty: Sendable, Equatable {
        /// Cards exist; none is due.
        case nothingDue
        /// The reader has not saved anything yet. A different sentence, because "nothing is due" to
        /// someone with no cards reads as a broken feature.
        case needsConfirmation(Int)
        case nothingEnrolled
        /// Nothing is askable, but new words are waiting on today's allowance. **A third sentence**,
        /// because a reader who saved thirty words this afternoon and is told "nothing is due" has
        /// no way to tell a working cap from a broken save.
        case heldBackUntilTomorrow(Int)
        /// **A fourth nothing: the cards could not be read at all.** The other three are answers;
        /// this is a failure, and it drew as "nothing is due" — telling a reader with a full
        /// collection that they were up to date. `problem` was assigned on that path and then
        /// thrown away, because an empty stage had nowhere to put it.
        case couldNotBeRead(String)
    }

    public struct Question: Sendable, Equatable {
        public let word: String
        /// What the word's colour is hashed from. **The lemma, not the captured surface**, so
        /// *ran* and *run* are one word here as they are in the lookup card and the drawer.
        public let accentKey: String
        public let sentence: Sentence?
        public let source: String
        public let position: Int
        public let batchSize: Int
        /// Whether this is practice. **Said on the card**, not inferred from how the reader got
        /// here: an attempt that changes nothing must not look like one that does.
        public let isPractice: Bool
        /// The question itself. **A fixed sentence, not a stored string** — it is reader-facing text
        /// and belongs in the catalog, so the view holds it and the model chooses nothing.
        public let prompt: Prompt
        /// Nil until the reader asks. See the type's own note.
        public let answer: Answer?
        /// A write in flight. The grade buttons refuse while one is, so a second press cannot become
        /// a second attempt at the same presentation.
        public let isCommitting: Bool
        /// A write that failed, in the reader's words. Stays until they act again.
        public let problem: String?

        public init(word: String, accentKey: String? = nil, sentence: Sentence?, source: String, position: Int,
                    batchSize: Int, isPractice: Bool = false, prompt: Prompt = .meaningHere,
                    answer: Answer? = nil, isCommitting: Bool = false, problem: String? = nil) {
            self.word = word
            // Defaults to the word, so a caller with no lemma is unchanged.
            self.accentKey = accentKey ?? word
            self.sentence = sentence
            self.source = source
            self.position = position
            self.batchSize = batchSize
            self.isPractice = isPractice
            self.prompt = prompt
            self.answer = answer
            self.isCommitting = isCommitting
            self.problem = problem
        }
    }

    /// Which question the card asks. One case today; a production card asks a different one, and it
    /// will be a case here rather than a string the model assembles.
    public enum Prompt: Sendable, Equatable {
        case meaningHere
    }

    public struct Sentence: Sendable, Equatable {
        public let text: String
        public let range: NSRange?

        public init(text: String, range: NSRange?) {
            self.text = text
            self.range = range
        }
    }

    public struct Answer: Sendable, Equatable {
        public let text: String
        public let dictionary: String?

        public init(text: String, dictionary: String?) {
            self.text = text
            self.dictionary = dictionary
        }
    }
}
