import Foundation
import ReviewKit
import StudyKit

public enum LibraryAction: Sendable, Equatable {
    case retry
    case search(String)
    /// One more page. **Grown, not offset**: a card enrolled while the reader is reading must not
    /// shift a boundary underneath them.
    case showMore
    /// The reader agrees these are the meanings they met. The library showed "Confirm the meaning"
    /// as a status with no way to act on it — a diagnosis with no remedy.
    case confirm
    /// **A sitting over exactly what is selected**, in Review (review-module-plan §8.2). The model hands
    /// the whole selection over, as listed, and the sitting says what it left out and why.
    case reviewSelected(SittingOrder)
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
    /// **The selected rows a confirmation would change**, decided by the model (ADR-0035: prune in the
    /// model, not on the way to the view). Not the whole selection: Confirm counted and reached every
    /// selected row, so an answerless note had `confirmed_at` written and stayed as unreviewable as it
    /// was, and a confirmed one was counted as one more to confirm.
    public let confirmable: Set<UUID>
    /// Whether the selection holds anything a confirmation would change.
    public var canConfirm: Bool { !confirmable.isEmpty }
    /// **The selected rows a Selected sitting could ask now**, decided by the model through the
    /// sitting's own planner — what Review Selected counts, and what it is disabled over when there are
    /// none.
    public let reviewable: Set<UUID>
    /// **The selected new meanings today's allowance would hold back** — the planner's count, so a
    /// control disabled over them can say they wait for tomorrow rather than that something is wrong.
    public let reviewHeldBack: Int

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
                hasMore: Bool = false, confirmable: Set<UUID> = [], reviewable: Set<UUID> = [],
                reviewHeldBack: Int = 0, suggestions: [Suggestion] = [], exported: String? = nil,
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
        self.confirmable = confirmable
        self.reviewable = reviewable
        self.reviewHeldBack = reviewHeldBack
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

        /// Drawn as `Text(name)`, which inflects the count as a key does; `String(localized:)` does not, and
        /// would show the markup.
        public var name: LocalizedStringResource {
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
    /// One line of "Where You Met It": a reading, and how many times that same sentence was met
    /// in the same place on the same day.
    ///
    /// **Collapsed here, counted never dropped.** The ledger keeps every lookup and so does the
    /// inspector's data; what is drawn is one line per sentence-place-day, the way a card draws
    /// "×N", because fifteen identical lines say nothing the first did not.
    public struct ReadingLine: Sendable, Equatable, Identifiable {
        /// The reading the line is headed by: the first of its kind in the order given.
        public let mark: ReadingMark
        public let times: Int
        public var id: Int { mark.id }

        public static func lines(of marks: [ReadingMark], calendar: Calendar = .current) -> [ReadingLine] {
            var lines: [ReadingLine] = []
            var place: [String: Int] = [:]
            for mark in marks {
                let day = calendar.startOfDay(for: mark.at).timeIntervalSinceReferenceDate
                let key = "\(day)\u{1F}\(mark.source ?? "")\u{1F}\(mark.sentence)"
                if let index = place[key] {
                    lines[index] = ReadingLine(mark: lines[index].mark, times: lines[index].times + 1)
                } else {
                    place[key] = lines.count
                    lines.append(ReadingLine(mark: mark, times: 1))
                }
            }
            return lines
        }
    }

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

        public var name: LocalizedStringResource {
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
        /// Whether confirming would change it. **Not read off `status`**, which a pause or an archive
        /// overrides: a paused proposal is still one Confirm fixes.
        public let isConfirmable: Bool
        /// What a Selected sitting of this row alone would do with it — the sitting's own planner, run by
        /// the model.
        public let review: Review
        /// Whether a Selected sitting could ask it now.
        public var isReviewable: Bool { review == .askable }

        /// **Three answers, not a flag**: a new meaning today's allowance holds back is neither askable
        /// nor blocked by anything the reader can fix, and the control says which (WI-8).
        public enum Review: Sendable, Equatable {
            /// Enrolled, nothing in the way, neither paused nor put off, the study dictionary's — and, if
            /// never reviewed, within today's allowance of new meanings.
            case askable
            /// A new meaning today's allowance holds back until tomorrow.
            case heldBack
            /// Anything else in the way: paused, put off, archived, waiting in Needs Attention, or saved
            /// under another study dictionary.
            case notAskable
        }

        public init(id: UUID, word: String, accentKey: String? = nil, excerpt: String, marks: [NSRange],
                    answer: String, status: Status?, due: String?, isConfirmable: Bool = false,
                    review: Review = .notAskable) {
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
            self.isConfirmable = isConfirmable
            self.review = review
        }
    }
}
