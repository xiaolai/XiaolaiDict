import Foundation
import ReviewKit
import XiaolaiDictCore
import XiaolaiDictUI

/// `--review-report`: **what Review will ask, and what its model holds on each side of the reveal**,
/// read through the same `ReviewModel` the Library window draws from.
///
/// The `review` end-to-end stage drives the real window from outside — keys posted as the keyboard
/// posts them, the accessibility tree read as VoiceOver reads it — and two questions are out of its
/// reach there. Whether the ledger it seeded is one the app's own queue will ask at all: a fixture the
/// queue refuses reads, from outside, as a window with no card in it, a fact about the harness that
/// looks like one about the app. And what the presentation holds before and after the reveal, which
/// is the boundary ADR-0032 puts the answer behind — the outside sees what was drawn, not what the
/// view was given to draw.
///
/// **It writes nothing, and that is why it can run anywhere.** A sitting is drawn and its first card
/// revealed: both are reads. It never grades, skips, postpones or explores, so pointing it at a
/// reader's own ledger changes nothing — `runningItChangesNothingInTheLedger` holds it to that, on
/// the ledger rather than on what the report says about itself.
///
/// Headless, under `dispatchMain()`: nothing here draws, captures or posts an event.
@MainActor
enum ReviewReport {
    /// How long the revealed answer is waited for. A reveal is one read of one row, so anything near
    /// this is a ledger that is not answering rather than one that is slow.
    static let revealDeadline: Duration = .seconds(5)

    /// The reader's own ledger and study dictionary, as the app opens them.
    static func run() async -> CommandStatus {
        let opening = Task { try await LedgerStore.openDefault() }
        // **The app's own suite**, as `XiaolaiDictApp.init()` takes it: run from inside the bundle,
        // `.standard` is the reader's domain, where today's one-day increase is kept.
        return await run(store: { opening }, primary: { PrimaryDictionaryStore().load() },
                         clock: { .now }, defaults: .standard, write: LookupCommand.writeLine)
    }

    static func run(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
                    primary: @escaping @MainActor () -> PrimaryDictionary,
                    clock: @escaping @MainActor () -> Date,
                    defaults: UserDefaults,
                    write: (String) -> Bool) async -> CommandStatus {
        let scope = primary().chosen
        var report: [String: Any] = [
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            // The study namespace the sitting is drawn from; nil is every namespace.
            "dictionary": scope.map { $0 as Any } ?? NSNull(),
        ]
        // **What the queue holds, counted the way the window counts it** — the same allowance and the
        // same study day — so a fixture the queue refuses is said in a number, not inferred from an
        // empty window.
        do {
            guard let opening = store() else { return finish(report, problem: "no ledger to open", write) }
            let now = clock()
            // Today's one-day increase included, as the window and the Library's badge count it.
            let increase = OneDayIncreaseStore(defaults: defaults).extra(in: .standard, at: now)
            let counts = try await opening.value.queueCounts(
                at: now, dictionary: scope,
                newAllowance: SittingPlanner.allowance(newCardsPerDay: ReviewModel.newCardsPerDay,
                                                       increaseToday: increase),
                dayStart: StudyDay.standard.start(containing: now))
            report["due"] = counts.due
            report["heldBack"] = counts.heldBack
        } catch {
            return finish(report, problem: "the ledger could not be read: \(error.localizedDescription)", write)
        }

        // `finish` closes the window; there is none here, and nothing below asks for it.
        let model = ReviewModel(store: store, primary: primary, clock: clock, defaults: defaults, finish: {},
                                openInDictionary: { _ in false })
        await model.start()
        let front = model.presentation
        report["front"] = describe(front)
        guard case .asking = front.stage else {
            return finish(report, problem: "the sitting asked nothing", write)
        }
        model.act(.reveal)
        let revealed = await Instrument.settle(until: revealDeadline) { answer(of: model.presentation) != nil }
        report["back"] = describe(model.presentation)
        guard revealed else {
            return finish(report, problem: "the reveal brought no answer within \(revealDeadline)", write)
        }
        return Instrument.write(report, to: write) ? .success : .internalError
    }

    /// **The presentation, spelled as JSON — and nothing the presentation does not hold.** Before the
    /// reveal there is no `answer` key at all: not an empty string and not a null, because the
    /// presentation has no answer and a report that wrote a placeholder would be one refactor away
    /// from writing the real thing.
    static func describe(_ presentation: ReviewPresentation) -> [String: Any] {
        switch presentation.stage {
        case .empty(let reason):
            var found: [String: Any] = ["stage": "empty"]
            switch reason {
            case .nothingDue: found["reason"] = "nothingDue"
            case .nothingEnrolled: found["reason"] = "nothingEnrolled"
            case .needsAttention(let waiting):
                found["reason"] = "needsAttention"
                found["count"] = waiting.total
                found["toConfirm"] = waiting.toConfirm
                found["toAnswer"] = waiting.toAnswer
                found["readingDeleted"] = waiting.readingDeleted
            case .heldBackUntilTomorrow(let count):
                found["reason"] = "heldBackUntilTomorrow"
                found["count"] = count
            case .couldNotBeRead(let problem):
                found["reason"] = "couldNotBeRead"
                found["problem"] = problem
            }
            return found
        case .asking(let question):
            var asked: [String: Any] = [
                "stage": "asking", "word": question.word, "exploreTerm": question.exploreTerm,
                "position": question.position, "batchSize": question.batchSize,
                "isPractice": question.isPractice, "isCommitting": question.isCommitting,
                "hasSentence": question.sentence != nil, "answerShown": question.answer != nil,
            ]
            if let answer = question.answer {
                asked["answer"] = answer.text
                if let dictionary = answer.dictionary { asked["answerDictionary"] = dictionary }
            }
            if let problem = question.problem { asked["problem"] = problem }
            return asked
        case .finished(let end):
            let summary = end.summary
            var found: [String: Any] = [
                "stage": "finished", "graded": summary.graded, "skipped": summary.skipped,
                "stillDue": summary.stillDue, "heldBack": summary.heldBack,
                "postponed": summary.postponed, "wasPractice": summary.wasPractice,
                // WI-5: forgot over its denominator, practice apart, the words that keep slipping and
                // the offer. **No forecast key where none was read** — not an empty week.
                "forgot": summary.forgot, "scheduled": summary.scheduled,
                "forgotInPractice": summary.forgotInPractice, "slipping": end.slipping,
                "moreNewToday": end.moreNewToday,
                // What left the sitting because it can no longer be asked, by reason — counts, never words.
                "left": Dictionary(uniqueKeysWithValues: summary.left.map { ($0.key.rawValue, $0.value) }),
            ]
            if let forecast = end.forecast { found["forecast"] = forecast.days.map(\.due) }
            if let problem = end.problem { found["problem"] = problem }
            return found
        }
    }

    private static func answer(of presentation: ReviewPresentation) -> ReviewPresentation.Answer? {
        guard case .asking(let question) = presentation.stage else { return nil }
        return question.answer
    }

    /// The report with the reason it could not say more, and a failure — or `.internalError` when
    /// even that could not be written, because a measurement nobody received must not exit as one.
    private static func finish(_ report: [String: Any], problem: String,
                               _ write: (String) -> Bool) -> CommandStatus {
        var report = report
        report["problem"] = problem
        return Instrument.write(report, to: write) ? .failure : .internalError
    }
}
