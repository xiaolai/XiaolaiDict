import Foundation
import ReviewKit
import StudyKit
@testable import StudyModels
import Testing
import UserNotifications
import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **What reaches the system, and the one file that reaches it** (review-module-plan §5.3, WI-7).
///
/// The request is built here without the notification center — a request and a calendar trigger are
/// plain values, and only `UNUserNotificationCenter.current()` needs a bundle — so what a banner says
/// and when it fires are asserted on the objects the system is handed.
@MainActor
struct ReminderDeliveryTests {
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let now = Date(timeIntervalSince1970: 1_791_165_600)  // 2026-10-05 10:00 in Shanghai

    /// A reminder as the coordinator plans it, from a ledger whose meaning is a word nobody could
    /// mistake for the app's own words.
    private func planned(showsCount: Bool) async throws -> PlannedReminder {
        let (path, clean) = Wiring.scratch("reminder-content")
        defer { clean() }
        try Wiring.save(try Ledger(path: path), "quixotic", at: now.addingTimeInterval(-10 * 86_400))
        let defaults = TemporaryDefaults.suite()
        ReminderSettingsStore(defaults: defaults).save(
            ReminderSettings(isEnabled: true, showsPredictedCount: showsCount))
        let center = FakeReminderCenter()
        let log = Box(ReminderLog())
        let reminders = ReminderCoordinator(
            scheduling: center, defaults: defaults, logStore: .memory(log), store: Wiring.store(path),
            primary: { PrimaryDictionary(chosen: "noad") }, clock: { self.now }, zone: { Self.shanghai },
            triggers: ReminderTriggers(system: NotificationCenter(), workspace: NotificationCenter(),
                                       ledger: LedgerChanges(), studyDictionary: { "noad" }))
        await reminders.replan(.launch)
        return try #require(center.added.first, "nothing was planned to build a request from")
    }

    // MARK: - What a banner says

    /// **No word, sentence or meaning, by type and on the wire.** `ReminderContent` has no `String`
    /// payload; this checks what the request carries anyway: the title, the count sentence, nothing
    /// else — no subtitle, no user info, no badge, no sound, and an `.active` interruption, never a
    /// time-sensitive one.
    @Test func theContentNeverCarriesText() async throws {
        let reminder = try await planned(showsCount: true)
        #expect(reminder.content == .sittingReady(predictedCount: 1))
        let content = ReminderDelivery.request(for: reminder).content
        #expect(content.title == "Review")
        #expect(content.body == "A sitting of 1 is ready")
        #expect(content.subtitle.isEmpty)
        #expect(content.userInfo.isEmpty)
        #expect(content.badge == nil)
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .active)
        #expect(content.categoryIdentifier == ReminderDelivery.categoryIdentifier)
        for said in [content.title, content.subtitle, content.body] {
            #expect(!said.contains("quixotic") && !said.contains("means"), "reading content reached a banner: \(said)")
        }
    }

    /// Without the count the sentence is the hidden-preview one: the reader chose not to be told N.
    @Test func withoutTheCountTheBannerSaysOnlyThatASittingIsReady() async throws {
        let reminder = try await planned(showsCount: false)
        #expect(reminder.content == .sittingReady(predictedCount: nil))
        #expect(ReminderDelivery.request(for: reminder).content.body == "A sitting is ready")
    }

    /// **The actions and the hidden preview.** Review, Later and Skip Today — and never "Not Today",
    /// which already means putting one card off (ADR-0038). Hidden, the preview keeps the title and
    /// says the sentence without its count.
    @Test func theCategoryOffersReviewLaterAndSkipToday() {
        let category = ReminderDelivery.category()
        #expect(category.identifier == ReminderDelivery.categoryIdentifier)
        #expect(category.actions.map(\.title) == ["Review", "Later", "Skip Today"])
        #expect(!category.actions.contains { $0.title == String(localized: ActionSymbol.notToday.title) })
        #expect(category.actions.map(\.identifier)
                == ReminderDelivery.Action.allCases.map(\.rawValue))
        // Review brings the app forward; the other two are answered where the reader is.
        #expect(category.actions.map { $0.options.contains(.foreground) } == [true, false, false])
        #expect(category.hiddenPreviewsBodyPlaceholder == "A sitting is ready")
        #expect(category.options.contains(.hiddenPreviewsShowTitle))
    }

    // MARK: - What a reader's answer means

    @Test func aResponseIsReadFromItsActionAndItsRequest() throws {
        let day = try #require(ReminderDay(year: 2026, month: 10, day: 5))
        #expect(ReminderDelivery.response(action: UNNotificationDefaultActionIdentifier,
                                          request: "review.2026-10-05") == .open)
        #expect(ReminderDelivery.response(action: ReminderDelivery.Action.open.rawValue,
                                          request: "review.2026-10-05") == .open)
        #expect(ReminderDelivery.response(action: ReminderDelivery.Action.later.rawValue,
                                          request: "review.2026-10-05") == .later(day))
        #expect(ReminderDelivery.response(action: ReminderDelivery.Action.skip.rawValue,
                                          request: "review.2026-10-05.later") == .skip(day))
        // Nothing this app asked for, and nothing a reader chose: no answer.
        #expect(ReminderDelivery.response(action: ReminderDelivery.Action.later.rawValue,
                                          request: "someone.else") == nil)
        #expect(ReminderDelivery.response(action: UNNotificationDismissActionIdentifier,
                                          request: "review.2026-10-05") == nil)
    }

    // MARK: - One owner of the permission

    /// **`granted()` never asks; `ensure()` asks only where the reader has never answered** (ADR-0017).
    @Test func onlyEnsureAsksAndOnlyWhereNobodyHasAnswered() async {
        for grant in [NotificationGrant.granted, .notAsked, .declined, .couldNotTell] {
            let center = FakeReminderCenter(grant: grant)
            let access = NotificationAccess(scheduling: center)
            #expect(await access.granted() == grant)
            #expect(center.requests == 0, "granted() asked, at \(grant)")
        }
        let expected: [(NotificationGrant, Bool, NotificationGrant, Int)] = [
            (.granted, true, .granted, 0),
            (.notAsked, true, .granted, 1),
            (.notAsked, false, .declined, 1),
            (.declined, true, .declined, 0),
            (.couldNotTell, true, .couldNotTell, 0),
        ]
        for (grant, answer, result, asked) in expected {
            let center = FakeReminderCenter(grant: grant)
            center.answer = answer
            #expect(await NotificationAccess(scheduling: center).ensure() == result, "\(grant)")
            #expect(center.requests == asked, "\(grant): asked \(center.requests) times")
        }
    }

    // MARK: - Where the system is named

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
    }

    /// Files whose code — comments aside — contains `spelling`, by name.
    private static func naming(_ spelling: String, under root: URL) throws -> (names: [String], scanned: Int) {
        let found = try SourceScan.offenders(of: spelling, under: root)
        return (found.names.sorted(), found.scanned)
    }

    /// **`UNUserNotificationCenter` is named in one file, and the module imported in that one.** Its
    /// `current()` aborts a bundle-less process, so every other caller goes through
    /// `ReminderScheduling` — which is what lets every test above use a fake. The services are covered
    /// by `ModuleBoundaryTests` and, linked, by `verify_service_boundaries`.
    @Test func theNotificationCenterIsNamedInExactlyOneFile() throws {
        let center = try Self.naming("UNUserNotificationCenter", under: Self.sources)
        #expect(center.scanned > 100, "scanned only \(center.scanned) files — the source walk is broken")
        #expect(center.names == ["ReminderDelivery.swift"], "\(center.names)")
        #expect(try Self.naming("import UserNotifications", under: Self.sources).names == ["ReminderDelivery.swift"])
        // **One owner of the permission**: the protocol's request is called from `NotificationAccess`
        // alone, and the system's from the delivery that implements it.
        #expect(try Self.naming(".requestAuthorization()", under: Self.sources).names == ["NotificationAccess.swift"])
        #expect(try Self.naming(".requestAuthorization(options:", under: Self.sources).names
                == ["ReminderDelivery.swift"])
    }

    /// The control: a planted mention is found, and one inside a comment is not.
    @Test func aPlantedMentionOfTheCenterIsFound() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-planted-center")
        try "/// UNUserNotificationCenter, in prose\nlet quiet = 1\n"
            .write(to: scratch.appending("Commented.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.naming("UNUserNotificationCenter", under: scratch.url).names.isEmpty)
        try "import UserNotifications\nlet planted = UNUserNotificationCenter.current()\n"
            .write(to: scratch.appending("Planted.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.naming("UNUserNotificationCenter", under: scratch.url).names == ["Planted.swift"])
    }
}
