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
    public let state: ReviewPresentation
    /// What the reader did. The view decides nothing: it reports, and the model commits.
    public let act: @MainActor (ReviewAction) -> Void

    public init(state: ReviewPresentation, act: @escaping @MainActor (ReviewAction) -> Void) {
        self.state = state
        self.act = act
    }

    public var body: some View {
        // **Scrollable, because the content is the reader's own writing.** A long sentence and a
        // long answer shared a fixed stack with the controls, so past a certain length neither
        // could be read to the end and the buttons went off the bottom of the window.
        ScrollView {
            VStack(alignment: .leading, spacing: scale.space.stack) {
                switch state.stage {
                case .empty(let reason):
                    emptyState(reason)
                case .asking(let asking):
                    self.asking(asking)
                case .finished(let summary):
                    finishedState(summary)
                }
            }
            .padding(scale.space.padAcross)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        ReadingPalette.accent(for: question.accentKey).color(in: scheme)
    }

    // MARK: - Asking

    @ViewBuilder
    private func asking(_ question: ReviewPresentation.Question) -> some View {
        HStack {
            Text("\(question.position) of \(question.batchSize)")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
            if question.isPractice {
                Text("Practice — nothing is scheduled")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Text(verbatim: question.source)
                .font(.system(size: scale.text.small))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }

        // **The reader's own sentence, with the word marked** — the cue, and the only thing on the
        // front that is prose. A capture that produced no real sentence shows none rather than the
        // word echoed back and dressed as context.
        if let sentence = question.sentence {
            // The same marking the lookup card and the drawer use, so the word the reader met looks
            // the same wherever it is shown to them.
            Text(MarkedSentence.text(
                sentence.text,
                marking: sentence.range.map { [$0] } ?? [],
                // **The reader's emphasis setting**, which the lookup card and the drawer both
                // honour through the same helper. Hardcoding `.bold` made this the one surface
                // that ignored it.
                size: scale.text.body, emphasis: options.emphasis,
                accent: accent(for: question)))
        }

        Text(verbatim: question.word)
            .font(.system(size: scale.text.heading, weight: .medium))
            .foregroundStyle(accent(for: question))

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

        Spacer(minLength: 0)
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
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func controls(_ question: ReviewPresentation.Question) -> some View {
        HStack(spacing: scale.space.inline) {
            if question.answer == nil {
                // **Disabled while a grade is committing**, like the grade buttons beside it: a
                // reveal started here could finish after the sitting had advanced and put this
                // card's answer on the next one.
                Button("Show the answer") { act(.reveal) }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(question.isCommitting)
            }
            Spacer(minLength: 0)
            // **Forgot first, always.** The order is the same on every card, so a reader answering
            // quickly is answering the question and not hunting for the button.
            Button("Forgot") { act(.grade(.again)) }
                .keyboardShortcut("1", modifiers: [])
                .disabled(question.isCommitting)
            Button("Remembered") { act(.grade(.good)) }
                .keyboardShortcut("2", modifiers: [])
                .disabled(question.isCommitting)
                .help(Text("You recalled it before revealing the answer"))
            Button("Skip") { act(.skip) }
                .keyboardShortcut("s", modifiers: [])
                .disabled(question.isCommitting)
                .help(Text("Still due today; the next batch can have it"))
            // **"Not today" is not "skip".** A skipped card comes back in this evening's next
            // batch; this one is gone until tomorrow, and the reader has to be able to say which
            // they mean.
            Button("Not today") { act(.postpone) }
                .keyboardShortcut("t", modifiers: [])
                .disabled(question.isCommitting)
                .help(Text("Out of the way until tomorrow. Nothing about your memory is recorded"))
        }
        if let problem = question.problem {
            // **A failed write stays on screen.** The reader answered; if the ledger did not take it,
            // saying nothing would leave them believing it did.
            Text(verbatim: problem)
                .font(.system(size: scale.text.small))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - The ends

    @ViewBuilder
    private func emptyState(_ reason: ReviewPresentation.Empty) -> some View {
        switch reason {
        case .nothingDue:
            Text("Nothing is due right now.")
                .font(.system(size: scale.text.body))
        case .nothingEnrolled:
            Text("You have not saved any meanings to study yet.")
                .font(.system(size: scale.text.body))
        case .couldNotBeRead(let problem):
            Text("Your cards could not be read.")
                .font(.system(size: scale.text.body))
            Text(verbatim: problem)
                .font(.system(size: scale.text.small))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case .heldBackUntilTomorrow(let count):
            Text("Nothing is due right now.")
                .font(.system(size: scale.text.body))
            // **The specific sentence instead of the general one**, never both: "they come back
            // when they are due" is a vaguer restatement of what the line above just said exactly.
            Text("\(count) new saved, waiting for tomorrow.")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        if !reason.explainsItself {
            Text("Saved meanings come back here when they are due.")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
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
            Text("\(summary.postponed) put off until tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **Said, and said differently from "more due".** New words the day's allowance is holding
        // are not late; without this line a reader who saved thirty and answered five sees twenty-
        // five words go quiet with no explanation.
        if summary.heldBack > 0 {
            Text("\(summary.heldBack) new saved, waiting for tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        HStack(spacing: scale.space.inline) {
            // **Skipped cards are still due**, and were left out of `stillDue` — so skipping
            // the last batch ended the sitting with work outstanding and no way to go on.
            if summary.stillDue > 0 || summary.skipped > 0 {
                Button("Review another batch") { act(.anotherBatch) }
            }
            // **Offered when there is nothing due**, which is when a reader who wants to keep
            // going would otherwise have nothing to do but wait.
            if summary.stillDue == 0 && summary.skipped == 0 {
                Button("Practise") { act(.practise) }
            }
            Button("Done") { act(.done) }
                .keyboardShortcut(.defaultAction)
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

        /// Whether this reason has already said when the cards come back, so the surface does not
        /// follow it with a vaguer version of the same sentence.
        var explainsItself: Bool {
            switch self {
            case .heldBackUntilTomorrow, .couldNotBeRead: true
            case .nothingDue, .nothingEnrolled: false
            }
        }
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
