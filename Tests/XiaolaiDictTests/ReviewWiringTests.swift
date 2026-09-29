import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
@testable import XiaolaiDict

/// **The Review window against a real ledger.** WI-004's wire.
///
/// `ReviewSessionTests` proves the rules of a sitting and `StudyReviewTests` proves the transaction;
/// both would pass over a window that writes nothing. These assert the two things only the wire can
/// be wrong about: that a grade reaches the ledger, and that the answer does not reach the reader
/// before they ask for it.
@MainActor
struct ReviewWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-review-\(UUID().uuidString).sqlite").path
        return (path, { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } })
    }

    /// A ledger with `count` cards ready to be asked, and the model pointed at it.
    ///
    /// `inProgress` answers each card once an hour ago, which is what makes it *due* rather than
    /// *new*. The distinction is load-bearing since C08: new cards are rationed by the daily
    /// allowance, so a fixture that wants to measure anything else — the batch bound, the backlog —
    /// must not be made of them.
    @discardableResult
    private func ready(_ path: String, count: Int = 1, inProgress: Bool = false) throws -> Ledger {
        let ledger = try Ledger(path: path)
        var enrolled: [UUID] = []
        for index in 0..<count {
            let lookup = try ledger.record(LookupRecord(
                surface: "fine\(index)", lemma: "fine\(index)",
                context: "He paid the fine\(index) today.", lemmaBasis: .tagger, language: "en",
                contextRange: NSRange(location: 12, length: 5),
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

    private func model(_ path: String, clock: Date? = nil) -> ReviewModel {
        let when = clock ?? now
        return ReviewModel(store: { Task { try LedgerStore(path: path) } },
                           primary: { PrimaryDictionary(chosen: "noad") },
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
        #expect(back.answer?.dictionary == "noad", "a card attributes its answer")
    }

    /// A capture that produced no real sentence shows none. The ledger stores the selection itself
    /// when nothing surrounded the word, and drawing that as context would be the word echoed back
    /// and dressed as the reader's own reading.
    @Test func acaptureWithNoSentenceShowsNone() throws {
        let cue = ReviewCue(
            card: StudyCard(noteID: UUID(), createdAt: now), word: "fine", sentence: "fine",
            range: nil, place: ReadingPlace(bundleID: nil, name: nil), readAt: now,
            quality: .accessibility(.accessibilityTextRange, context: .missing),
            target: .entry(dictionary: "noad", entryID: "e1"))
        #expect(ReviewModel.sentence(of: cue) == nil)
    }

    // MARK: - The grade reaches the ledger

    @Test func agradeIsWrittenAndTheSurfaceMovesOn() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try ready(path, count: 2)
        let model = model(path)
        await model.start()
        #expect(question(model)?.position == 1)

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
        let card = try #require(try reopened.card(of: note.id, at: now))
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
        model.act(.grade(.good))
        try await settle { self.question(model)?.position == 2 }

        model.act(.undo)
        try await settle { self.question(model)?.position == 1 }
        #expect(question(model)?.word == first.word)

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
        let card = try #require(try ledger.card(of: try #require(try ledger.notes().first).id, at: now))
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

        // And back tomorrow, with its schedule untouched.
        let tomorrow = self.model(path, clock: now.addingTimeInterval(86_400 + 3_600))
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

    /// Waits for the condition, never for a duration: the model commits in a task of its own, so an
    /// `await` on the call returns before the ledger has anything.
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}
