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
    /// What Done closes. Review is a pane of the Library window, so by default that window.
    private let finish: @MainActor () -> Void
    /// The primary dictionary the held sitting was drawn from. **Study state belongs to one
    /// dictionary**, so a sitting kept across pane switches (ADR-0044) is not kept across a switch of
    /// the primary — its cards are the old dictionary's.
    private var sittingScope: String?

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         primary: @escaping @MainActor () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
         clock: @escaping @MainActor () -> Date = { .now },
         finish: @escaping @MainActor () -> Void = {
             WindowActions.shared.dismissWindow(id: XiaolaiDictScene.libraryID)
         }) {
        self.finish = finish
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
            let scope = primary().chosen
            sittingScope = scope
            let cards = try await ledger.practisableCards(limit: Self.batchSize,
                                                          dictionary: scope)
            guard !cards.isEmpty else {
                session = nil
                presentation = ReviewPresentation(stage: .empty(.nothingDue))
                return
            }
            session = ReviewSession(startedAt: clock(),
                                    cards: cards.map { (id: $0.id, revision: $0.revision) })
            await draw()
        } catch {
            // **Said, not swallowed.** This drew "nothing is due" over a ledger that could not be
            // opened, which tells a reader with a full collection that they are up to date.
            session = nil
            presentation = ReviewPresentation(
                stage: .empty(.couldNotBeRead(error.localizedDescription)))
        }
    }

    /// Whether there is an answered card to go back to — what puts Undo in the toolbar. The same
    /// question `undo()` asks before it does anything, so the button is never there over nothing.
    var canUndo: Bool {
        session?.presentations.contains { $0.isAnswered } ?? false
    }

    @ObservationIgnored private var resuming = false
    /// Returns to the held sitting, or draws one where none is held — or where the reader has
    /// switched the primary since it was drawn.
    func resume() async {
        guard session == nil || sittingScope != primary().chosen, !resuming else { return }
        resuming = true
        defer { resuming = false }
        await start()
    }

    func start() async {
        guard let opening = store() else { return }
        problem = nil
        isPractice = false
        do {
            let ledger = try await opening.value
            let scope = primary().chosen
            sittingScope = scope
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
                let pending = try await ledger.attentionCount(dictionary: scope)
                if pending > 0 {
                    session = nil
                    presentation = ReviewPresentation(stage: .empty(.needsConfirmation(pending)))
                    return
                }
                let any = try await ledger.anyNotes(dictionary: scope)
                session = nil
                presentation = ReviewPresentation(stage: .empty(any ? .nothingDue : .nothingEnrolled))
                return
            }
            session = ReviewSession(
                startedAt: now, cards: cards.map { (id: $0.id, revision: $0.revision) },
                beyondBatch: max(0, counts.due - cards.count), heldBack: counts.heldBack)
            await draw()
        } catch {
            // `problem` belongs to a card on screen; there is none, so the reason goes in the
            // stage itself — assigning it here and then drawing `.nothingDue` lost it entirely.
            session = nil
            presentation = ReviewPresentation(
                stage: .empty(.couldNotBeRead(error.localizedDescription)))
        }
    }

    func act(_ action: ReviewAction) {
        // **Which card the reader acted on is decided here, synchronously.** A `Task` body does
        // not run at the point it is created: between `act` and the task's first line the reader
        // can skip, and a reveal that read `session.current` inside the task then revealed — and
        // answered — whichever card had arrived in the meantime. The card they were looking at is
        // the card in front of them *now*, which is only true here.
        let attempt = session?.current?.id
        switch action {
        case .reveal:
            Task { await reveal(attempt) }
        case .grade(let grade):
            Task { await commit(grade, attempt) }
        case .skip:
            session?.record(.skipped, for: attempt)
            Task { await draw() }
        case .postpone:
            Task { await postpone(attempt) }
        case .undo:
            Task { await undo() }
        case .anotherBatch:
            Task { await start() }
        case .practise:
            Task { await startPractice() }
        case .done:
            // **The sitting ends with it**, so the next visit draws a fresh batch — what reopening the
            // Review window did before Review became a pane, and what a resumed finished summary
            // would not.
            session = nil
            finish()
        }
    }

    /// **Out of the way until the next study day** (R05), and the surface advances only after the
    /// ledger has it — a card that disappeared from the sitting and was still due tomorrow evening
    /// would be the reader's "not today" silently ignored.
    ///
    /// The schedule is untouched. Saying "not this one, not now" is not saying anything about
    /// memory, so nothing here grades, and the daily allowance is unspent.
    private func postpone(_ attempt: UUID?) async {
        guard let card = session?.current, card.id == attempt, let opening = store() else { return }
        let until = studyDay.startOfNextDay(containing: clock())
        do {
            let ledger = try await opening.value
            try await ledger.postpone(cardID: card.cardID, until: until)
            LedgerChanges.shared.committed()
            // **For this attempt, not for whatever is current now.** Two presses during the write
            // both arrive here; the second finds a different card in front of the reader and is
            // refused, instead of advancing the sitting past a card nobody was shown.
            session?.record(.postponed, for: attempt)
        } catch {
            problem = String(localized: "It could not be hidden until tomorrow: \(error.localizedDescription)",
                             comment: "Shown on a review card when postponing it failed to save")
        }
        await draw()
    }

    // MARK: - One card

    private func draw() async {
        guard let session else { return }
        guard let current = session.current else {
            presentation = ReviewPresentation(stage: .finished(session.summary(wasPractice: isPractice)))
            return
        }
        answer = nil
        // **A failure belongs to the card it happened on.** Carried across, "That answer was not
        // saved" appeared on an untouched card the reader had merely skipped to.
        problem = nil
        guard let opening = store() else { return }
        let fetched: ReviewCue?
        do {
            fetched = try await opening.value.cue(forCard: current.cardID)
        } catch {
            // **A failed read is not a card in repair.** Both used to become nil and then a
            // silent skip, so one storage failure could consume an entire batch without ever
            // drawing a card — and the sitting would end saying everything had been reviewed.
            self.session = nil
            presentation = ReviewPresentation(
                stage: .empty(.couldNotBeRead(error.localizedDescription)))
            return
        }
        // **The card this was fetched for is still the card on screen**, or a later draw owns the
        // surface and this one has nothing to say. Unlike `reveal`'s check this one is defensive:
        // no test here reproduces a stale draw landing last, and it is kept because the ordering
        // that prevents it is not one Swift promises.
        guard let live = self.session, live.current?.id == current.id else { return }
        cue = fetched
        guard let cue else {
            // A card whose cue cannot be built is skipped rather than shown blank: its note is in
            // repair, and the queue's own recheck will stop offering it.
            self.session?.record(.skipped, for: current.id)
            await draw()
            return
        }
        render(cue, in: live)
    }

    /// **The answer is applied to the card it was fetched for, or not at all.**
    ///
    /// C2's rule is that a surface does not answer the question unasked; putting the *previous*
    /// card's answer on the next one breaks it and gets the answer wrong as well. The fetch
    /// suspends, and a skip in that window moves the reader on — so the attempt is checked
    /// against what is in front of them now.
    ///
    /// **Measured, not defensive.** Reading the current card inside the task instead of at the
    /// action fails `revealingThenSkippingDoesNotCarryTheAnswerOver` every run: the reader pressed
    /// Reveal for one card and the next one was answered for them.
    private func reveal(_ attempt: UUID?) async {
        guard let session, let current = session.current, let opening = store() else { return }
        guard current.id == attempt else { return }
        let fetched: ReviewAnswer?
        do {
            fetched = try await opening.value.revealed(cardID: current.cardID)
        } catch {
            // **`try?` marked the card revealed with nothing to show**, so "Show the answer"
            // could be pressed again and again and do nothing, with no reason given.
            guard self.session?.current?.id == attempt else { return }
            problem = String(localized: "The answer could not be read: \(error.localizedDescription)",
                             comment: "Shown on a review card when its answer could not be loaded")
            if let cue, let session = self.session { render(cue, in: session) }
            return
        }
        guard self.session?.current?.id == attempt else { return }
        answer = fetched
        self.session?.reveal()
        if let cue, let session = self.session { render(cue, in: session) }
    }

    private func commit(_ grade: Grade, _ attempt: UUID?) async {
        guard let session, let current = session.current, let opening = store() else { return }
        guard current.id == attempt else { return }
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
            LedgerChanges.shared.committed()
            committing = false
            self.session?.record(.graded(grade), for: attempt)
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
        // **The revision the restored card will be graded against.** Nil for an outcome that wrote
        // nothing; read back from the ledger otherwise, because the undo itself moved it and the
        // session cannot know the new number. Without this the reader's next answer to the card
        // they had just gone back to was refused as stale.
        var restored: Int?
        do {
            switch last.outcome {
            case .graded:
                let ledger = try await opening.value
                try await ledger.undoLatestReview(ofCard: last.cardID, at: clock())
                LedgerChanges.shared.committed()
                restored = try await ledger.revision(ofCard: last.cardID)
            case .postponed:
                // **Taking it back reaches the ledger too.** Undo reversed a grade durably and a
                // postponement only in the session, so the card came back on screen and stayed
                // hidden until tomorrow in every query behind it: the reader undid the action and
                // it was still in force.
                try await opening.value.postpone(cardID: last.cardID, until: nil)
                LedgerChanges.shared.committed()
            case .skipped, .none:
                break
            }
        } catch {
            problem = String(localized: "That could not be taken back: \(error.localizedDescription)",
                             comment: "Shown when undoing a review or a postponement failed")
            // **Drawn, or the reason is invisible.** The view observes `presentation`; assigning
            // `problem` and returning left the old presentation on screen, so a failed undo
            // looked exactly like one the reader had not pressed.
            if let cue, let session = self.session { render(cue, in: session) }
            return
        }
        self.session?.undoLast(revision: restored)
        await draw()
    }

    private func render(_ cue: ReviewCue, in session: ReviewSession) {
        guard let current = session.current else { return }
        presentation = ReviewPresentation(stage: .asking(ReviewPresentation.Question(
            word: cue.word, accentKey: cue.lemma,
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
        //
        // **No quality is not a quality that passes.** `cue.quality?.context != .missing` is true
        // when there is no quality at all, so an unqualified sentence was drawn as confidently as
        // a complete one — against the rule that a capture with no quality signal shows none.
        // A card with no reading behind it has no sentence either, and says so by being nil.
        guard let sentence = cue.sentence, let quality = cue.quality,
              quality.context != .missing, sentence != cue.word else { return nil }
        return ReviewPresentation.Sentence(text: sentence, range: cue.range)
    }

    static func source(of cue: ReviewCue) -> String {
        let where_ = cue.place.title ?? cue.place.name ?? ""
        // A card the reader wrote was met nowhere and read at no time; it says neither rather
        // than naming today, which would be a reading that never happened.
        guard let readAt = cue.readAt else { return where_ }
        let when = readAt.formatted(date: .abbreviated, time: .omitted)
        return where_.isEmpty ? when : "\(where_) · \(when)"
    }
}

/// The Review window's content.
///
/// **A view, not scene-body code.** Reading observable state in an `App`'s `body` invalidates every
/// scene in it — measured in this project as a sibling window whose menu item opened nothing — so the
/// model is read here, one level down.
///
/// **Undo is not here.** It is the window's — a toolbar item on Command-Z, put there by
/// `LibraryReviewPane` — where it was a button at zero opacity behind this view, hidden from
/// VoiceOver, that only a reader who guessed the key could reach.
struct ReviewSceneView: View {
    let model: ReviewModel
    var findUnconfirmed: (@MainActor () -> Void)?

    var body: some View {
        ReviewView(state: model.presentation, findUnconfirmed: findUnconfirmed) { model.act($0) }
            .task { await model.resume() }
    }
}
