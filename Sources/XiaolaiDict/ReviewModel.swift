import Foundation
import Observation
import SwiftUI
import XiaolaiDictCore
import XiaolaiDictUI

/// **The Review window's model: a session, a ledger, and nothing between them that guesses.**
///
/// Everything with a rule in it is elsewhere — `ReviewSession` knows what a sitting is,
/// `MemoryScheduler` knows what a grade does, the ledger knows what may be asked. This carries the
/// reader's action to those and the result back, and its whole discipline is one rule:
///
/// **The surface advances after the write, never before.** A model that moved to the next card while
/// the grade was in flight would let a reader finish a batch of ten believing ten are saved when nine
/// are, and the one that failed is the one they will never see again.
@MainActor
@Observable
final class ReviewModel {
    private(set) var presentation = ReviewPresentation(stage: .empty(.nothingEnrolled))
    private var session: ReviewSession?
    /// The cue in front of the reader, held so a reveal does not go back to disk.
    private var cue: ReviewCue?
    /// The answer, fetched only when the reader asks. **Not held before that**: a model that had it
    /// all along is one refactor away from handing it to the view.
    private var answer: ReviewAnswer?
    private var committing = false
    private var problem: String?
    /// Whether this sitting is practice. **Held on the model, not inferred at the commit**: which
    /// ledger call a grade goes to is decided once, when the sitting starts.
    private var isPractice = false

    /// How many cards one sitting offers. A bound on the sitting, never on the reader's debt.
    static let batchSize = 10
    /// **First introductions a day, and nothing else is rationed** (C08). Five is the feature
    /// ledger's proposal and a guess: ten new cards on Monday are ten reviews on Tuesday and
    /// twenty by Wednesday, and the number that keeps that bearable has not been measured.
    static let newCardsPerDay = 5

    /// Frozen when the sitting starts. A reader crossing a timezone mid-session must not have the
    /// day boundary move under them, and the allowance must not be replenished by travelling.
    private var studyDay = StudyDay.standard

    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    private let primary: @MainActor () -> PrimaryDictionary
    private let clock: @MainActor () -> Date

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         primary: @escaping @MainActor () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
         clock: @escaping @MainActor () -> Date = { .now }) {
        self.store = store
        self.primary = primary
        self.clock = clock
    }

    /// Draws a batch. Called when the window opens and when the reader asks for another.
    /// An unscheduled sitting over cards the reader has already reviewed.
    ///
    /// **Nothing it does is scheduled.** Every grade goes to `practise`, which records the attempt
    /// and leaves the card exactly as it was — so the reader can keep going without the scheduler
    /// concluding anything from it.
    func startPractice() async {
        guard let opening = store() else { return }
        problem = nil
        isPractice = true
        do {
            let ledger = try await opening.value
            let cards = try await ledger.practisableCards(limit: Self.batchSize,
                                                          dictionary: primary().chosen)
            guard !cards.isEmpty else {
                session = nil
                presentation = ReviewPresentation(stage: .empty(.nothingDue))
                return
            }
            session = ReviewSession(startedAt: clock(),
                                    cards: cards.map { (id: $0.id, revision: $0.revision) })
            await draw()
        } catch {
            presentation = ReviewPresentation(stage: .empty(.nothingDue))
        }
    }

    func start() async {
        guard let opening = store() else { return }
        problem = nil
        isPractice = false
        do {
            let ledger = try await opening.value
            let scope = primary().chosen
            let now = clock()
            studyDay = .standard
            let dayStart = studyDay.start(containing: now)
            let cards = try await ledger.dueCards(at: now, limit: Self.batchSize, dictionary: scope,
                                                  newAllowance: Self.newCardsPerDay,
                                                  dayStart: dayStart)
            let counts = try await ledger.queueCounts(at: now, dictionary: scope,
                                                      newAllowance: Self.newCardsPerDay,
                                                      dayStart: dayStart)
            guard !cards.isEmpty else {
                // **Three different nothings.** A reader with no cards is not a reader who is up to
                // date, and neither is one whose remaining words are merely waiting for tomorrow —
                // told "nothing is due", they would read rationing as loss.
                if counts.heldBack > 0 {
                    session = nil
                    presentation = ReviewPresentation(stage: .empty(.heldBackUntilTomorrow(counts.heldBack)))
                    return
                }
                let any = try await ledger.anyNotes()
                session = nil
                presentation = ReviewPresentation(stage: .empty(any ? .nothingDue : .nothingEnrolled))
                return
            }
            session = ReviewSession(
                startedAt: now, cards: cards.map { (id: $0.id, revision: $0.revision) },
                beyondBatch: max(0, counts.due - cards.count), heldBack: counts.heldBack)
            await draw()
        } catch {
            problem = String(localized: "The review could not be started: \(error.localizedDescription)",
                             comment: "Shown in the Review window when its cards could not be read")
            presentation = ReviewPresentation(stage: .empty(.nothingDue))
        }
    }

    func act(_ action: ReviewAction) {
        switch action {
        case .reveal:
            Task { await reveal() }
        case .grade(let grade):
            Task { await commit(grade) }
        case .skip:
            session?.record(.skipped)
            Task { await draw() }
        case .undo:
            Task { await undo() }
        case .anotherBatch:
            Task { await start() }
        case .practise:
            Task { await startPractice() }
        case .done:
            WindowActions.shared.dismissWindow(id: XiaolaiDictScene.reviewID)
        }
    }

    // MARK: - One card

    private func draw() async {
        guard let session else { return }
        guard let current = session.current else {
            presentation = ReviewPresentation(stage: .finished(session.summary))
            return
        }
        answer = nil
        guard let opening = store() else { return }
        do {
            cue = try await opening.value.cue(forCard: current.cardID)
        } catch {
            cue = nil
        }
        guard let cue else {
            // A card whose cue cannot be built is skipped rather than shown blank: its note is in
            // repair, and the queue's own recheck will stop offering it.
            self.session?.record(.skipped)
            await draw()
            return
        }
        render(cue, in: session)
    }

    private func reveal() async {
        guard let session, let current = session.current, let opening = store() else { return }
        answer = try? await opening.value.revealed(cardID: current.cardID)
        self.session?.reveal()
        if let cue, let session = self.session { render(cue, in: session) }
    }

    private func commit(_ grade: Grade) async {
        guard let session, let current = session.current, let opening = store() else { return }
        guard !committing else { return }
        committing = true
        problem = nil
        if let cue { render(cue, in: session) }
        do {
            // **The presentation's id is the idempotency key.** One showing is one attempt however
            // many times the write is retried, and a second showing of the same card is a new one.
            //
            // Which call it goes to was decided when the sitting started, not here: a practice
            // attempt that reached `grade` would move a schedule the reader was told it would not.
            if isPractice {
                try await opening.value.practise(cardID: current.cardID, grade,
                                                 eventID: current.id, at: clock())
            } else {
                try await opening.value.grade(cardID: current.cardID, grade, eventID: current.id,
                                              expectedRevision: current.revision, at: clock())
            }
            committing = false
            self.session?.record(.graded(grade))
            await draw()
        } catch {
            committing = false
            // **Stays on screen.** The reader answered; if the ledger did not take it, silence would
            // leave them believing it did — and the card would never come back to be answered again.
            problem = String(localized: "That answer was not saved: \(error.localizedDescription)",
                             comment: "Shown on a review card when the grade could not be written")
            if let cue, let session = self.session { render(cue, in: session) }
        }
    }

    private func undo() async {
        guard let session, let opening = store() else { return }
        guard let last = session.presentations.last(where: { $0.isAnswered }) else { return }
        if case .graded = last.outcome {
            do {
                try await opening.value.undoLatestReview(ofCard: last.cardID, at: clock())
            } catch {
                problem = String(localized: "That review could not be taken back: \(error.localizedDescription)",
                                 comment: "Shown when undoing a review failed")
                return
            }
        }
        self.session?.undoLast()
        await draw()
    }

    private func render(_ cue: ReviewCue, in session: ReviewSession) {
        guard let current = session.current else { return }
        presentation = ReviewPresentation(stage: .asking(ReviewPresentation.Question(
            word: cue.word,
            // **No sentence where the capture did not get one.** The ledger stores the selection
            // itself when nothing surrounded the word, and drawing that as context would be the
            // word echoed back and dressed as the reader's own reading.
            sentence: Self.sentence(of: cue),
            source: Self.source(of: cue),
            position: session.cursor + 1, batchSize: session.presentations.count,
            isPractice: isPractice,
            answer: current.isRevealed ? answer.map {
                ReviewPresentation.Answer(text: $0.text, dictionary: $0.dictionary)
            } : nil,
            isCommitting: committing, problem: problem)))
    }

    static func sentence(of cue: ReviewCue) -> ReviewPresentation.Sentence? {
        // `.missing` means the app exposed no surrounding text and the "sentence" *is* the
        // selection. Drawing that as context would be the word echoed back and dressed as reading.
        guard cue.quality?.context != .missing, cue.sentence != cue.word else { return nil }
        return ReviewPresentation.Sentence(text: cue.sentence, range: cue.range)
    }

    static func source(of cue: ReviewCue) -> String {
        let where_ = cue.place.title ?? cue.place.name ?? ""
        let when = cue.readAt.formatted(date: .abbreviated, time: .omitted)
        return where_.isEmpty ? when : "\(where_) · \(when)"
    }
}

/// The Review window's content.
///
/// **A view, not scene-body code.** Reading observable state in an `App`'s `body` invalidates every
/// scene in it — measured in this project as a sibling window whose menu item opened nothing — so the
/// model is read here, one level down.
struct ReviewSceneView: View {
    let model: ReviewModel

    var body: some View {
        ReviewView(state: model.presentation) { model.act($0) }
            // **Undo is the window's**, not a button on the card: it is about the review just
            // committed, which is no longer on screen. Command-Z is where a reader looks for it.
            .background {
                Button("Undo the last review") { model.act(.undo) }
                    .keyboardShortcut("z", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .task { await model.start() }
    }
}
