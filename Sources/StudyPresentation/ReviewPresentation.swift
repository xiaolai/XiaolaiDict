import Foundation
import ReviewKit
import StudyKit

/// What the reader can do to a card. **The view reports; the model commits** — a view that wrote to the
/// ledger would be one that advanced before the write landed.
public enum ReviewAction: Sendable, Equatable {
    case reveal
    case grade(Grade)
    case skip
    /// Out of the way until the next study day (R05). **Not `skip`**, which leaves it due now.
    case postpone
    case undo
    /// Opens the card's word in Apple's Dictionary. **Offered only once the meaning is showing**, and
    /// not a grade: it moves no schedule, writes no event and leaves the card where it is.
    case explore
    case anotherBatch
    /// An unscheduled sitting. **Recorded and inert**: no schedule moves and no retention figure
    /// counts it, which is why it is a separate action and a separate label rather than a mode
    /// the reader might not notice they are in.
    case practise
    /// Raises today's new-meaning allowance by what the end of the sitting offered, for this study day
    /// only, and draws a batch (WI-5). **It spends nothing**: introductions spend the allowance
    /// (ADR-0037), and this moves only the ceiling they are counted against. How many is the model's.
    case introduceMoreToday
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
        case finished(Finished)
    }

    /// **The end of a sitting** (review-module-plan §8.4, WI-5): what the sitting did, what the coming
    /// study days hold, which words keep slipping, and whether more new meanings can be introduced
    /// today.
    ///
    /// **Counts and words, never a meaning** (C2). A word is what the card's front showed; nothing here
    /// can hold what a card's back says, so the end of a sitting cannot answer a question either.
    public struct Finished: Sendable, Equatable {
        public let summary: ReviewSession.Summary
        /// What each of the coming study days will ask, today first. **Nil where it could not be
        /// read**, which `problem` then says — never an empty week standing in for an unread one.
        public let forecast: Forecast?
        /// The words of the meanings this sitting forgot that keep slipping — the Struggling filter's
        /// rule (R09). **Named and nothing else**: nothing is paused, put off or rescheduled for it.
        public let slipping: [String]
        /// How many more new meanings "Introduce More Today" would add to today's allowance. Zero is
        /// not offered: nothing is held back, or the count could not be read.
        public let moreNewToday: Int
        /// Why the forecast and the rest could not be read, in the reader's words. The sitting's own
        /// counts are still true and still shown.
        public let problem: String?

        public init(summary: ReviewSession.Summary, forecast: Forecast? = nil, slipping: [String] = [],
                    moreNewToday: Int = 0, problem: String? = nil) {
            self.summary = summary
            self.forecast = forecast
            self.slipping = slipping
            self.moreNewToday = moreNewToday
            self.problem = problem
        }
    }

    /// Whether what is on screen already offers the way to the unconfirmed meanings — the empty
    /// state that says they are what is holding review up has the button itself.
    public var offersFindUnconfirmed: Bool {
        if case .empty(.needsAttention) = stage { return true }
        return false
    }

    public enum Empty: Sendable, Equatable {
        /// Cards exist; none is due.
        case nothingDue
        /// Saved meanings exist and none can be asked, **counted by what is in the way** — each reason
        /// has its own remedy, and a sentence naming one must count only what it fixes.
        case needsAttention(StudyAttention)
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
    }

    public struct Question: Sendable, Equatable {
        /// **Which showing this is** — the sitting's presentation, whose id is also the grade's
        /// idempotency key. Every control on the card hands it back with its action, so an answer is
        /// about the card that was drawn when it was given and never about one the sitting has moved
        /// to since (WI-8).
        public let showing: UUID
        public let word: String
        /// What the word's colour is hashed from. **The lemma, not the captured surface**, so
        /// *ran* and *run* are one word here as they are in the lookup card and the drawer.
        public let accentKey: String
        /// The word to open in the dictionary: the card's own spelling, not the form it was met in.
        /// Defaults to the word, so a caller with nothing better is unchanged.
        public let exploreTerm: String
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

        public init(showing: UUID, word: String, accentKey: String? = nil, exploreTerm: String? = nil,
                    sentence: Sentence?, source: String, position: Int,
                    batchSize: Int, isPractice: Bool = false, prompt: Prompt = .meaningHere,
                    answer: Answer? = nil, isCommitting: Bool = false, problem: String? = nil) {
            self.showing = showing
            self.word = word
            // Defaults to the word, so a caller with no lemma is unchanged.
            self.accentKey = accentKey ?? word
            self.exploreTerm = exploreTerm ?? word
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
