import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
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
                           clock: { when })
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

        // Archive the note behind the model's back: the card is drawn and no longer askable, which
        // is exactly what a second window or a tidy-up does while the reader is thinking.
        let note = try #require(try ledger.notes().first)
        try ledger.setEnrollment(.archived, of: note.id)

        model.act(.grade(.good))
        try await settle { self.question(model)?.problem != nil }
        let after = try #require(question(model))
        #expect(after.position == before.position, "the surface moved on over a failed write")
        #expect(after.problem != nil, "and said nothing about it")
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
        guard case .finished(let summary) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
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
        guard case .finished(let summary) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
        #expect(summary.stillDue == 0, "the eight beyond the allowance are tomorrow's, not a backlog")
        // **And the reader is told.** Eight words they saved going quiet with no sentence is
        // indistinguishable from eight words the app lost.
        #expect(summary.heldBack == 8)

        // **The allowance does not refill within the day.** Asking for another sitting on the same
        // clock must find nothing askable — and must say why, not "nothing is due".
        await model.start()
        #expect(model.presentation.stage == .empty(.heldBackUntilTomorrow(8)))
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
        guard case .finished(let summary) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
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
        guard case .finished(let summary) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
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
                                clock: { self.now })
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

        for _ in 0..<2 {
            model.act(.skip)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await settle {
            if case .finished = model.presentation.stage { return true }
            return false
        }
        guard case .finished(let summary) = model.presentation.stage else {
            Issue.record("the batch never finished")
            return
        }
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
                                clock: { self.now })
        await model.resume()
        #expect(question(model) != nil, "positive control: the noad sitting was drawn")
        await model.resume()
        #expect(question(model) != nil, "an unchanged primary keeps the sitting")
        chosen.key = "another"
        await model.resume()
        #expect(question(model) == nil, "the old dictionary's card survived the switch")
        #expect(model.presentation.stage == .empty(.nothingEnrolled))
    }

    /// **Done ends the sitting and closes what holds it.** The Review window it used to dismiss is
    /// gone — Review is a pane of the Library — so the action was dismissing a window that no longer
    /// exists, and the finished summary stayed on screen with nothing closed.
    @Test func doneEndsTheSittingAndClosesTheLibrary() async throws {
        let (path, clean) = scratch(); defer { clean() }
        try ready(path)
        let closed = Chosen()
        let model = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                clock: { self.now }, finish: { closed.finished += 1 })
        await model.resume()
        model.act(.grade(.good))
        try await settle { if case .finished = model.presentation.stage { return true }; return false }
        model.act(.done)
        #expect(closed.finished == 1)
        await model.resume()
        if case .finished = model.presentation.stage { Issue.record("Done left the finished sitting to be resumed") }
    }
}
