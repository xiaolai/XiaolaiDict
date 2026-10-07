import Foundation
import ReviewKit
import StudyKit
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The end of a sitting, from the ledger's rows to what the Review pane is given to draw**
/// (review-module-plan §3, §8.4, WI-5).
///
/// `ForecastTests`, `OneDayIncreaseTests` and `ReviewSessionTests` prove the rules; these prove the
/// wire — a forecast nothing builds, a count nothing shows and an increase nothing reads are not
/// features. What the end says: how many were forgotten out of how many, what the coming study days
/// hold, which words keep slipping, and — where new meanings are held back — an offer to introduce
/// more today, which raises today's allowance and nothing else, and is counted the same way by the
/// sitting, the Library's badge and the instrument.
@MainActor
struct SittingEndWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixture

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        try Wiring.save(ledger, word, at: now.addingTimeInterval(-10 * 86_400))
    }

    /// Forgot, `daysAgo` days before the sitting — a day of failure on the card's record, and a card
    /// that is due again ten minutes later.
    private func forget(_ ledger: Ledger, _ note: StudyNote, daysAgo: Int) throws {
        let card = try #require(try ledger.existingCard(of: note.id))
        _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: card.revision,
                             at: now.addingTimeInterval(-Double(daysAgo) * 86_400), using: try MemoryScheduler())
    }

    private func review(_ path: String, _ defaults: UserDefaults = TemporaryDefaults.suite()) -> ReviewModel {
        ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                    clock: { self.now }, defaults: defaults)
    }

    private func question(_ model: ReviewModel) -> ReviewPresentation.Question? {
        guard case .asking(let question) = model.presentation.stage else { return nil }
        return question
    }

    private func end(_ model: ReviewModel) -> ReviewPresentation.Finished? {
        guard case .finished(let end) = model.presentation.stage else { return nil }
        return end
    }

    /// Answers every card by its word until the sitting ends, waiting for each grade to land.
    private func answer(_ model: ReviewModel, _ grade: (String) -> Grade) async throws {
        while let question = question(model) {
            model.act(.grade(grade(question.word)))
            try await Wiring.settle("the grade of \(question.word) never landed") {
                self.question(model).map { $0.position > question.position } ?? (self.end(model) != nil)
            }
        }
        _ = try #require(end(model), "the sitting did not end")
    }

    private func planner(increase: Int = 0) -> SittingPlanner {
        SittingPlanner(studyDay: .standard, now: now, batchSize: ReviewModel.batchSize,
                       newCardsPerDay: ReviewModel.newCardsPerDay, increaseToday: increase)
    }

    // MARK: - Forgot, and what is coming

    /// **"Forgot 2 of 3", and the week ahead, built from the ledger as the sitting left it.** The
    /// forecast the end carries is the pure one over a fresh read of the same ledger at the same
    /// instant — so the model computes nothing of its own — and it says something: the two forgotten
    /// meanings come back ten minutes later, which is still today.
    @Test func theEndSaysWhatWasForgottenAndWhatIsComing() async throws {
        let (path, clean) = Wiring.scratch("end-forecast")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for word in ["laconic", "ephemeral", "gregarious"] {
            try forget(ledger, try save(ledger, word), daysAgo: 1)
        }
        let model = review(path)
        await model.start()
        try await answer(model) { $0 == "ephemeral" ? .good : .again }

        let end = try #require(end(model))
        #expect(end.summary.forgot == 2)
        #expect(end.summary.scheduled == 3)
        #expect(end.summary.forgotInPractice == 0)
        let planner = planner()
        let expected = Forecast(from: try ledger.sittingCandidates(dictionary: "noad", introducedSince: planner.today),
                                planner: planner)
        #expect(end.forecast == expected)
        #expect(end.forecast?.days.count == Forecast.horizon)
        #expect(end.forecast?.days.first?.reviews == 2, "the forgotten two come back later today")
        #expect(end.problem == nil)
        // **C2: the end never answers.** It names counts and words; no saved meaning is in it.
        #expect(!"\(end)".contains("means"), "an answer reached the end of the sitting: \(end)")
    }

    // MARK: - Keeps slipping

    /// **Named by its word, and nothing is done to it.** The rule is the Struggling filter's own —
    /// days of failure, counted by study day, live graded answers only (R09) — applied to what this
    /// sitting forgot. *recalcitrant* fails today for the fourth day and is named; *fine* for the
    /// third, one short; *laconic* is over the line already and was remembered today, so it did not
    /// slip. The named card is not paused, put off or rescheduled: its schedule is exactly what its
    /// last grade wrote, and only that grade moved its revision.
    @Test func aMeaningThatKeepsSlippingIsNamedAndNothingIsDoneToIt() async throws {
        let (path, clean) = Wiring.scratch("end-slipping")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let slipping = try save(ledger, "recalcitrant")
        for days in [3, 2, 1] { try forget(ledger, slipping, daysAgo: days) }
        let almost = try save(ledger, "fine")
        for days in [2, 1] { try forget(ledger, almost, daysAgo: days) }
        let over = try save(ledger, "laconic")
        for days in [4, 3, 2, 1] { try forget(ledger, over, daysAgo: days) }

        let model = review(path)
        await model.start()
        try await answer(model) { $0 == "laconic" ? .good : .again }

        let end = try #require(end(model))
        #expect(end.slipping == ["recalcitrant"], "named \(end.slipping)")
        let card = try #require(try ledger.existingCard(of: slipping.id))
        let last = try #require(try ledger.reviews(ofCard: card.id).last)
        #expect(last.grade == .again && last.reviewedAt == now, "the fixture's last grade is not today's")
        #expect(!card.isPaused, "a slipping card was paused")
        #expect(card.hiddenUntil == nil, "a slipping card was put off")
        #expect(card.scheduled == last.after, "a slipping card was rescheduled")
        #expect(card.revision == last.cardRevision + 1, "something wrote to the card after its grade")
        // One rule: what the end names, the Struggling filter lists.
        let struggling = Set(try ledger.repeatedlyLapsed(dictionary: "noad"))
        #expect(struggling.contains(card.id))
    }

    // MARK: - The one-day increase

    /// **Offered where new meanings are held back, for exactly what is held back, and only today's.**
    /// Eight new meanings at five a day: the sitting asks five and holds three. Introducing more
    /// raises today's allowance by three — kept in the suite the model was given and nowhere else —
    /// and draws them. With nothing held back nothing is offered, and the action does nothing.
    @Test func aOneDayIncreaseIntroducesMoreTodayAndIsKeptInTheSuiteItWasGiven() async throws {
        let (path, clean) = Wiring.scratch("end-increase")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let defaults = TemporaryDefaults.suite()
        let standard = UserDefaults.standard.data(forKey: OneDayIncreaseStore.key)
        let model = review(path, defaults)
        await model.start()
        #expect(question(model)?.batchSize == ReviewModel.newCardsPerDay)
        try await answer(model) { _ in .good }

        let held = try #require(end(model))
        #expect(held.summary.heldBack == 3)
        #expect(held.moreNewToday == 3)
        model.act(.introduceMoreToday)
        try await Wiring.settle("the increase drew no sitting") { self.question(model)?.batchSize == 3 }
        let store = OneDayIncreaseStore(defaults: defaults)
        #expect(store.extra(in: .standard, at: now) == 3)
        #expect(UserDefaults.standard.data(forKey: OneDayIncreaseStore.key) == standard,
                "the increase reached the runner's own defaults")

        try await answer(model) { _ in .good }
        let none = try #require(end(model))
        #expect(none.summary.heldBack == 0)
        #expect(none.moreNewToday == 0, "more was offered with nothing held back")
        model.act(.introduceMoreToday)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.extra(in: .standard, at: now) == 3, "an action with nothing offered raised the allowance")
        #expect(end(model) != nil, "an action with nothing offered left the end")
    }

    /// **Yesterday's increase raises nothing today; today's raises only today.** A value kept from
    /// the previous study day is in the suite and is ignored: the sitting is rationed to the base. The
    /// control is today's: the same suite, raised today, draws all eight.
    @Test func anIncreaseKeptFromYesterdayRaisesNothingToday() async throws {
        let (path, clean) = Wiring.scratch("end-increase-old")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let defaults = TemporaryDefaults.suite()
        let store = OneDayIncreaseStore(defaults: defaults)
        store.raise(by: 5, in: .standard, at: StudyDay.standard.start(containing: now).addingTimeInterval(-1))
        #expect(store.extra(in: .standard, at: now) == 0)

        let yesterday = review(path, defaults)
        await yesterday.start()
        #expect(question(yesterday)?.batchSize == ReviewModel.newCardsPerDay, "yesterday's increase was spent today")

        store.raise(by: 5, in: .standard, at: now)
        let today = review(path, defaults)
        await today.start()
        #expect(question(today)?.batchSize == 8)
    }

    /// **One counting rule: the Library's badge counts what the sitting draws** (WI-2 made the planner
    /// the owner; the increase is one more input to it). Raised by three, the badge moves three from
    /// held back to due, and a sitting asks exactly that many.
    @Test func theLibraryCountsTheIncreaseTheSittingDraws() async throws {
        let (path, clean) = Wiring.scratch("end-increase-badge")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let defaults = TemporaryDefaults.suite()
        let library = LibraryModel(store: Wiring.store(path), clock: { self.now },
                                   exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                                   defaults: defaults, primary: { PrimaryDictionary(chosen: "noad") })
        await library.refreshReviewCount()
        #expect(library.reviewCount == 5 && library.reviewHeldBack == 3)

        OneDayIncreaseStore(defaults: defaults).raise(by: 3, in: .standard, at: now)
        await library.refreshReviewCount()
        #expect(library.reviewCount == 8 && library.reviewHeldBack == 0,
                "the badge says \(library.reviewCount) due, \(library.reviewHeldBack) held back")
        let model = review(path, defaults)
        await model.start()
        #expect(question(model)?.batchSize == library.reviewCount)
    }

    /// **The instrument counts the way the window counts**, increase included — its whole claim.
    @Test func theReviewReportCountsTodaysIncrease() async throws {
        let (path, clean) = Wiring.scratch("end-increase-report")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for index in 0..<8 { try save(ledger, "word\(index)") }
        let defaults = TemporaryDefaults.suite()
        OneDayIncreaseStore(defaults: defaults).raise(by: 2, in: .standard, at: now)
        var lines: [String] = []
        _ = await ReviewReport.run(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                   clock: { self.now }, defaults: defaults,
                                   write: { lines.append($0); return true })
        let line = try #require(lines.last, "the instrument wrote nothing")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(report["due"] as? Int == 7)
        #expect(report["heldBack"] as? Int == 1)
    }

    /// **"Today 1, Tomorrow 0, Thu 2 …": each count under the day it was counted for.** The weekday is
    /// named on the forecast's own calendar. Kiritimati is UTC+14, so its study days start the previous
    /// evening in most other zones: named on the machine's calendar instead, Thursday's count would sit
    /// under Wednesday. Text, never a chart and never a percentage.
    @Test func theWeekIsSaidDayByDayOnTheForecastsCalendar() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func local(_ day: Int, _ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour)))
        }
        let review = { (due: Date) in
            StudyCard(noteID: UUID(), scheduled: ScheduledCard(
                state: MemoryState(stability: 10, difficulty: 5), phase: .review, lastReview: nil, due: due),
                      createdAt: .distantPast)
        }
        let planner = SittingPlanner(studyDay: StudyDay(timeZone: zone, cutoffHour: 4), now: try local(10, 12),
                                     batchSize: 10, newCardsPerDay: 5)
        let forecast = Forecast(from: SittingCandidates(
            cards: [review(try local(10, 9)), review(try local(12, 9)), review(try local(12, 10))],
            introducedToday: 0), planner: planner)
        let thursday = try local(12, 12).formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))

        let said = ReviewView.days(of: forecast)
        #expect(said.hasPrefix("Today 1"), "\(said)")
        #expect(said.contains("Tomorrow 0"), "\(said)")
        #expect(said.contains("\(thursday) 2"), "Thursday's two are not under Thursday: \(said)")
        #expect(!said.contains("%"), "\(said)")
    }

    /// **The app gives the review model its own suite**, the one every other store of the reader's
    /// settings is given — never the runner's `.standard`, where a test's increase would outlive it.
    @Test func theAppGivesTheReviewModelItsSuite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appending(path: "Sources/XiaolaiDict/XiaolaiDictApp.swift"),
                             encoding: .utf8)
        let start = try #require(app.range(of: "lazy var reviewModel = ReviewModel("))
        let end = try #require(app.range(of: "lazy var libraryModel", range: start.upperBound..<app.endIndex))
        #expect(app[start.upperBound..<end.lowerBound].contains("defaults: preferences"),
                "the review model is not given the app's defaults suite")
    }
}
