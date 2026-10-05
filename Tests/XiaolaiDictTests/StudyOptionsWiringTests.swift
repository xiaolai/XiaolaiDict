import Foundation
import ReviewKit
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The study options in Settings › General — off by default, one key each, and read by what they
/// change** (R1b, R1c; 2026-10-05).
///
/// The wait after a confirmation was a defaults key set by hand (WI-4); it is a switch and a choice of
/// minimum now, and the confirmation hook reads the same `ConfirmationCooldownSetting` the switch
/// writes, so the two cannot disagree. Asserted at the wire: a value chosen through the choice
/// Settings draws reaches History's Confirm, and the card is hidden for exactly that long.
@MainActor
struct StudyOptionsWiringTests {
    /// The persistent spellings. **Written out, not read from the types**: a renamed key is every reader
    /// who chose something silently put back to the default, and this is what notices.
    private static let fourHours: TimeInterval = 4 * 3_600
    private static let threeHours: TimeInterval = 3 * 3_600

    private static let keys = ["reviewConfirmationCooldown", "reviewConfirmationCooldownMinimumDelay",
                               "studyReplacesWordCards"]

    @Test func everyOptionIsOffByDefaultAndReadingThemWritesNothing() {
        let suite = TemporaryDefaults.suite()
        let choice = StudyOptions(defaults: suite).choice
        #expect(!choice.replacesWordCards)
        #expect(!choice.waitsAfterConfirming)
        #expect(choice.minimumWait == ConfirmationCooldown.placeholderMinimumDelay)
        #expect(choice.minimumWaitChoices == ConfirmationCooldown.minimumDelayChoices)
        for key in Self.keys { #expect(suite.object(forKey: key) == nil, "\(key) was written by reading it") }
    }

    /// **Each choice is kept under its one key, in the suite the app was given**, and read back by a
    /// fresh owner — what the next launch is.
    @Test func eachChoiceIsKeptUnderItsOneKey() {
        let suite = TemporaryDefaults.suite()
        let options = StudyOptions(defaults: suite)
        options.choice.setReplacesWordCards(true)
        options.choice.setWaitsAfterConfirming(true)
        options.choice.setMinimumWait(Self.fourHours)
        #expect(suite.object(forKey: Self.keys[0]) as? Bool == true)
        #expect(suite.object(forKey: Self.keys[1]) as? Double == Self.fourHours)
        #expect(suite.object(forKey: Self.keys[2]) as? Bool == true)

        let again = StudyOptions(defaults: suite).choice
        #expect(again.replacesWordCards && again.waitsAfterConfirming && again.minimumWait == Self.fourHours)
        #expect(options.choice.minimumWait == Self.fourHours, "the observed copy did not follow the write")
    }

    /// **A switch set by hand** — `defaults write … reviewConfirmationCooldown -bool true`, the only
    /// way on before this — **is the switch Settings shows.**
    @Test func theSwitchSetByHandIsTheOneSettingsShows() {
        let suite = TemporaryDefaults.suite()
        suite.set(true, forKey: Self.keys[0])
        #expect(StudyOptions(defaults: suite).choice.waitsAfterConfirming)
    }

    /// The minimum's picker is disabled while the wait is off, and says why.
    @Test func theMinimumIsDisabledWithItsReasonWhileTheWaitIsOff() {
        let options = StudyOptions(defaults: TemporaryDefaults.suite())
        #expect(options.choice.minimumWaitReason == .waitIsOff)
        options.choice.setWaitsAfterConfirming(true)
        #expect(options.choice.minimumWaitReason == nil)
    }

    // MARK: - What History's Confirm does with them

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// One hour before a study day's cutoff, so the next study day is an hour away and only the minimum
    /// decides when the card comes back — 4 h and 8 h land on different instants.
    private var confirmedAt: Date { StudyDay.standard.startOfNextDay(containing: base).addingTimeInterval(-3_600) }

    private func lookup(_ ledger: Ledger, _ word: String) throws -> Int {
        try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word) in it.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: base, result: .found, answeredBy: .dictionaryService, quality: nil, script: .latin))
    }

    /// A proposal — the dictionary's text, not yet the reader's — in the arm the rule waits for. Ids are
    /// random, so it saves until one lands there; sixty-four misses is a one-in-2⁶⁴ event.
    private func proposalInTheWaitingArm(_ ledger: Ledger) throws -> StudyNote {
        for index in 0..<64 {
            let note = try ledger.enroll(
                .sense(dictionary: "noad", entryID: "e\(index)", senseKey: "e\(index).1", senseKeyKind: .publisher),
                issuer: .live, language: "en", chosenBy: .model,
                answer: StudyAnswer(origin: .dictionary, text: "what it means"),
                lookupID: try lookup(ledger, "word\(index)"), at: base)
            if ConfirmationCooldown().hiddenUntil(noteID: note.id, confirmedAt: base, exposure: .answerShown) != nil {
                return note
            }
        }
        throw WiringTimeout(what: "no note landed in the waiting arm")
    }

    /// History's inspector Confirm — the surface that shows the answer — on the app's model, in `suite`.
    private func confirmFromHistory(_ path: String, _ id: UUID, suite: UserDefaults) async throws -> StudyCard {
        let when = confirmedAt
        let model = LibraryModel(store: Wiring.store(path), clock: { when },
                                 exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                                 defaults: suite, primary: { PrimaryDictionary(chosen: "noad") })
        model.actArchive(.confirm(id))
        try await Wiring.settle("the confirmation never landed") {
            (try? Ledger(path: path).notes().first { $0.id == id })?.confirmedAt != nil
        }
        return try Ledger(path: path).card(of: id, at: when)
    }

    private func waitedFor(_ minimum: TimeInterval, _ id: UUID) -> Date? {
        ConfirmationCooldown(studyDay: .standard, minimumDelay: minimum)
            .hiddenUntil(noteID: id, confirmedAt: confirmedAt, exposure: .answerShown)
    }

    /// **The minimum chosen in Settings is the one the confirmation waits** — through the choice
    /// Settings draws, into the suite, out through the hook.
    @Test func theWaitChosenInSettingsIsTheOneHistorysConfirmApplies() async throws {
        let (path, clean) = Wiring.scratch("options-wait")
        defer { clean() }
        let note = try proposalInTheWaitingArm(try Ledger(path: path))
        let suite = TemporaryDefaults.suite()
        let options = StudyOptions(defaults: suite)
        options.choice.setWaitsAfterConfirming(true)
        options.choice.setMinimumWait(Self.fourHours)
        let four = try #require(waitedFor(Self.fourHours, note.id))
        let eight = try #require(waitedFor(ConfirmationCooldown.placeholderMinimumDelay, note.id))
        #expect(four != eight, "the premise: the two minimums land on different instants")

        let card = try await confirmFromHistory(path, note.id, suite: suite)
        #expect(card.hiddenUntil == four, "the confirmation waited \(String(describing: card.hiddenUntil)), not the 4 h chosen")
    }

    /// **A minimum chosen with the switch off changes nothing** — the card exactly as it was, which is
    /// today's behaviour (`FunnelWiringTests.withTheExperimentOffAConfirmationHidesNothing`).
    @Test func aMinimumChosenWithTheSwitchOffHidesNothing() async throws {
        let (path, clean) = Wiring.scratch("options-wait-off")
        defer { clean() }
        let note = try proposalInTheWaitingArm(try Ledger(path: path))
        let before = try Ledger(path: path).card(of: note.id, at: base)
        let suite = TemporaryDefaults.suite()
        StudyOptions(defaults: suite).choice.setMinimumWait(Self.fourHours)

        let card = try await confirmFromHistory(path, note.id, suite: suite)
        #expect(card == before, "a confirmation touched the card with the wait off")
    }

    /// **A minimum kept off the menu is the placeholder for both** — what the picker shows and what the
    /// confirmation waits.
    @Test func aMinimumOffTheMenuIsThePlaceholderForBoth() async throws {
        let (path, clean) = Wiring.scratch("options-wait-stray")
        defer { clean() }
        let note = try proposalInTheWaitingArm(try Ledger(path: path))
        let suite = TemporaryDefaults.suite()
        suite.set(true, forKey: Self.keys[0])
        suite.set(Self.threeHours, forKey: Self.keys[1])
        #expect(StudyOptions(defaults: suite).choice.minimumWait == ConfirmationCooldown.placeholderMinimumDelay)

        let card = try await confirmFromHistory(path, note.id, suite: suite)
        #expect(card.hiddenUntil == waitedFor(ConfirmationCooldown.placeholderMinimumDelay, note.id))
    }

    /// **The app builds the options over its own suite**, and its Library reads the same one.
    @Test func theAppsOptionsAreTheSuiteItWasGiven() {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite), reminders: FakeReminderCenter())
        app.studyOptions.choice.setWaitsAfterConfirming(true)
        #expect(ConfirmationCooldownSetting(defaults: suite).cooldown != nil,
                "the switch in Settings did not reach the suite the confirmation reads")
        #expect(StudyOptions(defaults: app.preferences).choice.waitsAfterConfirming)
    }
}
