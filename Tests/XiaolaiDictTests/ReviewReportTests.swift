import DictionaryModel
import Foundation
import ReviewKit
import StudyKit
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **`--review-report`: the app's own word on what Review will ask, read through the model.**
///
/// The `review` end-to-end stage drives the real window from outside — keys as the keyboard posts
/// them, the accessibility tree as VoiceOver reads it. Two things it cannot see from there: whether
/// the seeded ledger is one the app's queue will ask at all, and what the model's presentation holds
/// on each side of the reveal. This instrument answers both from inside the bundle, through the same
/// `ReviewModel` the window draws from, and **writes nothing** — it starts a sitting and reveals,
/// which are reads, so it can be run against any ledger.
@MainActor
struct ReviewReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A ledger with one card due, answered once a day ago so it is not rationed as new.
    private func ready(_ path: String) throws -> Ledger {
        let ledger = try Ledger(path: path)
        let note = try Wiring.save(ledger, "fine", at: now.addingTimeInterval(-2 * 86_400))
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: card.revision,
                             at: now.addingTimeInterval(-86_400), using: try MemoryScheduler())
        return ledger
    }

    private func report(_ path: String) async throws -> (CommandStatus, [String: Any]) {
        var lines: [String] = []
        let status = await ReviewReport.run(
            store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
            clock: { self.now }, defaults: TemporaryDefaults.suite(), write: { lines.append($0); return true })
        let line = try #require(lines.last, "the instrument wrote nothing")
        #expect(lines.count == 1, "one report, one line: \(lines)")
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (status, decoded)
    }

    // MARK: - The presentation, as the report spells it

    private func question(answer: ReviewPresentation.Answer?, committing: Bool = false,
                          problem: String? = nil) -> ReviewPresentation {
        ReviewPresentation(stage: .asking(ReviewPresentation.Question(
            showing: UUID(), word: "ran", accentKey: "run", exploreTerm: "run", sentence: nil, source: "",
            position: 2, batchSize: 8, answer: answer, isCommitting: committing, problem: problem)))
    }

    /// **The front has no answer key at all**, not an empty one: the presentation holds none, and a
    /// report that wrote `"answer": ""` would be one refactor from writing the real one.
    @Test func thefrontOfACardIsDescribedWithNoAnswer() {
        let front = ReviewReport.describe(question(answer: nil))
        #expect(front["stage"] as? String == "asking")
        #expect(front["word"] as? String == "ran")
        #expect(front["exploreTerm"] as? String == "run")
        #expect(front["position"] as? Int == 2)
        #expect(front["batchSize"] as? Int == 8)
        #expect(front["answerShown"] as? Bool == false)
        #expect(front["answer"] == nil, "the front carried an answer key: \(front)")
        #expect(front["answerDictionary"] == nil)
        #expect(JSONSerialization.isValidJSONObject(front))
    }

    @Test func thebackOfACardCarriesItsAnswerAndWhoSaidIt() {
        let back = ReviewReport.describe(question(
            answer: ReviewPresentation.Answer(text: "move fast", dictionary: "NOAD"), committing: true,
            problem: "That answer was not recorded"))
        #expect(back["answerShown"] as? Bool == true)
        #expect(back["answer"] as? String == "move fast")
        #expect(back["answerDictionary"] as? String == "NOAD")
        #expect(back["isCommitting"] as? Bool == true)
        #expect(back["problem"] as? String == "That answer was not recorded")
        #expect(JSONSerialization.isValidJSONObject(back))
    }

    /// **Five nothings, five names.** The surface says each differently, so the report must too — a
    /// harness told "empty" could not tell a ledger nobody seeded from one it could not read.
    @Test(arguments: [
        (ReviewPresentation.Empty.nothingDue, "nothingDue"),
        (.nothingEnrolled, "nothingEnrolled"),
        (.needsAttention(StudyAttention(toConfirm: 3, toAnswer: 2, readingDeleted: 1)), "needsAttention"),
        (.heldBackUntilTomorrow(4), "heldBackUntilTomorrow"),
        (.couldNotBeRead("disk I/O error"), "couldNotBeRead"),
    ])
    func everyEmptyStageIsNamed(reason: ReviewPresentation.Empty, name: String) {
        let empty = ReviewReport.describe(ReviewPresentation(stage: .empty(reason)))
        #expect(empty["stage"] as? String == "empty")
        #expect(empty["reason"] as? String == name)
        switch reason {
        case .needsAttention(let waiting):
            // The total, and each reason beside it: the surface says them apart.
            #expect(empty["count"] as? Int == waiting.total)
            #expect(empty["toConfirm"] as? Int == waiting.toConfirm)
            #expect(empty["toAnswer"] as? Int == waiting.toAnswer)
            #expect(empty["readingDeleted"] as? Int == waiting.readingDeleted)
        case .heldBackUntilTomorrow(let count):
            #expect(empty["count"] as? Int == count)
        case .couldNotBeRead(let problem):
            #expect(empty["problem"] as? String == problem)
        case .nothingDue, .nothingEnrolled:
            #expect(empty["count"] == nil)
        }
        #expect(JSONSerialization.isValidJSONObject(empty))
    }

    @Test func afinishedBatchSaysWhatItLeft() {
        let finished = ReviewReport.describe(ReviewPresentation(stage: .finished(ReviewPresentation.Finished(
            summary: ReviewSession.Summary(graded: 3, skipped: 1, stillDue: 4, heldBack: 2, postponed: 1,
                                           wasPractice: false, practised: 1, forgot: 1, forgotInPractice: 1),
            forecast: nil, slipping: ["laconic"], moreNewToday: 2))))
        #expect(finished["stage"] as? String == "finished")
        #expect(finished["graded"] as? Int == 3)
        #expect(finished["skipped"] as? Int == 1)
        #expect(finished["stillDue"] as? Int == 4)
        #expect(finished["heldBack"] as? Int == 2)
        #expect(finished["postponed"] as? Int == 1)
        #expect(finished["wasPractice"] as? Bool == false)
        // **What the end of a sitting adds (WI-5)**: forgot over its denominator, practice apart, the
        // words that keep slipping, and the offer — and no forecast key where none could be read.
        #expect(finished["forgot"] as? Int == 1)
        #expect(finished["scheduled"] as? Int == 2)
        #expect(finished["forgotInPractice"] as? Int == 1)
        #expect(finished["slipping"] as? [String] == ["laconic"])
        #expect(finished["moreNewToday"] as? Int == 2)
        #expect(finished["forecast"] == nil)
        #expect(JSONSerialization.isValidJSONObject(finished))
    }

    // MARK: - The instrument, against a real ledger

    /// **The wire.** A model nothing calls is not a feature: this goes through `run`, against a
    /// ledger, and reads the one line it writes.
    @Test func itReportsTheQueueTheFrontWithNoAnswerAndTheBackWithTheCardsOwn() async throws {
        let (path, clean) = Wiring.scratch("review-report")
        defer { clean() }
        _ = try ready(path)
        let (status, report) = try await report(path)
        #expect(status == .success)
        #expect(report["due"] as? Int == 1)
        #expect(report["heldBack"] as? Int == 0)
        #expect(report["dictionary"] as? String == "noad")
        let front = try #require(report["front"] as? [String: Any])
        let back = try #require(report["back"] as? [String: Any])
        #expect(front["stage"] as? String == "asking")
        #expect(front["word"] as? String == "fine")
        #expect(front["answer"] == nil, "the front of the card carried its answer: \(front)")
        #expect(back["word"] as? String == "fine")
        #expect(back["answer"] as? String == "what fine means")
    }

    /// **It writes nothing.** An instrument that may be pointed at a reader's own ledger starts a
    /// sitting and reveals — and a reveal that graded, or a draw that stamped anything, would be a
    /// review the reader never sat. Asserted on the ledger, not on what the report says about itself.
    @Test func runningItChangesNothingInTheLedger() async throws {
        let (path, clean) = Wiring.scratch("review-report-inert")
        defer { clean() }
        let ledger = try ready(path)
        let card = try #require(try ledger.dueCards(at: now, limit: 10, dictionary: "noad",
                                                    newAllowance: 5, dayStart: now.addingTimeInterval(-3_600)).first)
        let before = (try ledger.reviews(ofCard: card.id), try ledger.card(id: card.id))
        _ = try await report(path)
        let after = (try ledger.reviews(ofCard: card.id), try ledger.card(id: card.id))
        #expect(after.0 == before.0, "the report wrote a review event")
        #expect(after.1 == before.1, "the report moved the card")
    }

    /// **Nothing to ask is a failed measurement, said in the report.** Exiting 0 over an empty
    /// queue would let a stage whose fixture never landed read as a report that found nothing wrong.
    @Test func anEmptyQueueIsAFailureThatNamesItsStage() async throws {
        let (path, clean) = Wiring.scratch("review-report-empty")
        defer { clean() }
        _ = try Ledger(path: path)
        let (status, report) = try await report(path)
        #expect(status == .failure)
        #expect(report["due"] as? Int == 0)
        let front = try #require(report["front"] as? [String: Any])
        #expect(front["stage"] as? String == "empty")
        #expect(front["reason"] as? String == "nothingEnrolled")
        #expect(report["back"] == nil, "a back was reported for a card that was never asked")
        #expect((report["problem"] as? String)?.isEmpty == false, "a failure must say why")
    }

    /// **A report that could not be written is not a pass.** The sink is asked, not assumed.
    @Test func areportNobodyReceivedIsAnInternalError() async throws {
        let (path, clean) = Wiring.scratch("review-report-sink")
        defer { clean() }
        _ = try ready(path)
        let status = await ReviewReport.run(
            store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
            clock: { self.now }, defaults: TemporaryDefaults.suite(), write: { _ in false })
        #expect(status == .internalError)
    }
}
