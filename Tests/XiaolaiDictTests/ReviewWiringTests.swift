import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
@testable import StudyKit
import Testing
@testable import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The Review window against a real ledger.** WI-004's wire.
///
/// `ReviewSessionTests` proves the rules of a sitting and `StudyReviewTests` proves the transaction;
/// both would pass over a window that writes nothing. These assert the two things only the wire can
/// be wrong about: that a grade reaches the ledger, and that the answer does not reach the reader
/// before they ask for it.
@MainActor
struct ReviewWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) { Wiring.scratch("review") }

    /// A ledger with `count` cards ready to be asked, and the model pointed at it.
    ///
    /// `inProgress` answers each card once an hour ago, which is what makes it *due* rather than
    /// *new*. The distinction is load-bearing since C08: new cards are rationed by the daily
    /// allowance, so a fixture that wants to measure anything else — the batch bound, the backlog —
    /// must not be made of them.
    private func sentence(_ index: Int) -> String { "He paid the fine\(index) today." }

    @discardableResult
    private func ready(_ path: String, count: Int = 1, inProgress: Bool = false) throws -> Ledger {
        let ledger = try Ledger(path: path)
        var enrolled: [UUID] = []
        for index in 0..<count {
            let lookup = try ledger.record(LookupRecord(
                surface: "fine\(index)", lemma: "fine\(index)",
                context: sentence(index), lemmaBasis: .tagger, language: "en",
                // **Derived, never counted by hand.** A fixed length of 5 truncated `fine10`
                // onwards to `fine1`, so the backlog fixtures were pointing the range at a word
                // the sentence does not contain.
                contextRange: (sentence(index) as NSString).range(of: "fine\(index)"),
                place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", document: nil,
                                    page: nil, title: "A page", rawTitle: "A page"),
                lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
                quality: .accessibility(.accessibilityTextMarkers, context: .complete)))
            let note = try ledger.enroll(
                .sense(dictionary: "noad", entryID: "e\(index)", senseKey: "e\(index).001",
                       senseKeyKind: .publisher),
                issuer: .live, language: "en", chosenBy: .reader,
                answer: StudyAnswer(origin: .dictionary, text: "a penalty, sense \(index)"),
                lookupID: lookup, at: now)
            enrolled.append(note.id)
        }
        if inProgress {
            let scheduler = try MemoryScheduler()
            let anHourAgo = now.addingTimeInterval(-3_600)
            for id in enrolled {
                let card = try ledger.card(of: id, at: now)
                _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(),
                                     expectedRevision: card.revision, at: anHourAgo,
                                     using: scheduler)
            }
        }
        return ledger
    }

    private func model(_ path: String, clock: Date? = nil, named: Bool = true) -> ReviewModel {
        let when = clock ?? now
        return ReviewModel(store: Wiring.store(path),
                           primary: { PrimaryDictionary(chosen: "noad") },
                           dictionaryName: { key in named && key == "noad" ? "New Oxford American Dictionary" : nil },
                           clock: { when }, defaults: TemporaryDefaults.suite())
    }

    private func question(_ model: ReviewModel) -> ReviewPresentation.Question? {
        guard case .asking(let question) = model.presentation.stage else { return nil }
        return question
    }

    // MARK: - The answer is not there until it is asked for

    /// **C2, at the boundary the view draws from.** Before the reveal the answer is `nil` — not
    /// hidden, not zero-height, not behind an `opacity(0)`. There is nothing in the presentation to
    /// render, so there is nothing in the layout and nothing for VoiceOver.
    @Test func theanswerIsAbsentFromThePresentationUntilTheReaderAsks() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path)
        let model = model(path)
        await model.start()

        let front = try #require(question(model))
        #expect(front.answer == nil, "the answer reached the front of the card")
        #expect(front.word == "fine0")
        #expect(front.sentence?.text == "He paid the fine0 today.", "the cue is the reader's own sentence")

        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        let back = try #require(question(model))
        #expect(back.answer?.text == "a penalty, sense 0")
        // **By the dictionary's name, never its key.** The key is a bundle identifier: a revealed
        // answer was signed "com.apple.dictionary.zh_CN-en.OCD" (E2E Mac, 2026-10-02).
        #expect(back.answer?.dictionary == "New Oxford American Dictionary", "a card attributes its answer")
    }

    /// **A dictionary whose name cannot be found signs nothing.** It may have been switched off
    /// since the meaning was saved; its key is an identifier and never a fallback for its name.
    @Test func anAnswerFromADictionaryWithNoNameIsNotSignedWithItsKey() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path)
        let model = model(path, named: false)
        await model.start()
        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        let back = try #require(question(model))
        #expect(back.answer?.text == "a penalty, sense 0")
        #expect(back.answer?.dictionary == nil)
    }

    /// A capture that produced no real sentence shows none. The ledger stores the selection itself
    /// when nothing surrounded the word, and drawing that as context would be the word echoed back
    /// and dressed as the reader's own reading.
    @Test func acaptureWithNoSentenceShowsNone() throws {
        func cue(sentence: String?, quality: CaptureQuality?) -> ReviewCue {
            ReviewCue(card: StudyCard(noteID: UUID(), createdAt: now), word: "fine",
                      sentence: sentence, range: nil,
                      place: ReadingPlace(bundleID: nil, name: nil), readAt: now,
                      quality: quality, target: .entry(dictionary: "noad", entryID: "e1"))
        }
        // **One reason at a time.** The original fixture set `.missing` *and* made the sentence
        // equal the word, so either guard alone satisfied it and removing the other went
        // unnoticed. Each of the three reasons is now its own case, with a real sentence where
        // the reason is the quality, and a real quality where the reason is the sentence.
        let complete = CaptureQuality.accessibility(.accessibilityTextRange, context: .complete)
        #expect(ReviewModel.sentence(of: cue(sentence: "He paid the fine.",
                                             quality: .accessibility(.accessibilityTextRange,
                                                                     context: .missing))) == nil,
                "a capture that exposed no surrounding text has no sentence to draw")
        #expect(ReviewModel.sentence(of: cue(sentence: "fine", quality: complete)) == nil,
                "the word echoed back is not the reader's reading")
        #expect(ReviewModel.sentence(of: cue(sentence: "He paid the fine.", quality: nil)) == nil,
                "no quality signal at all shows no sentence")
        // And the positive control: a real sentence with a real quality is drawn.
        #expect(ReviewModel.sentence(of: cue(sentence: "He paid the fine.",
                                             quality: complete))?.text == "He paid the fine.")
    }

    // MARK: - The grade reaches the ledger

    @Test func agradeIsWrittenAndTheSurfaceMovesOn() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path, count: 2)
        let model = model(path)
        await model.start()
        #expect(question(model)?.position == 1)
        // Which card is actually on screen, so the assertions below are about that one.
        let shownWord = try #require(question(model)?.word)
        let opened = try Ledger(path: path)
        let shown = try #require(
            try opened.notes().compactMap { try opened.existingCard(of: $0.id) }
                .first { try opened.cue(forCard: $0.id)?.word == shownWord }).id

        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }

        let ledger = try Ledger(path: path)
        let cards = try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                      newAllowance: .max, dayStart: .distantPast)
        let reviewed = try ledger.notes().compactMap { try ledger.card(of: $0.id, at: self.now) }
            .flatMap { try ledger.reviews(ofCard: $0.id) }
        #expect(reviewed.count == 1, "the grade never reached the ledger")
        #expect(reviewed.first?.grade == .good)
        #expect(cards.count == 1, "and the card it graded is no longer due")
        // **The card that was on screen**, not merely one of the two. Counting a review and a
        // remaining due card was satisfied by grading the other one.
        #expect(reviewed.first?.cardID == shown, "the grade landed on the card nobody was shown")
        #expect(cards.first?.id != shown, "and the graded card is the one that left the queue")
    }

    /// **The surface advances after the write, never before.** A model that moved on while the grade
    /// was in flight would let a reader finish a batch of ten believing ten are saved when nine are.
    @Test func afailedGradeKeepsTheCardAndSaysSo() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path)
        let model = model(path)
        await model.start()
        let before = try #require(question(model))

        // **A write that fails** — the ledger refuses the event itself, as a full disk or a locked file
        // would. This test archived the note until the final closing pass (finding 2); a card that can no
        // longer be asked now leaves the sitting (`aWordCardReplacedUnderTheSittingLeavesItWhenGraded`), and
        // ADR-0032's rule is about a write that may be taken when pressed again.
        let note = try #require(try ledger.notes().first)
        try ledger.run("CREATE TRIGGER fail_grade BEFORE INSERT ON review_events BEGIN SELECT RAISE(ABORT, 'injected'); END",
                       bind: []) { _ in }

        model.act(.grade(.good))
        try await settle { self.question(model)?.problem != nil }
        let after = try #require(question(model))
        #expect(after.position == before.position, "the surface moved on over a failed write")
        #expect(after.problem != nil, "and said nothing about it")
        // **"Not recorded", never "not saved"** (AGENTS.md): *saved* is the word for a meaning put into
        // study, and this card's meaning is saved whatever became of the answer.
        #expect(after.problem?.hasPrefix("That answer was not recorded: ") == true, "\(after.problem ?? "")")
        let reopened = try Ledger(path: path)
        let card = try reopened.card(of: note.id, at: now)
        #expect(try reopened.reviews(ofCard: card.id).isEmpty)
    }

    /// Undo takes the grade back in the ledger *and* puts the card back in front of the reader.
    @Test func undoVoidsTheEventAndReturnsTheCard() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path, count: 2)
        let model = model(path)
        await model.start()
        let first = try #require(question(model))
        #expect(!model.canUndo, "a sitting nothing has been answered in has nothing to undo")
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }

        // **Undo is offered exactly while there is an answer to take back**: the toolbar item is
        // present on this and absent otherwise, where it was an invisible button on a key.
        #expect(model.canUndo)
        model.act(.undo)
        try await settle { self.question(model)?.position == 1 }
        #expect(question(model)?.word == first.word)
        #expect(!model.canUndo, "nothing is left to take back, so nothing offers to")

        let ledger = try Ledger(path: path)
        let events = try ledger.notes().compactMap { try ledger.card(of: $0.id, at: self.now) }
            .flatMap { try ledger.reviews(ofCard: $0.id) }
        #expect(events.count == 1)
        #expect(events.first?.isVoid == true, "the event is voided, not deleted")
    }

    /// **A card brought back by undo shows the meaning the reader had already seen** (audit-fix round 3,
    /// #4). The sitting keeps a revealed card revealed across an undo — hiding it again would pretend the
    /// attempt never happened — but the draw cleared the answer and read only the cue, so the card came
    /// back revealed with nothing to show and the meaning had to be asked for a second time. The answer
    /// is read again for the card brought back, and only for it.
    @Test func undoingARevealedCardBringsItsAnswerBack() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path, count: 2)
        let model = model(path)
        await model.start()
        let first = try #require(question(model))

        // **The control first**: a card graded without its meaning comes back without it (C2).
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }
        model.act(.undo)
        try await settle { self.question(model)?.position == 1 }
        #expect(question(model)?.answer == nil, "undo revealed a meaning the reader never asked for")

        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        let seen = try #require(question(model)?.answer)
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }
        #expect(question(model)?.answer == nil, "the next card arrived with an answer nobody asked for")

        model.act(.undo)
        try await settle { self.question(model)?.position == 1 }
        #expect(question(model)?.word == first.word)
        try await Wiring.settle("the card brought back is revealed and shows nothing") {
            self.question(model)?.answer != nil
        }
        #expect(question(model)?.answer == seen, "the card brought back shows another meaning")
    }

    /// **An undo that fails on the finished summary says so there** (audit-fix round 2). The reason was
    /// drawn onto the card in front of the reader, and at the end there is none — so the failure was
    /// assigned and never shown, and Undo looked like a key that did nothing.
    @Test func anUndoThatFailsAtTheEndOfASittingSaysSo() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path, count: 1)
        let model = model(path)
        await model.start()
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { true } else { false } }
        // Taken back already, elsewhere: this undo has nothing left to void.
        let card = try #require(try ledger.notes().first.flatMap { try ledger.existingCard(of: $0.id) })
        try ledger.undoLatestReview(ofCard: card.id, at: now)
        try #require(model.canUndo)
        model.act(.undo)
        try await settle {
            if case .finished(let end) = model.presentation.stage { end.problem != nil } else { false }
        }
        guard case .finished(let end) = model.presentation.stage else { return }
        #expect(end.problem?.isEmpty == false, "the failed undo was not said on the summary")
    }

    /// **A practice sitting freezes the study day too** (audit-fix round 2). It never did, so "not
    /// today" in practice put a card off until the next day of whatever zone the last *review* sitting
    /// had frozen — a reader who had travelled since had it come back at another zone's 04:00.
    @Test func practiceFreezesTheStudyDayItIsDrawnIn() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path, count: 1, inProgress: true)
        let tokyo = StudyDay(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let newYork = StudyDay(timeZone: try #require(TimeZone(identifier: "America/New_York")))
        let day = Travelling(tokyo)
        let model = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                clock: { self.now }, studyDay: { day.now }, defaults: TemporaryDefaults.suite())
        await model.start()
        try #require(question(model) != nil, "the review sitting drew nothing")
        day.now = newYork
        await model.startPractice()
        try #require(question(model)?.isPractice == true, "the practice sitting drew nothing")
        model.act(.postpone)
        let card = try #require(try ledger.notes().first.flatMap { try ledger.existingCard(of: $0.id) })
        try await settle { (try? ledger.card(id: card.id))??.hiddenUntil != nil }
        #expect(try ledger.card(id: card.id)?.hiddenUntil == newYork.startOfNextDay(containing: now),
                "put off until another zone's next study day")
        #expect(tokyo.startOfNextDay(containing: now) != newYork.startOfNextDay(containing: now),
                "the control: the two zones' next study days differ")
    }

    /// The reader's study day, which a test can move to another zone after the model captured it.
    @MainActor private final class Travelling {
        var now: StudyDay
        init(_ now: StudyDay) { self.now = now }
    }

    /// **Two different nothings.** A reader with no saved meanings is not a reader who is up to date,
    /// and telling them "nothing is due" reads as a feature that does not work.
    @Test func anEmptyLedgerAndAnEmptyQueueAreDifferentStates() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try Ledger(path: path)
        let empty = model(path)
        await empty.start()
        #expect(empty.presentation.stage == .empty(.nothingEnrolled))

        let (second, cleanSecond) = scratch()
        defer { cleanSecond() }
        let ledger = try ready(second)
        let card = try ledger.card(of: try #require(try ledger.notes().first).id, at: now)
        try ledger.postpone(cardID: card.id, until: now.addingTimeInterval(86_400))
        let upToDate = model(second)
        await upToDate.start()
        #expect(upToDate.presentation.stage == .empty(.nothingDue))
    }

    /// The end of a batch reports what it did **and what it did not**: a sitting is bounded, the
    /// reader's debt is not, and "all done" over a backlog is the one thing this may never say.
    @Test func thefinishedBatchKeepsTheBacklogVisible() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: ReviewModel.batchSize + 3, inProgress: true)
        let model = model(path)
        await model.start()
        #expect(question(model)?.batchSize == ReviewModel.batchSize)

        // **Wait for each grade to land before giving the next**, exactly as the reader does. The
        // model refuses a second grade while one is in flight — the buttons are disabled for the
        // same reason — so a loop that fires ten presses at once measures the guard, not the batch.
        for index in 0..<ReviewModel.batchSize {
            model.act(.grade(.good))
            let next = index + 2
            try await settle {
                if case .finished = model.presentation.stage { return true }
                return self.question(model)?.position == next
            }
        }
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.graded == ReviewModel.batchSize)
        #expect(summary.stillDue == 3, "three did not fit and must stay visible")
    }

    /// **The window rations first introductions** (C08). `NewCardAllowanceTests` proves the ledger
    /// can cap them; this proves the window asks it to. A model that passed `.max` — the shape every
    /// test below the wire uses — would satisfy every one of those and still hand a reader who saved
    /// thirty words thirty cards on their first evening, and thirty reviews the next.
    @Test func afirstSittingIsRationedToTheDailyAllowance() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: ReviewModel.newCardsPerDay + 8)
        let model = model(path)
        await model.start()
        #expect(question(model)?.batchSize == ReviewModel.newCardsPerDay,
                "\(ReviewModel.newCardsPerDay + 8) saved, \(ReviewModel.newCardsPerDay) allowed today")

        for index in 0..<ReviewModel.newCardsPerDay {
            model.act(.grade(.good))
            let next = index + 2
            try await settle {
                if case .finished = model.presentation.stage { return true }
                return self.question(model)?.position == next
            }
        }
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.stillDue == 0, "the eight beyond the allowance are tomorrow's, not a backlog")
        // **And the reader is told.** Eight words they saved going quiet with no sentence is
        // indistinguishable from eight words the app lost.
        #expect(summary.heldBack == 8)

        // **The allowance does not refill within the day.** Asking for another sitting on the same
        // clock must find nothing askable — and must say why, not "nothing is due".
        await model.start()
        #expect(model.presentation.stage == .empty(.heldBackUntilTomorrow(8)))
    }

    /// **The reader is asked in the planner's order, not the SQL queue's** (WI-2). Every card here
    /// was answered at one instant, so all are due at one instant — one study day's tie, which the
    /// queue breaks by card id and `SittingPlanner` by a shuffle seeded with the study day. A window
    /// still drawing from `dueCards` asks the same cards in the other order, and fails this.
    @Test func theSittingIsAskedInThePlannersOrder() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: ReviewModel.batchSize, inProgress: true)
        let ledger = try Ledger(path: path)
        let planner = SittingPlanner(studyDay: .standard, now: now, batchSize: ReviewModel.batchSize,
                                     newCardsPerDay: ReviewModel.newCardsPerDay)
        func words(_ cards: [StudyCard]) throws -> [String] {
            try cards.map { try #require(try ledger.cue(forCard: $0.id)).word }
        }
        let planned = try words(planner.reviewSitting(
            from: try ledger.sittingCandidates(dictionary: "noad", introducedSince: planner.today)).batch)
        let queued = try words(try ledger.dueCards(at: now, limit: ReviewModel.batchSize, dictionary: "noad",
                                                   newAllowance: ReviewModel.newCardsPerDay,
                                                   dayStart: planner.today))
        try #require(planned.count == ReviewModel.batchSize && Set(planned) == Set(queued),
                     "the fixture is not one batch of the same cards both ways")
        try #require(planned != queued, "the fixture cannot tell the planner's order from the queue's")

        let model = model(path)
        await model.start()
        var asked: [String] = []
        for index in 0..<ReviewModel.batchSize {
            asked.append(try #require(question(model)?.word, "card \(index + 1) was never asked"))
            model.act(.skip)
            let next = index + 2
            try await settle {
                if case .finished = model.presentation.stage { return true }
                return self.question(model)?.position == next
            }
        }
        #expect(asked == planned, "asked \(asked), planned \(planned), the SQL queue's \(queued)")
    }

    /// **"Not today" was a ledger method with no control** (R05). `postpone` — `hide` before the
    /// name collision that made the audit blind to it — put a card out of the way without touching
    /// its schedule, and no surface offered it.
    ///
    /// Distinct from Skip, which is what makes it worth having: a skipped card is still due today
    /// and the next batch can have it; a postponed one is gone until the next study day. A reader
    /// who cannot face a particular word this evening has no way to say so otherwise.
    @Test func acardCanBePutOffUntilTheNextStudyDay() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()
        let first = try #require(question(model)?.word)

        // What the schedule is before it is put off, so "untouched" is a comparison.
        let opened = try Ledger(path: path)
        let target = try #require(
            try opened.notes().compactMap { try opened.existingCard(of: $0.id) }
                .first { try opened.cue(forCard: $0.id)?.word == first })
        let beforePostponing = target.scheduled

        model.act(.postpone)
        try await settle { self.question(model)?.word != first }

        // Gone from today, and said so at the end of the batch.
        model.act(.grade(.good))
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.postponed == 1)
        #expect(summary.skipped == 0, "a postponement is not a skip")

        // **Not due again today**, which is the difference from Skip.
        await model.start()
        #expect(model.presentation.stage == .empty(.nothingDue))

        // **Back at the next study day's cutoff, and not before** — a rolling 24-hour
        // postponement satisfied "25 hours later" without ever using the boundary. And the
        // schedule must be exactly what it was: putting a card off says nothing about memory.
        let reopened = try Ledger(path: path)
        let held = try #require(
            try reopened.library(LibraryQuery(now: now)).compactMap {
                try reopened.existingCard(of: $0.id)
            }.first { $0.hiddenUntil != nil })
        let boundary = StudyDay.standard.startOfNextDay(containing: now)
        #expect(held.hiddenUntil == boundary, "put off to a rolling 24 hours, not to the cutoff")
        #expect(held.scheduled == beforePostponing, "putting a card off moved its schedule")

        // A minute before the boundary it is still away; a minute after, it is back.
        let justBefore = self.model(path, clock: boundary.addingTimeInterval(-60))
        await justBefore.start()
        #expect(question(justBefore)?.word != first, "it came back before the cutoff")

        let tomorrow = self.model(path, clock: boundary.addingTimeInterval(60))
        await tomorrow.start()
        #expect(question(tomorrow)?.word == first)
    }

    /// **A card graded again after an undo must land.** Undo is itself a write, so the ledger
    /// card's revision has moved twice by the time the reader answers the restored card — once
    /// for the grade, once for taking it back. The session kept the revision the card was *drawn*
    /// at, so the second grade was refused as stale and the reader could not answer a card they
    /// had deliberately gone back to.
    @Test func acardCanBeGradedAgainAfterAnUndo() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 1, inProgress: true)
        let model = model(path)
        await model.start()
        let word = try #require(question(model)?.word)

        model.act(.grade(.good))
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        model.act(.undo)
        try await settle { self.question(model)?.word == word }

        model.act(.grade(.good))
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.graded == 1, "the re-grade landed")
        #expect(question(model)?.problem == nil)

        // And the ledger has exactly one live event for it: the first was voided, not replaced.
        let reopened = try Ledger(path: path)
        let card = try #require(try reopened.dueCards(
            at: now.addingTimeInterval(-1), limit: 10, dictionary: nil,
            newAllowance: .max, dayStart: .distantPast).first
            ?? reopened.library(LibraryQuery()).first.flatMap { try reopened.existingCard(of: $0.id) })
        // The fixture's own `.again` — what made the card due — is a live grade too, so the claim
        // is about what this sitting did: the undone attempt is voided, the replacement is not,
        // and the replacement did not land twice.
        let all = try reopened.reviews(ofCard: card.id)
        #expect(all.filter(\.isVoid).count == 1,
                "exactly the undone attempt is voided — all: \(all.map { "\($0.kind) void=\($0.isVoid)" })")
        #expect(all.last?.isVoid == false, "the replacement is live")
        #expect(all.count == 3, "setup grade, the attempt taken back, and its replacement")
    }

    /// **One press, one card.** "Not today" writes to the ledger before the session advances, so
    /// a second press during that window found no guard: both completions advanced the sitting
    /// and the reader lost a card they were never shown. Grading has a guard; this did not, and
    /// the button is only disabled while a *grade* is in flight.
    @Test func twopressesOfNotTodayTakeOneCard() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 3, inProgress: true)
        let model = model(path)
        await model.start()
        let first = try #require(question(model)?.word)
        #expect(question(model)?.position == 1)

        model.act(.postpone)
        model.act(.postpone)
        try await settle { self.question(model)?.word != first }
        // Settled: whatever is on screen is stable now.
        try await Task.sleep(for: .milliseconds(200))
        #expect(question(model)?.position == 2, "the sitting advanced by two presses, not one card")

        // And only the card that was on screen was put off.
        let reopened = try Ledger(path: path)
        let held = try reopened.library(LibraryQuery(now: now)).compactMap {
            try reopened.existingCard(of: $0.id)
        }.filter { $0.hiddenUntil != nil }
        #expect(held.count == 1, "put off \(held.count) cards on one press")
    }

    /// **No card ever shows another card's answer.** C2's rule is that the surface does not
    /// answer the question unasked; showing the *wrong* answer unasked is the same rule broken
    /// twice. Reveal fetches for the card in front of the reader and applies the result after an
    /// await, so a skip in that window put the previous card's meaning on the next one.
    ///
    /// **Reproducible, three times out of three**, once the attempt is captured at the right
    /// moment: reading `session.current` *inside* the task is too late, because a `Task` body
    /// does not run where it is created and the skip lands first. Reverting the capture to inside
    /// the task fails this test every run.
    @Test func revealingThenSkippingDoesNotCarryTheAnswerOver() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()
        let first = try #require(question(model))
        #expect(first.answer == nil)

        model.act(.reveal)
        model.act(.skip)
        try await settle { self.question(model)?.word != first.word }
        try await Task.sleep(for: .milliseconds(200))

        let next = try #require(question(model))
        #expect(next.word != first.word, "the skip took")
        #expect(next.answer == nil,
                "the next card is showing an answer nobody asked for: \(next.answer?.text ?? "")")
    }

    /// **An answer belongs to the card on screen when it was given** (WI-8). A skip advances the
    /// sitting at once, and the next card is drawn only after its cue is read — so a grade pressed in
    /// between reached the card the sitting had moved to, which the reader had never seen, and graded
    /// it. Two fresh presses, not a held key: `S` then `2`, and `S` then `S`, before the redraw.
    @Test func anActionBeforeTheRedrawAppliesToTheCardOnScreen() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 3, inProgress: true)
        let model = model(path)
        await model.start()
        let shown = try #require(question(model))
        #expect(shown.position == 1)

        model.act(.skip)
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(question(model)?.position == 2, "the grade went to a card nobody was shown, and moved past it")
        let ledger = try Ledger(path: path)
        let graded = try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }
            .flatMap { try ledger.reviews(ofCard: $0.id) }.filter { !$0.isVoid && $0.reviewedAt >= now }
        #expect(graded.isEmpty, "a grade pressed on the skipped card was written to \(graded.count) other card(s)")

        // Two skips before the redraw skip the one card on screen, not the one after it as well.
        let second = try #require(question(model))
        model.act(.skip)
        model.act(.skip)
        try await settle { self.question(model)?.position == 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(question(model)?.position == 3, "a second skip took a card nobody was shown")
        #expect(question(model)?.word != second.word)

        // **The control**: once the redraw has happened, the same press grades the card it shows.
        model.act(.grade(.good))
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        let landed = try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }
            .flatMap { try ledger.reviews(ofCard: $0.id) }.filter { !$0.isVoid && $0.reviewedAt >= now }
        #expect(landed.count == 1)
    }

    /// **The E2E stage's held key, in process: keys through the window's own shortcuts, into this model
    /// and a real ledger** (WI-8 follow-up). On the E2E Mac a held `2` on a freshly drawn card wrote
    /// nothing: SwiftUI kept the shortcut's action from the card before, so the press named a card the
    /// sitting had left and was refused, and every repeat after it was refused as a repeat. Calling
    /// `act` or `press` from a test supplies the card itself and cannot see that. A skip draws the next
    /// card exactly as that write did — every button the same and enabled, only the card different — and
    /// does so every time, where a grade's write may or may not be drawn disabled on its way.
    @Test func aHeldKeyThroughTheWindowGradesTheCardItWasPressedOnOnce() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 3, inProgress: true)
        let model = model(path)
        await model.start()
        let keys = KeyboardHarness { ReviewSceneView(model: model).environment(\.pressingEvent, $0) }
        defer { keys.close() }
        let first = try #require(question(model))

        try keys.press(.s)
        try await settle { self.question(model)?.position == 2 }
        keys.render()
        let held = try #require(question(model))
        #expect(held.word != first.word, "S did not move past the first card")

        // The press that starts the hold, then the next card drawn while the key is still down, then
        // the repeats landing on it — the order the keyboard sends them in.
        try keys.press(.two)
        do {
            try await settle { self.question(model)?.position == 3 }
        } catch {
            Issue.record("the press that started the hold answered nothing: \(question(model)?.word ?? "-") is still asked")
            throw error
        }
        keys.render()
        try keys.repeats(.two, count: 5)
        try await Task.sleep(for: .milliseconds(200))

        let ledger = try Ledger(path: path)
        let written = try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }.flatMap { card in
            try ledger.reviews(ofCard: card.id).filter { !$0.isVoid && $0.reviewedAt >= now }
                .map { _ in try ledger.cue(forCard: card.id)?.word }
        }
        #expect(written == [held.word], "a held 2 on \(held.word) wrote grades for \(written)")
        #expect(question(model)?.position == 3, "the repeats answered the card after it")
    }

    /// **Not while its answer is being written** (WI-8, the same class). The grade is in flight on the
    /// card on screen; a skip or a "not today" pressed then is about that card too, and taking it would
    /// record the card skipped — or put off — over a grade the ledger then holds. The view disables
    /// both while it commits; the model must not depend on that.
    @Test func noOtherAnswerIsTakenWhileAGradeIsBeingWritten() async throws {
        for pressed in [ReviewAction.skip, .postpone] {
            let (path, clean) = scratch()
            defer { clean() }
            try ready(path, count: 3, inProgress: true)
            let gate = Gate()
            let opening = Wiring.store(path)
            let model = ReviewModel(store: {
                guard gate.closed, let held = opening() else { return opening() }
                return Task { await gate.wait(); return try await held.value }
            }, primary: { PrimaryDictionary(chosen: "noad") }, clock: { self.now }, defaults: TemporaryDefaults.suite())
            await model.start()
            let shown = try #require(question(model))

            gate.closed = true
            model.act(.grade(.good))
            try await settle { self.question(model)?.isCommitting == true }
            model.act(pressed)
            gate.closed = false
            try await settle { self.question(model)?.position == 2 }
            try await Task.sleep(for: .milliseconds(200))
            #expect(question(model)?.position == 2, "\(pressed) during the write took a second card")

            let ledger = try Ledger(path: path)
            let card = try #require(try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }
                .first { try ledger.cue(forCard: $0.id)?.word == shown.word })
            #expect(try ledger.reviews(ofCard: card.id).filter { !$0.isVoid && $0.reviewedAt >= now }.count == 1,
                    "\(pressed): the grade was not written")
            #expect(card.hiddenUntil == nil, "\(pressed): the card was put off over its own grade")
            model.act(.undo)
            try await settle { self.question(model)?.word == shown.word }
            #expect(try ledger.reviews(ofCard: card.id).filter { !$0.isVoid && $0.reviewedAt >= now }.isEmpty,
                    "\(pressed): the session did not record the grade it wrote, so undo could not take it back")
        }
    }

    /// A gate a test opens: while closed, a store reached through it waits.
    @MainActor private final class Gate {
        var closed = false
        func wait() async {
            while closed { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    /// **One store call, scripted**: the next call is held until released, refused, or both — every
    /// later one passes. A gate on every call cannot tell which of two waiting writes goes first; this
    /// holds exactly the one the test names.
    @MainActor private final class Rigged {
        enum Next { case pass, hold, fail, holdThenFail }
        struct Refused: Error {}
        var next = Next.pass
        var released = false

        func store(_ opening: @escaping @MainActor () -> Task<LedgerStore, any Error>?)
            -> @MainActor () -> Task<LedgerStore, any Error>? {
            { [self] in
                let mode = next
                next = .pass
                switch mode {
                case .pass: return opening()
                case .fail: return Task { throw Refused() }
                case .hold:
                    guard let held = opening() else { return nil }
                    return Task { await self.release(); return try await held.value }
                case .holdThenFail: return Task { await self.release(); throw Refused() }
                }
            }
        }

        private func release() async {
            while !released { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    private func rigged(_ path: String, _ rig: Rigged) -> ReviewModel {
        ReviewModel(store: rig.store(Wiring.store(path)), primary: { PrimaryDictionary(chosen: "noad") },
                    clock: { self.now }, defaults: TemporaryDefaults.suite())
    }

    /// **Undo waits for the write in flight** (audit-fix round 1). With the second card's grade being
    /// written, Undo reached for the last *recorded* answer — the first card's — voided it, and moved
    /// the sitting back; the grade then landed on a card the sitting had left, so the ledger kept a
    /// grade the session never recorded and no undo could take back. Two undos pressed together
    /// voided twice. Undo is not offered while anything is being written, and is refused if pressed.
    @Test func undoIsNeitherOfferedNorTakenWhileAWriteIsInFlight() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 3, inProgress: true)
        let rig = Rigged()
        let model = rigged(path, rig)
        await model.start()
        let first = try #require(question(model))
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }
        let second = try #require(question(model))

        rig.next = .hold
        model.act(.grade(.good))
        try await settle { self.question(model)?.isCommitting == true }
        #expect(!model.canUndo, "Undo is offered while a grade is being written")
        model.act(.undo)
        model.act(.undo)
        try await Task.sleep(for: .milliseconds(200))
        rig.released = true
        try await settle { self.question(model)?.position == 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(question(model)?.position == 3, "an undo pressed during the write moved the sitting")

        let ledger = try Ledger(path: path)
        func live(_ word: String) throws -> Int {
            let card = try #require(try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }
                .first { try ledger.cue(forCard: $0.id)?.word == word })
            return try ledger.reviews(ofCard: card.id).filter { !$0.isVoid && $0.reviewedAt >= now }.count
        }
        #expect(try live(first.word) == 1, "an undo pressed during the write took back the first card's grade")
        #expect(try live(second.word) == 1, "the second card's grade was not written")
        // **The control**: after the write, undo takes back the grade it wrote, and only that one.
        model.act(.undo)
        try await settle { self.question(model)?.word == second.word }
        #expect(try live(second.word) == 0, "the session did not record the grade it wrote")
        #expect(try live(first.word) == 1)
    }

    /// **A failed "not today" stays said** (audit-fix round 1). The failure was assigned and the card
    /// drawn again, and drawing a card clears its problem first — so the reader saw the card back with
    /// nothing to say why "not today" did nothing.
    @Test func aFailedPostponementKeepsTheCardAndSaysSo() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let rig = Rigged()
        let model = rigged(path, rig)
        await model.start()
        let before = try #require(question(model))
        rig.next = .fail
        model.act(.postpone)
        try await settle { self.question(model)?.problem != nil }
        try await Task.sleep(for: .milliseconds(200))
        let after = try #require(question(model))
        #expect(after.word == before.word && after.position == before.position)
        #expect(after.problem?.hasPrefix("It could not be hidden until tomorrow: ") == true, "\(after.problem ?? "nil")")
        #expect(!after.isCommitting, "the card's controls stayed disabled after the failure")
    }

    /// **A stale read that fails says nothing** (audit-fix round 1). A skip starts the next card's read;
    /// an undo then puts the skipped card back and draws it. The first read failing afterwards cleared
    /// the sitting on screen and said the ledger could not be read — about a card nobody is shown.
    @Test func aSupersededReadThatFailsLeavesTheSittingAlone() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 3, inProgress: true)
        let rig = Rigged()
        let model = rigged(path, rig)
        await model.start()
        let first = try #require(question(model))
        rig.next = .holdThenFail
        model.act(.skip)
        try await settle { model.canUndo }
        model.act(.undo)
        try await settle { self.question(model)?.showing != first.showing && self.question(model)?.word == first.word }
        rig.released = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(question(model)?.word == first.word, "a stale read's failure replaced the card on screen: \(model.presentation.stage)")
    }

    /// **Undoing "Not today" brings the card back today.** Undo reversed a grade in the ledger
    /// and a postponement only in the session, so the card returned to the sitting on screen and
    /// stayed hidden until tomorrow in every query behind it — the reader took the action back
    /// and it was still in force.
    @Test func undoingApostponementBringsTheCardBack() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()
        let first = try #require(question(model)?.word)

        model.act(.postpone)
        try await settle { self.question(model)?.word != first }
        model.act(.undo)
        try await settle { self.question(model)?.word == first }

        let reopened = try Ledger(path: path)
        let hidden = try reopened.library(LibraryQuery(now: now)).compactMap {
            try reopened.existingCard(of: $0.id)
        }.filter { $0.hiddenUntil != nil }
        #expect(hidden.isEmpty, "\(hidden.count) card(s) are still put off after the undo")
    }

    /// **A card brought back by undoing "Not today" can be answered.** Postponing moves the card's
    /// revision and so does taking it back, but the undo restored the revision the card was *drawn*
    /// at, as it did for a grade before `acardCanBeGradedAgainAfterAnUndo` — so the reader's answer
    /// to the card they had just brought back was refused as stale.
    @Test func aCardCanBeGradedAfterUndoingItsPostponement() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 1, inProgress: true)
        let model = model(path)
        await model.start()
        let word = try #require(question(model)?.word)

        model.act(.postpone)
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        model.act(.undo)
        try await settle { self.question(model)?.word == word }

        model.act(.grade(.good))
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return self.question(model)?.problem != nil
        }
        #expect(question(model)?.problem == nil,
                "the answer was refused: \(question(model)?.problem ?? "")")
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.graded == 1, "the grade after the undo landed")
    }

    // MARK: - An answer edited while the sitting is held (closing pass after audit-fix round 3, #100)

    /// Review and Saved over one store, as the app has them: a sitting held by one, an answer edited in
    /// the other.
    private func reviewAndSaved(_ path: String) -> (review: ReviewModel, saved: LibraryModel) {
        let store = Wiring.store(path)
        return (ReviewModel(store: store, primary: { PrimaryDictionary(chosen: "noad") },
                            clock: { self.now }, defaults: TemporaryDefaults.suite()),
                LibraryModel(store: store, clock: { self.now }, defaults: TemporaryDefaults.suite(),
                             primary: { PrimaryDictionary(chosen: "noad") }))
    }

    /// Writes the reader's own answer through Saved's editor, and waits for the ledger to hold it.
    private func edit(_ saved: LibraryModel, _ note: UUID, to text: String, in ledger: Ledger) async throws {
        saved.act(.setAnswer(noteID: note, text: text))
        try await Wiring.settle("Saved never wrote the edit") { (try? ledger.answer(of: note))?.text == text }
    }

    private func liveReviews(of note: UUID, in ledger: Ledger) throws -> Int {
        let card = try #require(try ledger.existingCard(of: note))
        return try ledger.reviews(ofCard: card.id).filter { !$0.isVoid && $0.reviewedAt >= now }.count
    }

    /// **An answer edited while the sitting is held is graded once the reader has seen it** (closing
    /// pass after round 3, #100). Round 3 made an answer write move every card of its note, so a grade
    /// drawn before an edit is refused — rightly. But a sitting takes each card's revision when it is
    /// planned and never read it again: the second card, whose answer the reader replaced in Saved
    /// before it came up, was revealed with the new answer under the old revision, and every grade of it
    /// was refused for the rest of the sitting. Its revision is read with what is shown of it.
    @Test func anAnswerEditedWhileTheSittingIsHeldIsGradedOnceSeen() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path, count: 2, inProgress: true)
        let (review, saved) = reviewAndSaved(path)
        await review.start()
        let first = try #require(question(review))
        let second = try #require(try ledger.notes().first { note in
            try ledger.existingCard(of: note.id).flatMap { try ledger.cue(forCard: $0.id) }?.word != first.word
        })

        try await edit(saved, second.id, to: "my own words", in: ledger)
        await review.resume()
        #expect(question(review)?.showing == first.showing, "returning to Review did not keep the sitting")
        review.act(.grade(.good))
        try await settle { self.question(review)?.position == 2 }
        review.act(.reveal)
        try await settle { self.question(review)?.answer != nil }
        #expect(question(review)?.answer?.text == "my own words", "the card did not show the edited answer")

        review.act(.grade(.good))
        try await Wiring.settle("the grade neither landed nor failed") {
            if case .finished = review.presentation.stage { return true }
            return self.question(review)?.problem != nil
        }
        #expect(question(review)?.problem == nil,
                "a grade given after seeing the edited answer was refused: \(question(review)?.problem ?? "")")
        #expect(try liveReviews(of: second.id, in: ledger) == 1, "the grade of the edited card was not written")
    }

    /// **A revealed card whose answer is edited under it is shown again as it is now, never graded as
    /// it was** (#100). The reader replaced the meaning on screen in Saved and came back: the grade they
    /// gave over the old meaning is refused (ADR-0031 — it was about a question that no longer exists),
    /// and the card stays on screen saying so (ADR-0032) — with the new meaning, as a new showing, so a
    /// press made on the old display is refused too (WI-8). Then it can be answered. Before, the old
    /// meaning stayed drawn and every attempt was refused as stale, for good.
    @Test func aRevealedCardWhoseAnswerIsEditedIsShownAgainAsItIsNow() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path, count: 1, inProgress: true)
        let (review, saved) = reviewAndSaved(path)
        await review.start()
        review.act(.reveal)
        try await settle { self.question(review)?.answer != nil }
        let seen = try #require(question(review))
        #expect(seen.answer?.text == "a penalty, sense 0")
        let note = try #require(try ledger.notes().first).id

        try await edit(saved, note, to: "my own words", in: ledger)
        await review.resume()
        review.act(.grade(.good))
        try await Wiring.settle("the grade over the replaced answer was neither refused nor recorded") {
            if case .finished = review.presentation.stage { return true }
            return self.question(review)?.problem != nil && self.question(review)?.isCommitting == false
        }
        #expect(try liveReviews(of: note, in: ledger) == 0, "a grade given over the replaced answer was recorded")
        let again = try #require(question(review), "the card left the screen over a refused grade")
        #expect(again.answer?.text == "my own words",
                "the card still shows the answer the reader replaced: \(again.answer?.text ?? "nil")")
        #expect(again.showing != seen.showing, "the card was not shown again, so a press on the old answer still names it")
        #expect(again.problem?.hasPrefix("That answer was not recorded: ") == true, "\(again.problem ?? "nil")")

        // A press made on the display that showed the replaced meaning answers nothing.
        review.act(.grade(.good), on: seen.showing)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try liveReviews(of: note, in: ledger) == 0, "a press on the display of the replaced answer graded the card")

        // **The control**: the card as it is now can be answered.
        review.act(.grade(.good))
        try await Wiring.settle("the card could not be graded once shown as it is now") {
            (try? self.liveReviews(of: note, in: ledger)) == 1
        }
        try await settle { if case .finished = review.presentation.stage { true } else { false } }
    }

    /// **Nothing renews a card while its grade is being written** (#100). The write names the showing it
    /// was pressed on. A reveal landing during it — Space then `2`, the reveal's read slower — that renewed
    /// the card at the revision it read left the write naming a showing the sitting no longer held: its
    /// refusal went unsaid with the card's controls still disabled, and a grade that landed instead could
    /// not have been recorded by the sitting at all. The reveal shows its answer and leaves the showing.
    @Test func aRevealDuringAGradesWriteLeavesTheShowingTheWriteNames() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try ready(path, count: 1, inProgress: true)
        let rig = Rigged()
        let model = rigged(path, rig)
        await model.start()
        let note = try #require(try ledger.notes().first).id
        try ledger.setReaderAnswer("my own words", of: note, at: now)

        rig.next = .hold
        model.act(.grade(.good))
        try await settle { self.question(model)?.isCommitting == true }
        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        rig.released = true
        try await Wiring.settle("the refused grade was never said, or the card's controls stayed disabled") {
            self.question(model)?.problem != nil && self.question(model)?.isCommitting == false
        }
        #expect(question(model)?.answer?.text == "my own words")
        #expect(try liveReviews(of: note, in: ledger) == 0, "a grade given before the edit was seen was recorded")
        model.act(.grade(.good))
        try await Wiring.settle("the card could not be graded once shown as it is now") {
            (try? self.liveReviews(of: note, in: ledger)) == 1
        }
    }

    /// **A collection that cannot be read is not a collection with nothing due.**
    ///
    /// Both drew the same screen, so a reader whose ledger failed to open was told they were up
    /// to date. The reason was even computed on that path and then dropped, because an empty
    /// stage had nowhere to carry it.
    @Test func aledgerThatCannotBeOpenedSaysSoRatherThanNothingDue() async throws {
        // A path that cannot be a database: a directory where the file should be.
        let scratch = TemporaryDirectory(named: "xiaolaidict-unopenable")
        let directory = scratch.url

        let model = ReviewModel(store: { Task { try LedgerStore(path: directory.path) } },
                                primary: { PrimaryDictionary(chosen: "noad") },
                                clock: { self.now }, defaults: TemporaryDefaults.suite())
        await model.start()
        guard case .empty(let reason) = model.presentation.stage else {
            Issue.record("expected an empty stage, got \(model.presentation.stage)")
            return
        }
        guard case .couldNotBeRead(let said) = reason else {
            Issue.record("a failed read drew \(reason), which reads as being up to date")
            return
        }
        #expect(!said.isEmpty, "and it says what went wrong")

        // Practice took the same path and discarded the error outright.
        await model.startPractice()
        guard case .empty(.couldNotBeRead) = model.presentation.stage else {
            Issue.record("practice drew \(model.presentation.stage) over a ledger it could not open")
            return
        }
    }

    /// **Skipping the last batch does not end the sitting.** A skipped card is still due, and
    /// `stillDue` counts only what did not fit — so skipping everything left work outstanding
    /// with no way to go on, and offered Practice instead, which grades nothing.
    @Test func skippingTheLastBatchStillOffersAnother() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()

        // Each skip is of the card on screen, so the second waits for the first's card to be drawn
        // (WI-8): pressed before the redraw, it would name a card the sitting had already left.
        for position in 1...2 {
            model.act(.skip)
            try await settle {
                if case .finished = model.presentation.stage { return true }
                return self.question(model)?.position == position + 1
            }
        }
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        let summary = end.summary
        #expect(summary.skipped == 2)
        #expect(summary.stillDue == 0, "nothing was left over — they were all skipped")
        // The control that must be there: work remains, so another batch must be offered.
        #expect(summary.skipped > 0, "and skipped work is work")
        #expect(summary.wasPractice == false)
    }

    /// A wait that never holds must end its test, not let everything after it run.
    @Test func awaitThatNeverHoldsStopsTheTest() async throws {
        await #expect(throws: WiringTimeout.self) {
            try await Wiring.settle("this never holds") { false }
        }
    }

    /// Waits for the condition, never for a duration: the model commits in a task of its own, so an
    /// `await` on the call returns before the ledger has anything.
    /// Forwards to the one shared wait — see `Wiring.settle`, which throws rather than
    /// letting everything after a missed state run anyway.
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        try await Wiring.settle("the model never reached the expected state", condition)
    }
    @Test func concurrentResumeAndPaneReturnPreserveRevealedQuestion() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path, count:2)
        let model = model(path)
        async let first: Void = model.resume()
        async let second: Void = model.resume()
        _ = await (first, second)
        let original = try #require(question(model))
        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        await model.resume()
        #expect(question(model)?.word == original.word)
        #expect(question(model)?.answer != nil)
    }


    /// **A held sitting belongs to the dictionary it was drawn from.** Returning to the pane keeps it
    /// (ADR-0044); switching the primary starts study over, so the sitting goes with it rather than
    /// asking the old dictionary's cards under the new one's name.
    /// What the reader changes while a test holds the model.
    @MainActor private final class Chosen {
        var key = "noad"
        var finished = 0
    }

    @Test func resumeStartsOverWhenThePrimaryChanged() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path)
        let chosen = Chosen()
        let model = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: chosen.key) },
                                clock: { self.now }, defaults: TemporaryDefaults.suite())
        await model.resume()
        #expect(question(model) != nil, "positive control: the noad sitting was drawn")
        await model.resume()
        #expect(question(model) != nil, "an unchanged primary keeps the sitting")
        chosen.key = "another"
        await model.resume()
        #expect(question(model) == nil, "the old dictionary's card survived the switch")
        #expect(model.presentation.stage == .empty(.nothingEnrolled))
    }

    // MARK: - Exploring a card after its meaning is showing

    /// What the model was asked to open, and whether the launch took.
    @MainActor private final class Opened {
        var terms: [String] = []
        var launches = true
    }

    private func exploring(_ path: String, _ opened: Opened) -> ReviewModel {
        ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                    clock: { self.now }, defaults: TemporaryDefaults.suite(),
                    openInDictionary: { term in opened.terms.append(term); return opened.launches })
    }

    /// **Before the reveal there is nothing to explore with.** Asking the dictionary about the word
    /// while the question is still open is looking the answer up; the button is absent then, and the
    /// model refuses too, so a key that reaches it by another route still answers nothing.
    @Test func exploringIsRefusedUntilTheMeaningIsShowing() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path)
        let opened = Opened()
        let model = exploring(path, opened)
        await model.start()
        model.act(.explore)
        #expect(opened.terms.isEmpty, "the dictionary was opened on a card whose question was still open")
        #expect(question(model)?.problem == nil, "a refusal is not a failure to say anything about")
        #expect(question(model)?.answer == nil)
    }

    /// **Exploring is not an answer.** It opens the word and nothing else: the card stays on screen
    /// with its meaning showing, no event is written, the schedule is what it was, and the sitting
    /// has not moved.
    @Test func exploringOpensTheWordAndChangesNothingAboutTheCard() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path, count: 2, inProgress: true)
        let opened = Opened()
        let model = exploring(path, opened)
        await model.start()
        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        let before = try #require(question(model))

        let ledger = try Ledger(path: path)
        let scheduleBefore = try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }.map(\.scheduled)
        let readingsBefore = try ["fine0", "fine1"].flatMap { try ledger.history(of: $0) }.count
        let eventsBefore = try ledger.notes().compactMap { try ledger.card(of: $0.id, at: now) }
            .flatMap { try ledger.reviews(ofCard: $0.id) }.count

        model.act(.explore)
        #expect(opened.terms == [before.exploreTerm], "one request, for the card's own word")
        #expect(before.exploreTerm == "fine0" || before.exploreTerm == "fine1")
        #expect(question(model) == before, "exploring moved the card, its answer or its position")

        let reopened = try Ledger(path: path)
        #expect(try reopened.notes().compactMap { try reopened.existingCard(of: $0.id) }.map(\.scheduled)
                == scheduleBefore, "exploring moved a schedule")
        #expect(try reopened.notes().compactMap { try reopened.card(of: $0.id, at: now) }
            .flatMap { try reopened.reviews(ofCard: $0.id) }.count == eventsBefore,
                "exploring was recorded as a review")
        #expect(try ["fine0", "fine1"].flatMap { try reopened.history(of: $0) }.count == readingsBefore,
                "exploring wrote a reading")
    }

    /// **A launch that did not take says so**, in the card's own place for it, and nothing else
    /// moves: the reader pressed a key and is owed to know it did nothing.
    @Test func aDictionaryThatDidNotOpenIsSaid() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path)
        let opened = Opened()
        opened.launches = false
        let model = exploring(path, opened)
        await model.start()
        model.act(.reveal)
        try await settle { self.question(model)?.answer != nil }
        model.act(.explore)
        #expect(question(model)?.problem != nil, "a launch that failed was silent")
        #expect(question(model)?.answer != nil, "the card lost its meaning over a failed launch")
    }

    /// **The word that is opened is the card's own, not the captured surface.** The reader met
    /// *ran*; the dictionary files *run*. A phrase is opened by its own spelling — the reading's
    /// lemma is the hovered word's, and `take into account` is not `account` — and a card the
    /// reader wrote by theirs.
    @Test func theTermOpenedIsTheCardsOwnNotTheSurfaceItWasMetAs() throws {
        func cue(word: String, lemma: String?, target: StudyTarget) -> ReviewCue {
            ReviewCue(card: StudyCard(noteID: UUID(), createdAt: now), word: word, lemma: lemma,
                      sentence: nil, range: nil, place: ReadingPlace(bundleID: nil, name: nil),
                      readAt: nil, quality: nil, target: target)
        }
        #expect(ReviewModel.explorationTerm(of: cue(
            word: "ran", lemma: "run", target: .entry(dictionary: "noad", entryID: "e1"))) == "run")
        #expect(ReviewModel.explorationTerm(of: cue(
            word: "account", lemma: "account",
            target: .phrase(dictionary: "noad", text: "take something into account")))
                == "take something into account")
        #expect(ReviewModel.explorationTerm(of: cue(
            word: "a blue moon", lemma: nil, target: .custom(dictionary: "noad", text: "a blue moon")))
                == "a blue moon")
    }

    /// **The wire the model tests cannot see**: the button is drawn only where the answer is, is
    /// bound to `E` and reports `.explore`, and `E` is bound nowhere else on this surface.
    @Test func theButtonIsDrawnOnlyWhereTheAnswerIs() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI/ReviewView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "if question.answer != nil {"),
                                 "the explore button's guard is gone")
        let end = try #require(source.range(of: "Spacer(minLength: 0)", range: start.upperBound..<source.endIndex))
        let guarded = source[start.upperBound..<end.lowerBound]
        // Through `answer`, which refuses a held key's repeats before it reports (ReviewKeyRepeatTests).
        #expect(guarded.contains("answer(.explore, on: question)"), "the button is not inside the answer's guard")
        #expect(guarded.contains("KeyboardShortcut(\"e\", modifiers: [])"))
        #expect(source.components(separatedBy: "(.explore").count == 2, "reachable from somewhere else")
        #expect(source.components(separatedBy: "KeyboardShortcut(\"e\"").count == 2, "E is bound twice")
    }

    /// **Done ends the sitting and closes what holds it.** The Review window it used to dismiss is
    /// gone — Review is a pane of the Library — so the action was dismissing a window that no longer
    /// exists, and the finished summary stayed on screen with nothing closed.
    @Test func doneEndsTheSittingAndClosesTheLibrary() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path)
        let closed = Chosen()
        let model = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                clock: { self.now }, defaults: TemporaryDefaults.suite(),
                                finish: { closed.finished += 1 })
        await model.resume()
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { return true }; return false }
        model.act(.done)
        #expect(closed.finished == 1)
        await model.resume()
        if case .finished = model.presentation.stage { Issue.record("Done left the finished sitting to be resumed") }
    }

    // MARK: - A card that can no longer be asked leaves the sitting (final closing pass, finding 2)

    /// A word saved with no meaning, given an answer of the reader's own so it is asked: the card R1b
    /// archives when the reader chooses its meaning.
    private func wordOnlyCard(_ ledger: Ledger, lookup: Int) throws -> StudyNote {
        let word = try #require(try ledger.keep(
            .entry(dictionary: "noad", entryID: "e0"), issuer: .live, language: "en", chosenBy: nil, answer: nil,
            lookupID: lookup, at: now, source: .manual))
        try ledger.setReaderAnswer("a penalty", of: word.id, at: now)
        return word
    }

    /// One reading of *fine0*, as `ready` records it.
    private func reading(_ ledger: Ledger) throws -> Int {
        try ledger.record(LookupRecord(
            surface: "fine0", lemma: "fine0", context: sentence(0), lemmaBasis: .tagger, language: "en",
            contextRange: (sentence(0) as NSString).range(of: "fine0"),
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete)))
    }

    /// Choose a Meaning with R1b on, as `LedgerStore.keepReplacingWordCards` writes it: the meaning kept, the
    /// word-only card archived, one transaction.
    private func chooseAMeaning(_ ledger: Ledger, lookup: Int, replacing word: StudyNote) throws {
        let sense = try #require(try ledger.keep(
            .sense(dictionary: "noad", entryID: "e0", senseKey: "e0.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader, answer: StudyAnswer(origin: .dictionary, text: "a fine"),
            lookupID: lookup, at: now, source: .manual))
        #expect(try ledger.replaceWordCards(onLookup: lookup, with: sense.id, at: now).replaced == [word.id],
                "premise: the word-only card was archived")
    }

    /// The sitting is over, or the card on screen says something went wrong: the two ways a press on a card
    /// that can no longer be graded can end. Waiting for either, so a test fails on the wrong one at once.
    private func endedOrRefused(_ model: ReviewModel) -> Bool {
        if case .finished = model.presentation.stage { return true }
        return question(model)?.problem != nil
    }

    /// The end of the sitting, or a failure naming what is on screen instead.
    private func end(of model: ReviewModel) throws -> ReviewPresentation.Finished {
        guard case .finished(let end) = model.presentation.stage else {
            Issue.record("the sitting holds a card it can never grade: \(question(model)?.problem ?? "no problem said")")
            throw CancellationError()
        }
        return end
    }

    /// **R1b archives the card on screen: a grade of it leaves the sitting, once, and the end says why.** The
    /// reader's Review sitting holds the word-only card; they choose its meaning in History with the option
    /// on, which archives it. The grade they then give is refused as not eligible — and the refusal used to
    /// keep the card on screen "not recorded", so every later press was refused too, for good.
    @Test func aWordCardReplacedUnderTheSittingLeavesItWhenGraded() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try Ledger(path: path)
        let lookup = try reading(ledger)
        let word = try wordOnlyCard(ledger, lookup: lookup)
        let model = model(path)
        await model.start()
        #expect(question(model)?.word == "fine0", "premise: the word-only card is asked")

        try chooseAMeaning(ledger, lookup: lookup, replacing: word)
        model.act(.grade(.good))
        try await settle { self.endedOrRefused(model) }
        let end = try end(of: model)
        #expect(end.summary.left == [.noLongerInStudy: 1], "\(end.summary.left)")
        #expect(end.summary.graded == 0 && end.summary.skipped == 0, "a card that left was counted as answered")
        let card = try #require(try ledger.existingCard(of: word.id))
        #expect(try ledger.reviews(ofCard: card.id).isEmpty, "a card out of study was graded")
        #expect(!model.canUndo, "Undo offered to take back what the sitting did, not the reader")
    }

    /// **And a sitting held across the switch drops it before it is pressed.** Returning to Review resumes the
    /// sitting it holds; the card it would show can no longer be asked, so it is not shown again.
    @Test func aResumedSittingDropsACardThatCanNoLongerBeAsked() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try Ledger(path: path)
        let lookup = try reading(ledger)
        let word = try wordOnlyCard(ledger, lookup: lookup)
        let model = model(path)
        await model.start()
        #expect(question(model)?.word == "fine0", "premise: the word-only card is asked")

        try chooseAMeaning(ledger, lookup: lookup, replacing: word)
        await model.resume()
        try await settle { self.endedOrRefused(model) || self.question(model) == nil }
        #expect(try end(of: model).summary.left == [.noLongerInStudy: 1])
    }

    /// **Paused in Saved while the sitting holds it: it leaves.** A bulk pause moves the revision, so the grade
    /// is refused as stale first and shown again — and then refused as not eligible, for ever.
    @Test func aCardPausedUnderTheSittingLeavesIt() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try ready(path, inProgress: true)
        let model = model(path)
        await model.start()
        let note = try #require(try ledger.notes().first)
        try ledger.setPaused(true, ofNotes: [note.id])

        // **One press.** The stale refusal is not shown again as it is now (round 3, #100) when what moved it
        // is the card leaving study: shown again, it would only be refused once more.
        model.act(.grade(.good))
        try await settle { self.endedOrRefused(model) }
        #expect(try end(of: model).summary.left == [.paused: 1])
        let card = try #require(try ledger.existingCard(of: note.id))
        #expect(try ledger.reviews(ofCard: card.id).count == 1, "the paused card was graded again")
    }

    /// **Its reading deleted while the sitting holds it: it leaves.** A note with no reading has no sentence to
    /// be asked in (`needsRepair`), so no grade of it will ever be taken.
    @Test func aCardWhoseReadingIsDeletedUnderTheSittingLeavesIt() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try ready(path, inProgress: true)
        let model = model(path)
        await model.start()
        let note = try #require(try ledger.notes().first)
        for lookup in try ledger.lookupIDs(evidencing: note.id) { try ledger.delete(lookup: lookup) }

        model.act(.grade(.good))
        try await settle { self.endedOrRefused(model) }
        #expect(try end(of: model).summary.left == [.notReady: 1])
    }

    /// **A card that can no longer be asked is never drawn.** Two cards; the one not yet shown is archived
    /// while the reader answers the first, and the sitting ends rather than putting it in front of them.
    @Test func aCardArchivedBeforeItsTurnIsNeverShown() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()
        let shown = try #require(question(model)?.word)
        let waiting = try #require(try ledger.notes().first { note in
            guard let card = try ledger.existingCard(of: note.id) else { return false }
            return try ledger.cue(forCard: card.id)?.word != shown
        })
        try ledger.setEnrollment(.archived, of: waiting.id)

        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { true } else { self.question(model)?.position == 2 } }
        let end = try end(of: model)
        #expect(end.summary.graded == 1)
        #expect(end.summary.skipped == 0, "a card that left the sitting was counted as skipped, still due")
        #expect(end.summary.left == [.noLongerInStudy: 1])
    }

    /// **Undo passes over a card that left, and the card is asked again when its turn comes round.** The
    /// reader takes back the grade before it: the card that left is not theirs to take back, and asked again
    /// it leaves again — not a dead Undo that keeps restoring a card that cannot stay.
    @Test func undoPassesOverACardThatLeftTheSitting() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try ready(path, count: 2, inProgress: true)
        let model = model(path)
        await model.start()
        let first = try #require(question(model)?.word)
        let waiting = try #require(try ledger.notes().first { note in
            guard let card = try ledger.existingCard(of: note.id) else { return false }
            return try ledger.cue(forCard: card.id)?.word != first
        })
        try ledger.setEnrollment(.archived, of: waiting.id)
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { true } else { false } }

        #expect(model.canUndo, "the reader's grade is there to take back")
        model.act(.undo)
        try await settle { self.question(model)?.word == first }
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { true } else { false } }
        let end = try end(of: model)
        #expect(end.summary.graded == 1 && end.summary.left == [.noLongerInStudy: 1], "\(end.summary)")
    }

    /// **The refusal is read, not assumed**: a card askable again by the time the reason is asked — a put-off
    /// that ran out between the grade and the read — stays, says the answer was not recorded, and the next
    /// press is taken. The control for `leave`'s read: without it, the card would have gone.
    @Test func aCardEligibleAgainByTheTimeTheReasonIsAskedStays() async throws {
        let (path, clean) = scratch(); defer { clean() }
        let ledger = try ready(path, inProgress: true)
        final class Clock { var calls = 0; var jumpAfter = Int.max }
        let clock = Clock(), early = now, later = now.addingTimeInterval(7_200)
        let model = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                clock: {
                                    clock.calls += 1
                                    return clock.calls > clock.jumpAfter ? later : early
                                }, defaults: TemporaryDefaults.suite())
        await model.start()
        let note = try #require(try ledger.notes().first)
        let card = try #require(try ledger.existingCard(of: note.id))
        // Put off for an hour **without moving the revision**, so the grade is refused as not eligible
        // rather than as stale; the commit asks the clock once, and every later ask is two hours on.
        try ledger.run("UPDATE study_cards SET hidden_until = ? WHERE id = ?",
                       bind: [.real(now.addingTimeInterval(3_600).timeIntervalSince1970), .text(card.id.uuidString)]) { _ in }
        clock.jumpAfter = clock.calls + 1

        model.act(.grade(.good))
        try await settle { self.endedOrRefused(model) }
        let refused = try #require(question(model), "the card left though it could be asked again")
        #expect(refused.problem?.hasPrefix("That answer was not recorded: ") == true, "\(refused.problem ?? "")")
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { true } else { false } }
        #expect(try end(of: model).summary.graded == 1)
        #expect(try ledger.reviews(ofCard: card.id).filter { !$0.isVoid }.count == 2, "the press after the refusal was not taken")
    }
}
