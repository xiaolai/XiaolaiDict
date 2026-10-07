import CaptureModel
import Foundation
import Observation
import ReviewKit
import StudyKit
import StudyPresentation

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
public final class ReviewModel {
    public private(set) var presentation = ReviewPresentation(stage: .empty(.nothingEnrolled))
    private var session: ReviewSession?
    /// The cue in front of the reader, held so a reveal does not go back to disk.
    private var cue: ReviewCue?
    /// The answer, fetched only when the reader asks. **Not held before that**: a model that had it
    /// all along is one refactor away from handing it to the view.
    private var answer: ReviewAnswer?
    /// **A write to the ledger is in flight** — a grade, a "not today", or an undo. One at a time: an
    /// undo pressed while a grade was being written took back the answer *before* it and moved the
    /// sitting, so the grade then landed on a card the sitting had left and nothing could take it back;
    /// two undos together voided twice. Every action that writes, or that records an outcome a write
    /// would contradict, is refused while this holds, and the card's controls and Undo are disabled.
    private var writing = false
    private var problem: String?
    /// Which draw owns the surface. **Every draw takes the next number before it first suspends**, and
    /// publishes only while it is still the latest — so a sitting the reader asked for is not replaced
    /// by one asked for before it that happened to finish later. Which ledger call a grade goes to is
    /// no longer the sitting's: each card carries the mode it was drawn in (`Presentation.mode`).
    @ObservationIgnored private var drawing = 0
    /// Selected sittings still being drawn. **What the pane's `resume` defers to**: showing Review is
    /// what Review Selected does, and a resume that found no sitting held drew the queue's over it.
    @ObservationIgnored private var selecting = 0

    /// How many cards one sitting offers. A bound on the sitting, never on the reader's debt.
    public static let batchSize = 10
    /// **First introductions a day, and nothing else is rationed** (C08). Five is the feature
    /// ledger's proposal and a guess: ten new cards on Monday are ten reviews on Tuesday and
    /// twenty by Wednesday, and the number that keeps that bearable has not been measured.
    public static let newCardsPerDay = 5

    /// Frozen when the sitting starts. A reader crossing a timezone mid-session must not have the
    /// day boundary move under them, and the allowance must not be replenished by travelling.
    private var studyDay: StudyDay

    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    private let primary: @MainActor () -> PrimaryDictionary
    /// A dictionary's name, from its key. **What an answer is signed with**: the key is a bundle
    /// identifier, and a revealed answer was attributed to "com.apple.dictionary.zh_CN-en.OCD".
    /// Nil where the dictionary is no longer one the reader has on — then the answer is unsigned.
    private let dictionaryName: @MainActor (String) -> String?
    private let clock: @MainActor () -> Date
    /// The study day a sitting is drawn in, asked at each draw and frozen for the sitting — the reader's
    /// zone at that moment. A parameter, like the clock, so a test can travel.
    private let studyDayNow: @MainActor () -> StudyDay
    /// What Done closes. Review is a pane of the Library window, so the app hands in that window's dismissal.
    /// **No default**: this module can reach neither the app's window actions nor its scenes, and a default
    /// that did nothing would be a Done that refuses its click (plan-macos-modularisation P4b).
    private let finish: @MainActor () -> Void
    /// Opens a word in the system dictionary and says whether it took. **Handed in by the app**, for the
    /// reason `finish` is; a parameter too so a test can see what was asked without launching an app.
    private let openInDictionary: @MainActor (String) -> Bool
    /// The primary dictionary the held sitting was drawn from. **Study state belongs to one
    /// dictionary**, so a sitting kept across pane switches (ADR-0044) is not kept across a switch of
    /// the primary — its cards are the old dictionary's.
    private var sittingScope: String?
    /// Today's one-day increase of the new-meaning allowance, kept in the suite the model was given.
    private let increases: OneDayIncreaseStore
    /// **Told after every scheduled answer the ledger took** — the reminder's cue to ask whether the
    /// sitting left anything askable today, and withdraw today's reminder if not (review-module-plan
    /// §5.4). Practice moves no schedule and tells nothing.
    private let graded: @MainActor () -> Void

    public init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         primary: @escaping @MainActor () -> PrimaryDictionary = { PrimaryDictionaryStore().load() },
         dictionaryName: @escaping @MainActor (String) -> String? = { _ in nil },
         clock: @escaping @MainActor () -> Date = { .now },
         studyDay: @escaping @MainActor () -> StudyDay = { .standard },
         // **No default**, as for the Library: a default of `.standard` lets every test that omits it
         // write the one-day increase into the runner's own domain, where the next run reads it.
         defaults: UserDefaults,
         graded: @escaping @MainActor () -> Void = {},
         finish: @escaping @MainActor () -> Void,
         openInDictionary: @escaping @MainActor (String) -> Bool) {
        self.finish = finish
        self.openInDictionary = openInDictionary
        self.store = store
        self.primary = primary
        self.dictionaryName = dictionaryName
        self.clock = clock
        studyDayNow = studyDay
        self.studyDay = studyDay()
        self.graded = graded
        increases = OneDayIncreaseStore(defaults: defaults)
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
        drawing += 1
        let mine = drawing
        do {
            let ledger = try await opening.value
            let scope = primary().chosen
            let day = studyDayNow()
            let cards = try await ledger.practisableCards(limit: Self.batchSize,
                                                          dictionary: scope)
            guard mine == drawing else { return }
            sittingScope = scope
            // **Frozen here too** (audit-fix round 2): "not today" in practice puts a card off until the
            // next study day, and without this it was the next day of whatever zone the last *review*
            // sitting froze — a reader who had travelled since had it back at another zone's 04:00.
            studyDay = day
            guard !cards.isEmpty else {
                session = nil
                presentation = ReviewPresentation(stage: .empty(.nothingDue))
                return
            }
            session = ReviewSession(startedAt: clock(),
                                    cards: cards.map { (id: $0.id, revision: $0.revision) }, mode: .practice)
            await draw()
        } catch {
            // **Said, not swallowed.** This drew "nothing is due" over a ledger that could not be
            // opened, which tells a reader with a full collection that they are up to date.
            guard mine == drawing else { return }
            session = nil
            presentation = ReviewPresentation(
                stage: .empty(.couldNotBeRead(error.localizedDescription)))
        }
    }

    /// Whether there is an answered card to go back to — what puts Undo in the toolbar. The same
    /// question `undo()` asks before it does anything, so the button is never there over nothing.
    public var canUndo: Bool {
        !writing && session?.presentations.contains { $0.isAnswered } ?? false
    }

    @ObservationIgnored private var resuming = false
    /// Returns to the held sitting, or draws one where none is held — or where the reader has
    /// switched the primary since it was drawn.
    ///
    /// **A held sitting is returned to only with a card that can still be asked** (the final closing pass,
    /// finding 2). The reader leaves Review for Saved or History and comes back; what they did there —
    /// archive, pause, choose a meaning that replaces a word-only card, delete a reading — can leave the
    /// card on screen one no grade will ever be taken for, and the sitting held it for good.
    public func resume() async {
        if session != nil, sittingScope == primary().chosen, !resuming, selecting == 0 {
            await recheckTheCardOnScreen()
            return
        }
        guard session == nil || sittingScope != primary().chosen, !resuming, selecting == 0 else { return }
        resuming = true
        defer { resuming = false }
        await start()
    }

    /// The card on screen, asked again whether it can be asked, and let go where it cannot. A read that fails
    /// changes nothing: the card stays, and a grade of it says what went wrong.
    private func recheckTheCardOnScreen() async {
        guard case .asking = presentation.stage, !writing, let current = session?.current,
              let opening = store() else { return }
        let departure: Departure?
        do {
            departure = try await opening.value.departure(ofCard: current.cardID, at: clock())
        } catch {
            return
        }
        guard let departure, !writing, session?.current?.id == current.id else { return }
        session?.record(.left(departure), for: current.id)
        await draw()
    }

    public func start() async {
        guard let opening = store() else { return }
        problem = nil
        drawing += 1
        let mine = drawing
        do {
            let ledger = try await opening.value
            let scope = primary().chosen
            let now = clock()
            let day = studyDayNow()
            // **One read, and the batch and its counts both planned from it** (WI-2). Two queries
            // could disagree the moment a card came due between them, and the end of the batch would
            // report a backlog the batch was not drawn from.
            let planner = planner(day, now)
            let plan = planner.reviewSitting(
                from: try await ledger.sittingCandidates(dictionary: scope, introducedSince: planner.today))
            guard mine == drawing else { return }
            sittingScope = scope
            studyDay = day
            let cards = plan.batch, counts = plan.counts
            guard !cards.isEmpty else {
                // **Three different nothings.** A reader with no cards is not a reader who is up to
                // date, and neither is one whose remaining words are merely waiting for tomorrow —
                // told "nothing is due", they would read rationing as loss.
                if counts.heldBack > 0 {
                    session = nil
                    presentation = ReviewPresentation(stage: .empty(.heldBackUntilTomorrow(counts.heldBack)))
                    return
                }
                // **By reason**: each has its own remedy, and Confirm is not the remedy for most.
                let waiting = try await ledger.attentionCounts(dictionary: scope)
                guard mine == drawing else { return }
                if waiting.total > 0 {
                    session = nil
                    presentation = ReviewPresentation(stage: .empty(.needsAttention(waiting)))
                    return
                }
                let any = try await ledger.anyNotes(dictionary: scope)
                guard mine == drawing else { return }
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
            guard mine == drawing else { return }
            session = nil
            presentation = ReviewPresentation(
                stage: .empty(.couldNotBeRead(error.localizedDescription)))
        }
    }

    /// **A sitting over exactly the notes the reader chose in Saved** (review-module-plan §8.2, R4) —
    /// what the Library's Review Selected hands over, as listed. Every card is filtered before anything
    /// is shown, and its mode is frozen at the draw: due is graded, reviewed and not due is practised.
    ///
    /// **Synchronous up to the draw**, so the claim on the surface is made before the Library shows the
    /// Review pane — whose `resume` would otherwise find no sitting held and draw the queue's over this
    /// one. The draw itself is the returned task, which the caller need not wait for.
    @discardableResult
    public func startSelected(noteIDs: [UUID], order: SittingOrder) -> Task<Void, Never> {
        drawing += 1
        selecting += 1
        let mine = drawing
        return Task {
            await drawSelected(noteIDs, order, mine)
            selecting -= 1
        }
    }

    private func drawSelected(_ noteIDs: [UUID], _ order: SittingOrder, _ mine: Int) async {
        guard let opening = store() else { return }
        problem = nil
        do {
            let ledger = try await opening.value
            let scope = primary().chosen
            let now = clock()
            let day = studyDayNow()
            let planner = planner(day, now)
            let plan = planner.selectedSitting(
                from: try await ledger.selectedCandidates(noteIDs: noteIDs, dictionary: scope,
                                                          introducedSince: planner.today),
                order: order)
            guard mine == drawing else { return }
            sittingScope = scope
            studyDay = day
            // **Nothing to ask is still a sitting with an end to show**: an empty one is finished at
            // once, and its end says what was held back or left out, and why — the same sentences as
            // any other sitting's end, rather than a fifth way of saying nothing.
            session = ReviewSession(
                startedAt: now,
                drawn: plan.batch.map { (id: $0.card.id, revision: $0.card.revision, mode: $0.mode) },
                beyondBatch: plan.stillDue, heldBack: plan.heldBack, excluded: plan.excluded)
            await draw()
        } catch {
            guard mine == drawing else { return }
            session = nil
            presentation = ReviewPresentation(stage: .empty(.couldNotBeRead(error.localizedDescription)))
        }
    }

    /// What the reader did. `showing` is **the card it was done to**: the showing the surface drew
    /// when they pressed, which the view names. Nil is for a caller with no surface of its own — the
    /// instrument, a test — and means the card this model last put on screen.
    public func act(_ action: ReviewAction, on showing: UUID? = nil) {
        // **Which card the reader acted on is decided here, synchronously.** A `Task` body does
        // not run at the point it is created: between `act` and the task's first line the reader
        // can skip, and a reveal that read `session.current` inside the task then revealed — and
        // answered — whichever card had arrived in the meantime.
        //
        // **And it is the card on screen, not the sitting's current one.** A skip advances the
        // sitting at once, and the next card is drawn only once its cue has been read: a grade
        // pressed in between went to `session.current` — a card nobody had been shown — and graded
        // it (WI-8). So an action names the showing it was made on, and one whose card the sitting
        // has already left is refused: the reader acted on a card that is gone, and nothing they
        // can see is what they answered.
        let shown = showing ?? onScreen
        let attempt = shown.flatMap { $0 == session?.current?.id ? $0 : nil }
        switch action {
        case .reveal:
            guard let attempt else { return }
            Task { await reveal(attempt) }
        case .grade(let grade):
            guard let attempt else { return }
            Task { await commit(grade, attempt) }
        // **Not while the card's grade is being written**, either: a skip then recorded the card skipped
        // over a grade the ledger kept, and a put-off moved its revision under the grade or hid it after.
        // The view disables both while it commits; the model does not rely on that (WI-8).
        case .skip:
            guard let attempt, !writing, session?.record(.skipped, for: attempt) == true else { return }
            Task { await draw() }
        case .postpone:
            guard let attempt, !writing else { return }
            Task { await postpone(attempt) }
        case .undo:
            guard !writing else { return }
            Task { await undo() }
        case .explore:
            guard attempt != nil else { return }
            explore()
        case .anotherBatch:
            Task { await start() }
        case .practise:
            Task { await startPractice() }
        case .introduceMoreToday:
            introduceMoreToday()
        case .done:
            // **The sitting ends with it**, so the next visit draws a fresh batch — what reopening the
            // Review window did before Review became a pane, and what a resumed finished summary
            // would not.
            session = nil
            finish()
        }
    }

    /// The showing this model last drew, or nil when no card is on screen.
    private var onScreen: UUID? {
        guard case .asking(let question) = presentation.stage else { return nil }
        return question.showing
    }

    /// **Opens the card's word, and changes nothing else.** Refused unless the meaning is showing: the
    /// button is absent before that, and a key that arrives by another route must not look the answer
    /// up either. Synchronous and ledger-free on purpose — it is not a reading, so nothing is
    /// recorded, and not a grade, so no schedule moves.
    private func explore() {
        guard let cue, answer != nil, session?.current?.isRevealed == true, !writing else { return }
        // A success says nothing and leaves any earlier problem standing: a failed grade is still
        // unrecorded whether or not the reader went to look something up.
        if !openInDictionary(Self.explorationTerm(of: cue)) {
            problem = String(localized: "The dictionary could not be opened.",
                             comment: "Shown on a review card when asking Apple's Dictionary about its word did nothing")
            if let session { render(cue, in: session) }
        }
    }

    /// The word the dictionary files the card under. **The card's own spelling**: a phrase by its
    /// text — the reading's lemma is the hovered word's, and `take into account` is not `account` —
    /// and a card the reader wrote by theirs; anything else by the lemma, since the reader may have
    /// met *ran* and the dictionary has *run*.
    static func explorationTerm(of cue: ReviewCue) -> String {
        cue.target.ownText ?? cue.lemma
    }

    /// **A sitting's planner, with today's one-day increase in it.** One spelling for every draw, so a
    /// Review sitting, a Selected one and the end's counts are rationed against one allowance.
    private func planner(_ day: StudyDay, _ now: Date) -> SittingPlanner {
        Self.planner(day, now, increaseToday: increases.extra(in: day, at: now))
    }

    /// **The sitting's planner, for anything that must count as a sitting would** — the Library's
    /// Review Selected among them, so a control is offered over exactly what the sitting would ask.
    static func planner(_ day: StudyDay, _ now: Date, increaseToday: Int) -> SittingPlanner {
        SittingPlanner(studyDay: day, now: now, batchSize: batchSize, newCardsPerDay: newCardsPerDay,
                       increaseToday: increaseToday)
    }

    // MARK: - The end of a sitting

    /// **What the end of a sitting says beyond its own counts** (review-module-plan §8.4, WI-5), read
    /// once the last card is answered — from the ledger as the sitting left it, through the pure types:
    ///
    /// - **What's coming**: `Forecast` over the read a sitting is planned from, with the sitting's study
    ///   day and today's increase.
    /// - **Keeps slipping**: of the meanings this sitting's scheduled answers forgot, those the
    ///   Struggling filter lists — `repeatedlyLapsed`, R09's rule and its one SQL spelling, so the end
    ///   and Saved cannot disagree about a card. Named by the word the card showed. **Read, and nothing
    ///   written**: no card is paused, put off or rescheduled for it.
    /// - **Introduce more today**: offered for what today's allowance holds back, up to one day's base.
    ///
    /// A read that fails is said in `problem`, and the sitting's own counts are shown regardless.
    private func end(of session: ReviewSession) async -> ReviewPresentation.Finished {
        let summary = session.summary()
        guard let opening = store() else { return ReviewPresentation.Finished(summary: summary) }
        let planner = planner(studyDay, clock())
        do {
            let ledger = try await opening.value
            let candidates = try await ledger.sittingCandidates(dictionary: sittingScope,
                                                                introducedSince: planner.today)
            let forgotten = session.forgottenCards
            let struggling = forgotten.isEmpty
                ? [] : Set(try await ledger.repeatedlyLapsed(dictionary: sittingScope))
            var named = Set<UUID>(), slipping: [String] = []
            for card in forgotten where struggling.contains(card) && named.insert(card).inserted {
                if let word = try await ledger.cue(forCard: card)?.word { slipping.append(word) }
            }
            let heldBack = planner.reviewSitting(from: candidates).counts.heldBack
            return ReviewPresentation.Finished(
                summary: summary, forecast: Forecast(from: candidates, planner: planner), slipping: slipping,
                moreNewToday: min(heldBack, Self.newCardsPerDay))
        } catch {
            return ReviewPresentation.Finished(
                summary: summary,
                problem: String(localized: "What is coming could not be read: \(error.localizedDescription)",
                                comment: "Shown at the end of a review sitting when its forecast could not be read"))
        }
    }

    /// **Raises today's allowance by what the end offered, and draws a sitting with it** (WI-5).
    ///
    /// Synchronous up to the draw, and the offer is taken off the end before anything else: two presses
    /// arriving before the next sitting is drawn would otherwise raise it twice. The increase writes no
    /// ledger row and spends nothing — introductions spend the allowance (ADR-0037) — but every count
    /// of the queue changed with it, so the observers that refresh on a ledger change are told.
    private func introduceMoreToday() {
        guard case .finished(let end) = presentation.stage, end.moreNewToday > 0 else { return }
        increases.raise(by: end.moreNewToday, in: studyDayNow(), at: clock())
        presentation = ReviewPresentation(stage: .finished(ReviewPresentation.Finished(
            summary: end.summary, forecast: end.forecast, slipping: end.slipping, moreNewToday: 0,
            problem: end.problem)))
        LedgerChanges.shared.committed()
        Task { await start() }
    }

    /// **Out of the way until the next study day** (R05), and the surface advances only after the
    /// ledger has it — a card that disappeared from the sitting and was still due tomorrow evening
    /// would be the reader's "not today" silently ignored.
    ///
    /// The schedule is untouched. Saying "not this one, not now" is not saying anything about
    /// memory, so nothing here grades, and the daily allowance is unspent.
    private func postpone(_ attempt: UUID?) async {
        guard let session, let card = session.current, card.id == attempt, !writing,
              let opening = store() else { return }
        let until = studyDay.startOfNextDay(containing: clock())
        writing = true
        problem = nil
        if let cue { render(cue, in: session) }
        do {
            let ledger = try await opening.value
            try await ledger.postpone(cardID: card.cardID, until: until)
            LedgerChanges.shared.committed()
            writing = false
            // **For this attempt, not for whatever is current now.** Two presses during the write
            // both arrive here; the second finds a different card in front of the reader and is
            // refused, instead of advancing the sitting past a card nobody was shown.
            self.session?.record(.postponed, for: attempt)
        } catch {
            writing = false
            // **Drawn on the card it failed on, and nothing more.** Drawing the card again went
            // through `draw`, which clears a card's problem before reading it — so the reason was
            // assigned and erased in the same breath, and "not today" looked like a press that did
            // nothing (audit-fix round 1).
            problem = String(localized: "It could not be hidden until tomorrow: \(error.localizedDescription)",
                             comment: "Shown on a review card when postponing it failed to save")
            if let cue, let session = self.session { render(cue, in: session) }
            return
        }
        await draw()
    }

    // MARK: - One card

    private func draw() async {
        guard let session else { return }
        guard let current = session.current else {
            let end = await end(of: session)
            // **Still this sitting's end**: a draw that began while the ledger was being read owns the
            // surface now, and an undo has put a card back in front of the reader.
            guard self.session == session else { return }
            presentation = ReviewPresentation(stage: .finished(end))
            return
        }
        answer = nil
        // **A failure belongs to the card it happened on.** Carried across, "That answer was not
        // saved" appeared on an untouched card the reader had merely skipped to.
        problem = nil
        guard let opening = store() else { return }
        let fetched: ReviewCue?
        // **A card the sitting holds revealed has its answer read with its cue** (audit-fix round 3, #4).
        // Undo keeps a revealed card revealed — the reader has seen the meaning, and hiding it would
        // pretend the attempt never happened — but this cleared the answer and read the cue alone, so the
        // card came back revealed with nothing on it. Only for that card: an unrevealed one reads no
        // answer, so C2 holds by construction. Applied under the same check as the cue, below. A failed
        // answer read is said on the card as `reveal` says it, and Reveal asks again — it is not a card
        // that could not be drawn.
        var revealedAnswer: ReviewAnswer?
        var answerProblem: String?
        let revision: Int?
        // **Why it can no longer be asked, if it cannot** (the final closing pass, finding 2): a card archived,
        // paused, put off or left unready since the sitting was drawn is never shown — the reader would
        // answer it and every grade would be refused. It leaves the sitting, and its end says why.
        let departure: Departure?
        do {
            let ledger = try await opening.value
            departure = try await ledger.departure(ofCard: current.cardID, at: clock())
            // **The revision first, then what is shown at it** — see `adopt`.
            revision = try await ledger.revision(ofCard: current.cardID)
            fetched = try await ledger.cue(forCard: current.cardID)
            if current.isRevealed {
                do {
                    revealedAnswer = try await ledger.revealed(cardID: current.cardID)
                } catch {
                    answerProblem = String(localized: "The answer could not be read: \(error.localizedDescription)",
                                           comment: "Shown on a review card when its answer could not be loaded")
                }
            }
        } catch {
            // **Only the read for the card still in front of the reader may say so.** A skip and an
            // undo while this read was pending put another card on screen, and this failure then
            // ended that sitting over a card nobody was shown (audit-fix round 1) — the same check
            // the success path makes below.
            guard self.session?.current?.id == current.id else { return }
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
        if let departure {
            self.session?.record(.left(departure), for: current.id)
            await draw()
            return
        }
        cue = fetched
        answer = revealedAnswer
        if let answerProblem { problem = answerProblem }
        guard let cue else {
            // A card whose cue cannot be built is skipped rather than shown blank: its note is in
            // repair, and the queue's own recheck will stop offering it.
            self.session?.record(.skipped, for: current.id)
            await draw()
            return
        }
        adopt(revision, for: current.id)
        if let session = self.session { render(cue, in: session) }
    }

    /// **A grade is compared against the revision of what the reader was shown** (closing pass after
    /// audit-fix round 3, #100). A sitting takes each card's revision when it is planned, and an answer
    /// write moves every card of its note (round 3, #10) — so a card whose answer the reader edited in
    /// Saved while Review held the sitting carried the new answer under the old revision, and every
    /// grade of it was refused for the rest of the sitting. So the draw and the reveal read the card's
    /// revision with the cue and the answer they show, and a card that moved is renewed at it as a new
    /// showing: a press made on the display before names the old one and is refused (WI-8).
    ///
    /// **The revision is read first.** A write landing between it and the data it goes with leaves the
    /// revision older than what is shown, which the commit then refuses and `askAgain` shows again — a
    /// race costs one refusal, never a grade against something nobody saw. **Never while a write is in
    /// flight**: that write names the showing, and renewing it would leave a grade the ledger kept that
    /// the sitting could not record.
    private func adopt(_ revision: Int?, for attempt: UUID) {
        guard !writing, let revision, let current = session?.current, current.id == attempt,
              current.revision != revision else { return }
        session?.renew(attempt, revision: revision)
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
        let revision: Int?
        do {
            let ledger = try await opening.value
            // **The revision first, then the answer it goes with** (#100) — `adopt`. The reveal is the
            // moment the reader sees what they will grade against.
            revision = try await ledger.revision(ofCard: current.cardID)
            fetched = try await ledger.revealed(cardID: current.cardID)
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
        adopt(revision, for: current.id)
        answer = fetched
        self.session?.reveal()
        if let cue, let session = self.session { render(cue, in: session) }
    }

    private func commit(_ grade: Grade, _ attempt: UUID?) async {
        guard let session, let current = session.current, let opening = store() else { return }
        guard current.id == attempt else { return }
        guard !writing else { return }
        writing = true
        problem = nil
        if let cue { render(cue, in: session) }
        do {
            // **The presentation's id is the idempotency key.** One showing is one attempt however
            // many times the write is retried, and a second showing of the same card is a new one.
            //
            // **Which call it goes to was decided when the card was drawn**, not here and not by the
            // sitting: a practice attempt that reached `grade` would move a schedule the reader was
            // told it would not, and a card that came due while on screen was still drawn as practice.
            switch current.mode {
            case .practice:
                try await opening.value.practise(cardID: current.cardID, grade,
                                                 eventID: current.id, at: clock())
            case .graded:
                try await opening.value.grade(cardID: current.cardID, grade, eventID: current.id,
                                              expectedRevision: current.revision, at: clock())
            }
            LedgerChanges.shared.committed()
            if current.mode == .graded { graded() }
            writing = false
            self.session?.record(.graded(grade), for: attempt)
            await draw()
        } catch ReviewError.staleRevision(let expected, let found) {
            await askAgain(current.id, refused: .staleRevision(expected: expected, found: found))
        } catch let refusal as ReviewError where refusal == .notEligible(current.cardID) || refusal == .noSuchCard(current.cardID) {
            // **Refused because the card can no longer be asked, not because the write failed** (the final
            // closing pass, finding 2). Kept on screen it was refused at every press for good; it leaves the
            // sitting, and the end says why.
            await leave(current.id, cardID: current.cardID, refused: refusal)
        } catch {
            writing = false
            // **Stays on screen.** The reader answered; if the ledger did not take it, silence would
            // leave them believing it did — and the card would never come back to be answered again.
            // **"Not recorded", never "not saved"**: *saved* is a meaning put into study, which this
            // card's meaning is whatever became of the answer (AGENTS.md).
            problem = String(localized: "That answer was not recorded: \(error.localizedDescription)",
                             comment: "Shown on a review card when the grade could not be written")
            if let cue, let session = self.session { render(cue, in: session) }
        }
    }

    /// **A card no grade will be taken for leaves the sitting**, named by why (the final closing pass,
    /// finding 2). ADR-0032's "a failed grade keeps its card on screen and says so" is about a write that
    /// failed and may succeed when pressed again; a card archived, paused, put off or left unready since it
    /// was drawn will be refused at every press, so keeping it held the reader at one card for good.
    ///
    /// **Why is read, not assumed**: the refusal says only that it is not eligible. A card eligible again by
    /// the time it is read — a put-off that has just run out — is no card to let go: it stays, and says the
    /// answer was not recorded, as any refusal does, so the next press is taken. Still writing until then.
    private func leave(_ attempt: UUID, cardID: UUID, refused: ReviewError) async {
        let departure: Departure?
        do {
            departure = try await store()?.value.departure(ofCard: cardID, at: clock())
        } catch {
            departure = nil
        }
        writing = false
        guard self.session?.current?.id == attempt else { return }
        if let departure {
            self.session?.record(.left(departure), for: attempt)
            await draw()
            return
        }
        problem = String(localized: "That answer was not recorded: \(refused.localizedDescription)",
                         comment: "Shown on a review card when the grade could not be written")
        if let cue, let session = self.session { render(cue, in: session) }
    }

    /// **A grade refused as stale is asked again, of the card as it is now** (closing pass after audit-fix
    /// round 3, #100). ADR-0031 refuses it — the grade was about the card as it was, and something wrote
    /// to it since the reader last saw it — and `ReviewError.staleRevision` says the caller must read the
    /// card again. So the card stays on screen and says the answer was not recorded (ADR-0032), as for any
    /// failed grade, but drawn as it is now: its revision, its cue and, where the reader had asked for it,
    /// its answer — a meaning edited under a revealed card is shown, never graded as it was. A new showing
    /// (`adopt`), so the grade given the old one and any press made on it reach nothing (WI-8). Before, the
    /// card kept the old revision and the old meaning, and every attempt was refused for good.
    ///
    /// **Still writing until it is drawn**: nothing may answer a card before it is shown as it is. A card
    /// that cannot be read any more keeps the refusal, said as any other — and the next grade asks again.
    private func askAgain(_ attempt: UUID, refused: ReviewError) async {
        guard let current = session?.current, current.id == attempt, let opening = store() else {
            writing = false
            return
        }
        var revision: Int?, shown: ReviewCue?, meaning: ReviewAnswer?, departure: Departure?
        do {
            let ledger = try await opening.value
            // **A card that moved because it left study is not shown again** (the final closing pass,
            // finding 2): a bulk pause moves the revision, so its grade is refused as stale first — and shown
            // again, every grade then refused as not eligible.
            departure = try await ledger.departure(ofCard: current.cardID, at: clock())
            revision = try await ledger.revision(ofCard: current.cardID)
            shown = try await ledger.cue(forCard: current.cardID)
            if current.isRevealed { meaning = try await ledger.revealed(cardID: current.cardID) }
        } catch {
            revision = nil
        }
        writing = false
        guard self.session?.current?.id == attempt else { return }
        if let departure {
            self.session?.record(.left(departure), for: attempt)
            await draw()
            return
        }
        if let revision, let shown {
            adopt(revision, for: attempt)
            cue = shown
            answer = meaning
            problem = String(localized: "That answer was not recorded: the card changed after it was shown. It is shown again as it is now.",
                             comment: "Shown on a review card whose grade was refused because the card was changed elsewhere, such as its answer edited, after it was drawn")
        } else {
            problem = String(localized: "That answer was not recorded: \(refused.localizedDescription)",
                             comment: "Shown on a review card when the grade could not be written")
        }
        if let cue, let session = self.session { render(cue, in: session) }
    }

    private func undo() async {
        guard let session, !writing, let opening = store() else { return }
        guard let last = session.presentations.last(where: { $0.isAnswered }) else { return }
        // **A write of its own**, even for a skip that wrote nothing: it moves the sitting back, and a
        // grade landing after that is recorded against a card the sitting has left.
        writing = true
        if let cue { render(cue, in: session) }
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
                let ledger = try await opening.value
                try await ledger.postpone(cardID: last.cardID, until: nil)
                LedgerChanges.shared.committed()
                // **Read back, as for a grade.** Postponing and taking it back each moved the
                // revision, and the card brought back was refused as stale when answered.
                restored = try await ledger.revision(ofCard: last.cardID)
            // A card that left is never `last`: `isAnswered` passes over it, as Undo must.
            case .skipped, .left, .none:
                break
            }
        } catch {
            writing = false
            problem = String(localized: "That could not be taken back: \(error.localizedDescription)",
                             comment: "Shown when undoing a review or a postponement failed")
            // **Drawn, or the reason is invisible.** The view observes `presentation`; assigning
            // `problem` and returning left the old presentation on screen, so a failed undo
            // looked exactly like one the reader had not pressed. **At the end of a sitting there is
            // no card to draw it on** (audit-fix round 2), so it goes on the summary — `render` draws
            // only a card, and the undo there failed in silence.
            if let session = self.session, session.current == nil, case .finished(let end) = presentation.stage {
                presentation = ReviewPresentation(stage: .finished(ReviewPresentation.Finished(
                    summary: end.summary, forecast: end.forecast, slipping: end.slipping,
                    moreNewToday: end.moreNewToday, problem: problem)))
            } else if let cue, let session = self.session {
                render(cue, in: session)
            }
            return
        }
        writing = false
        self.session?.undoLast(revision: restored)
        await draw()
    }

    private func render(_ cue: ReviewCue, in session: ReviewSession) {
        guard let current = session.current else { return }
        presentation = ReviewPresentation(stage: .asking(ReviewPresentation.Question(
            showing: current.id,
            word: cue.word, accentKey: cue.lemma, exploreTerm: Self.explorationTerm(of: cue),
            // **No sentence where the capture did not get one.** The ledger stores the selection
            // itself when nothing surrounded the word, and drawing that as context would be the
            // word echoed back and dressed as the reader's own reading.
            sentence: Self.sentence(of: cue),
            source: Self.source(of: cue),
            position: session.cursor + 1, batchSize: session.presentations.count,
            // **Per card**: a Selected sitting holds both modes, and each says which it is.
            isPractice: current.mode == .practice,
            answer: current.isRevealed ? answer.map {
                ReviewPresentation.Answer(text: $0.text, dictionary: $0.dictionary.flatMap(dictionaryName))
            } : nil,
            isCommitting: writing, problem: problem)))
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
