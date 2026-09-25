import DictionaryModel
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
        model: LocalModelState? = .ready(.standard),
        modelDeclined: Bool = false,
        engine: SenseEngineStatus = .onDevice
    ) -> SetupBoard {
        SetupBoard(
            permissions: PermissionsReport(states: [
                PermissionState(permission: .accessibility, isGranted: accessibility),
                PermissionState(permission: .screenRecording, isGranted: screenRecording),
            ]),
            available: available, chosen: chosen, language: language, shortcut: shortcut,
            shortcutIsRegistered: shortcutIsRegistered, model: model, modelDeclined: modelDeclined,
            engine: engine)
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
            language: "en", shortcut: nil, model: .notDownloaded, modelDeclined: false,
            engine: .onDevice)
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

        let fresh = board(
            accessibility: false, screenRecording: false, chosen: nil, shortcut: nil, model: .notDownloaded)
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

        // **Nor over a model row nobody answered.** `isAvailable` leaves an unknown row out of
        // `outstanding` — which is right for a Mac that cannot hold a model and wrong for a board
        // that was never told, and the two are the same value here.
        let unknown = board(model: nil)
        #expect(unknown.outstanding.isEmpty)
        #expect(!unknown.isComplete, "the board claimed completeness while it knew nothing about the model")
    }

    /// **"None declares it" is not "you have none."** Three of the seven dictionaries enabled on
    /// the development Mac declare no language, so the rule cannot classify them — but telling a
    /// reader with Longman enabled that they have no English dictionary would be false. This is
    /// the consumer the script probe was missing.
    ///
    /// **The declares-nothing three and the sideloaded three are the same three**, measured
    /// 2026-09-24 from all seven bundles' `DCSDictionaryLanguages`: every Apple asset declares,
    /// no sideloaded conversion does. Two earlier readings of this had them as different counts
    /// — "six declare nothing, three are sideloaded" — which was the *installed* sideloaded six
    /// wearing the enabled seven's denominator. The fixture below does not depend on the number:
    /// it is a language claim tested through the rule, and `languages: []` is what carries it.
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

    // MARK: - The local model

    /// **A download the reader has not agreed to is still needed** — the row the sense engine used
    /// to be did not ask anything, and this one does: a 3 GB download only the reader can agree to.
    @Test func aModelNotYetDownloadedIsStillNeeded() {
        let fresh = board(model: .notDownloaded)
        #expect(SetupBoard.Step.localModel.needsReader)
        #expect(!fresh.isSettled(.localModel))
        #expect(fresh.outstanding == [.localModel])
        #expect(!fresh.isComplete)
    }

    /// Settled two ways, and both are the reader's answer: the model is here, or they said Not now.
    @Test func downloadedOrDeclinedSettlesTheRow() {
        #expect(board(model: .ready(.standard)).isSettled(.localModel))
        #expect(board(model: .ready(.small)).isComplete)
        let declined = board(model: .notDownloaded, modelDeclined: true)
        #expect(declined.isSettled(.localModel))
        #expect(declined.isComplete)
        #expect(board(model: .stopped(reason: "x", size: .standard), modelDeclined: true).isSettled(.localModel))
    }

    /// A download in flight, or one that stopped, is not yet an answer.
    @Test func aDownloadUnderWayOrStoppedIsNotSettled() {
        let progress = ModelDownloadProgress(received: 1, total: 2)
        #expect(!board(model: .downloading(progress, size: .standard)).isSettled(.localModel))
        #expect(!board(model: .stopped(reason: "the connection failed", size: .standard)).isSettled(.localModel))
    }

    /// A Mac that cannot hold even 2B has nothing to ask of its reader — a row that stayed needed
    /// there could never be settled, and the board would be unfinished forever. **But it is not
    /// settled either**: a tick would claim the reader had got something they have not.
    @Test func aMacWithTooLittleMemoryIsNotAskedForAnythingAndIsNotTicked() {
        let small = board(model: .tooLittleMemory)
        #expect(!small.isAvailable(.localModel))
        #expect(!small.isSettled(.localModel), "a Mac that cannot run the model showed a tick for it")
        #expect(!small.outstanding.contains(.localModel))
        #expect(small.isComplete)
        #expect(board().isAvailable(.localModel))
    }

    /// An upgrade keeps the row settled: the model it replaces is answering the whole time.
    @Test func anUpgradeLeavesTheRowSettled() {
        let progress = ModelDownloadProgress(received: 1, total: 2)
        let upgrading = board(model: .downloading(progress, size: .large, replacing: .standard))
        #expect(upgrading.isSettled(.localModel))
        #expect(upgrading.isComplete)
        #expect(board(model: .stopped(reason: "x", size: .large, replacing: .standard)).isSettled(.localModel))
    }

    /// A board built without the model's state asks the reader for nothing: it does not know.
    @Test func aBoardWithNoModelStateAsksForNothing() {
        let unknowing = board(model: nil)
        #expect(!unknowing.isAvailable(.localModel))
        #expect(!unknowing.isSettled(.localModel))
        #expect(!unknowing.outstanding.contains(.localModel))
    }

    /// A download under way is not an answer, whatever was chosen before it started.
    @Test func aRunningDownloadIsNeverSettled() {
        let progress = ModelDownloadProgress(received: 1, total: 2)
        #expect(!board(model: .downloading(progress, size: .standard), modelDeclined: true).isSettled(.localModel))
    }

    /// Apple's model is no longer a row; it is what the model row names as the fallback, so it is
    /// still read — and still read from the one place that asks.
    @Test func appleIntelligenceIsTheFallbackNotARow() {
        #expect(!SetupBoard.Step.allCases.map(\.rawValue).contains("senseEngine"))
        #expect(board(engine: .unavailable(.modelNotReady)).engine.reason == .modelNotReady)
        #expect(board(engine: .onDevice).engine.isOnDevice)
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
