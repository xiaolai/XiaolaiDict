import Foundation
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// The setup board reads live state, always shows every row, and remembers nothing.
struct SetupBoardTests {
    private static let oxford = DictionaryCapability(
        identity: DictionaryIdentity(name: "牛津英汉汉英词典", identifier: "com.apple.dictionary.zh_CN-en.OCD"),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "zh_CN", explains: "zh_CN"), .init(index: "en", explains: "zh_CN")],
        indexes: [.latin, .han])
    private static let noad = DictionaryCapability(
        identity: DictionaryIdentity(name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD"),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "en_US", explains: "en_US")], indexes: [.latin])

    /// A usable combination — ⌃⌥D, as shipped.
    private static let combination = Shortcut(keyCode: 2, modifiers: 2_048 + 4_096)

    private func board(
        accessibility: Bool = true, screenRecording: Bool = true,
        available: [DictionaryCapability]? = [oxford, noad],
        chosen: String? = "com.apple.dictionary.NOAD",
        language: String = "en-US",
        shortcut: Shortcut? = combination,
        shortcutIsRegistered: Bool = true,
        engine: SenseEngineStatus = .onDevice
    ) -> SetupBoard {
        SetupBoard(
            permissions: PermissionsReport(states: [
                PermissionState(permission: .accessibility, isGranted: accessibility),
                PermissionState(permission: .screenRecording, isGranted: screenRecording),
            ]),
            available: available, chosen: chosen, language: language, shortcut: shortcut,
            shortcutIsRegistered: shortcutIsRegistered, engine: engine)
    }

    // MARK: - Rows read live state

    @Test func aGrantedPermissionSettlesItsRow() {
        #expect(board(accessibility: true).isSettled(.accessibility))
        #expect(!board(accessibility: false).isSettled(.accessibility))
        #expect(board(screenRecording: true).isSettled(.screenRecording))
        #expect(!board(screenRecording: false).isSettled(.screenRecording))
    }

    /// A permission the report never mentions is not granted. Reading a missing row as "fine" is
    /// how a board comes to show a tick for something nobody ever asked about.
    @Test func aPermissionMissingFromTheReportIsNotGranted() {
        let empty = SetupBoard(
            permissions: PermissionsReport(states: []), available: nil, chosen: nil,
            language: "en", shortcut: nil, engine: .onDevice)
        #expect(!empty.isGranted(.accessibility))
        #expect(!empty.isSettled(.screenRecording))
    }

    /// Settled by the reader having chosen, never by a proposal existing.
    @Test func aProposalIsAnOfferAndDoesNotSettleTheDictionaryRow() {
        let waiting = board(chosen: nil, language: "zh-Hans-CN")
        #expect(waiting.proposal == .propose(Self.oxford))
        #expect(!waiting.isSettled(.dictionary))
        #expect(waiting.outstanding.contains(.dictionary))
        #expect(board().isSettled(.dictionary))
    }

    /// The proposal follows the reader's language, which is the whole point of the rule.
    @Test func theProposalFollowsTheReadersLanguage() {
        #expect(board(language: "zh-Hans-CN").proposal == .propose(Self.oxford))
        #expect(board(language: "en-US").proposal == .propose(Self.noad))
        #expect(board(language: "ko-KR").proposal == .nothingSuitable)
    }

    /// "Still asking" and "you have none" must not read the same.
    @Test func anUnansweredServiceIsNotAnEmptyDictionaryList() {
        #expect(board(available: nil).available == nil)
        #expect(board(available: []).available == [])
        #expect(board(available: nil).proposal == .nothingSuitable)
    }

    @Test func theShortcutRowFollowsWhetherOneIsUsable() {
        #expect(board().isSettled(.shortcut))
        #expect(!board(shortcut: nil).isSettled(.shortcut))
    }

    // MARK: - A chosen dictionary that went away

    /// The reader disabled their study dictionary in Dictionary.app. Every lookup now abstains, so
    /// the row unsettles and says so — this is the job the board keeps doing after the first run.
    @Test func aChosenDictionaryThatIsNoLongerEnabledUnsettlesTheRow() {
        let gone = board(available: [Self.oxford], chosen: "com.apple.dictionary.NOAD")
        #expect(gone.chosenDictionaryIsMissing)
        #expect(gone.chosenDictionary == nil)
        #expect(!gone.isSettled(.dictionary))
        #expect(!gone.isComplete)
    }

    /// While the service has not answered, a chosen dictionary is not declared missing. An
    /// unanswered list is not evidence of absence.
    @Test func anUnansweredListNeverDeclaresTheChosenDictionaryMissing() {
        let asking = board(available: nil, chosen: "com.apple.dictionary.NOAD")
        #expect(!asking.chosenDictionaryIsMissing)
        #expect(asking.isSettled(.dictionary))
    }

    @Test func aChosenDictionaryStillEnabledIsFound() {
        #expect(board().chosenDictionary == Self.noad)
    }

    // MARK: - What the board still wants from the reader

    /// The shortcut ships with a working default and is on the board to teach the gesture.
    @Test func anUnusableShortcutIsNotSomethingTheReaderMustDo() {
        let board = board(shortcut: nil)
        #expect(!board.isSettled(.shortcut))
        #expect(!board.outstanding.contains(.shortcut))
        #expect(board.isComplete)
    }

    @Test func everythingOutstandingIsListedInBoardOrder() {
        let board = board(accessibility: false, screenRecording: false, chosen: nil)
        #expect(board.outstanding == [.accessibility, .screenRecording, .dictionary])
        #expect(!board.isComplete)
    }

    // MARK: - Reopening shows the board, not a congratulation

    /// Every row, every time.
    @Test func aFinishedBoardStillShowsEveryRow() {
        let finished = board()
        #expect(finished.isComplete)
        #expect(finished.steps == SetupBoard.Step.allCases)
        #expect(finished.steps.count == 5)

        let fresh = board(accessibility: false, screenRecording: false, chosen: nil, shortcut: nil)
        #expect(!fresh.isComplete)
        #expect(fresh.steps == finished.steps, "a finished board shows the same rows as a fresh one")
    }

    // MARK: - Found by the audit

    /// A well-formed combination is not a registered one. `RegisterEventHotKey` fails with
    /// `eventHotKeyExistsErr` when another app holds it exclusively, and the app then falls back to
    /// showing the saved combination — so the row drew "Ready" over a shortcut that answered
    /// nothing.
    @Test func aShortcutThatNeverRegisteredIsNotReady() {
        #expect(board(shortcutIsRegistered: true).isSettled(.shortcut))
        #expect(!board(shortcutIsRegistered: false).isSettled(.shortcut))
    }

    /// "Everything needed is in place" is a stronger claim than "this row is settled", and it
    /// cannot be made over a dictionary service that never answered — that is a failure rendering
    /// as confidently as a success.
    @Test func completenessIsNotClaimedWhileTheServiceHasNotAnswered() {
        let asking = board(available: nil)
        #expect(asking.isAsking)
        #expect(asking.outstanding.isEmpty, "a saved choice still settles its own row")
        #expect(!asking.isComplete, "the board claimed completeness without a dictionary list")
        #expect(board().isComplete)
    }

    /// **"None declares it" is not "you have none."** Six of the seven dictionaries on the
    /// development Mac declare no language, so the rule cannot propose one — but telling a reader
    /// with Longman enabled that they have no English dictionary would be false. This is the
    /// consumer the script probe was missing.
    @Test func aDictionaryThatDeclaresNothingIsStillCountedAsIndexingEnglish() {
        let longman = DictionaryCapability(
            identity: DictionaryIdentity(name: "Longman"), senseKeyKind: .position, probed: true,
            languages: [], indexes: [.latin])
        let korean = DictionaryCapability(
            identity: DictionaryIdentity(name: "Korean"), senseKeyKind: .none, probed: true,
            languages: [], indexes: [.hangul])
        let board = board(available: [longman, korean], chosen: nil, language: "ko")

        #expect(board.proposal == .nothingSuitable, "neither declares a language, so neither is proposed")
        #expect(board.undeclaredEnglishDictionaries == [longman])
        #expect(!board.undeclaredEnglishDictionaries.contains(korean))
    }

    @Test func aDictionaryThatDeclaresItsLanguagesIsNotCountedAsUndeclared() {
        #expect(board().undeclaredEnglishDictionaries.isEmpty)
    }

    // MARK: - The sense engine

    /// Reported, never demanded. Measured 2026-09-22 over three identical runs, the
    /// confidently-wrong rate is 17% with Apple's on-device model and 17% with the `NLEmbedding`
    /// fallback — so an unavailable model is not a task, and counting it would leave a reader with
    /// nothing they can act on staring at an unfinished board.
    @Test func anUnavailableModelIsReportedAndNeverAskedFor() {
        let without = board(engine: .unavailable(.deviceNotEligible))
        #expect(!without.isSettled(.senseEngine))
        #expect(!without.outstanding.contains(.senseEngine))
        #expect(without.isComplete)
    }

    @Test func theEngineRowFollowsWhatIsActuallyBackingSelection() {
        #expect(board(engine: .onDevice).isSettled(.senseEngine))
        #expect(!board(engine: .unavailable(.appleIntelligenceNotEnabled)).isSettled(.senseEngine))
        #expect(board(engine: .unavailable(.modelNotReady)).engine.reason == .modelNotReady)
        #expect(board(engine: .onDevice).engine.reason == nil)
    }

    /// The board holds no flag about having been shown. Whether the window opened by itself is
    /// somebody else's question, and mixing the two is how re-running becomes impossible.
    ///
    /// **Read from the source, because the obvious test cannot fail.** Comparing two identically
    /// built boards proves nothing: a completion flag added with the same default on both sides
    /// would compare equal and the check would pass over exactly the change it exists to stop.
    /// What can fail is the board reaching for the store at all.
    @Test func theBoardNeverConsultsWhetherItHasBeenShown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/XiaolaiDictUI/SetupBoard.swift", "Sources/XiaolaiDictUI/SetupView.swift"] {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            #expect(!text.isEmpty, "\(file) is empty, so this scanned nothing")
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(
                !code.contains("hasOpenedBefore") && !code.contains("SetupPresentationStore"),
                "\(file) reads the presentation flag; it must never decide what the board shows")
        }
    }
}
