import DictionaryModel
import XiaolaiDictCore

/// What a fresh install still needs, read from live state every time it is asked.
///
/// **A board, not a script.** Each step reports what is true right now, so "set up again" is
/// nothing more than opening the window — there is no progress to resume and no completion to
/// remember. The one flag in this feature (`SetupPresentationStore`) decides whether the window
/// *opens by itself* at launch and never what it shows; a `hasCompletedSetup` that gated content is
/// how a status board rots into a wizard that can only be run once.
///
/// The steps are independent facts rather than stages. Nothing here is ordered, nothing waits on a
/// Next button, and a reader who grants a permission in System Settings sees the row change without
/// touching this window — `SettingsModel` already polls for exactly that, because macOS posts
/// nothing when a permission changes.
public struct SetupBoard: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable, Identifiable {
        case accessibility
        case screenRecording
        case dictionary
        case shortcut
        /// The local model: one row for translation and sense picking, because one download does both.
        case localModel

        public var id: String { rawValue }

        /// Whether an unsettled step is something the reader still has to do.
        ///
        /// The shortcut is not: it ships with a working default, and it is on the board to *teach*
        /// the gesture rather than to ask for anything. Counting it would leave a reader with
        /// nothing left to do looking at a permanently unfinished board.
        ///
        /// **The local model is**, which the sense-engine row it replaced was not. That row's
        /// reason — "nothing a reader can do about it inside this app" — stopped being true once
        /// there was a download only the reader can agree to. It is settled by the download, or by
        /// the reader choosing **Not now**; either way it is their answer, and it is asked once.
        public var needsReader: Bool { self != .shortcut }
    }

    public let permissions: PermissionsReport
    /// Every enabled dictionary, or **nil while the service has not answered**. Nil and empty are
    /// different states and must not read the same: one is "asking", the other is "you have none".
    public let available: [DictionaryCapability]?
    /// The primary dictionary the reader settled on, as a `DictionaryIdentity.key`.
    public let chosen: String?
    /// The reader's own language, from `ReaderLanguage.preferred`.
    public let language: String
    /// The lookup shortcut as the app holds it.
    public let shortcut: Shortcut?
    /// Whether the hot key is actually registered. **Not the same as the combination being
    /// well-formed**: `RegisterEventHotKey` fails with `eventHotKeyExistsErr` when another app
    /// holds the combination exclusively, and the app then falls back to showing the saved one. A
    /// row reading `isUsable` alone drew "Ready" over a shortcut that answered nothing.
    public let shortcutIsRegistered: Bool
    /// The local model on this Mac, read from its store and the download in flight. **Nil where the
    /// board was built without it** — a preview, or a caller that forgot: the row then reports that
    /// it does not know, rather than asking the reader for a download it has no way to start.
    public let model: LocalModelState?
    /// The reader chose **Not now** — its own persisted flag, so it survives the app quitting.
    /// **No default.** Defaulted to false, a caller that had not wired it up asked the reader again
    /// for something they had already declined, and nothing said so.
    public let modelDeclined: Bool
    /// Apple's on-device model, which is no longer a row of its own: it is the fallback the model
    /// row names while the model is absent, because that is what picks senses meanwhile.
    public let engine: SenseEngineStatus

    public init(
        permissions: PermissionsReport, available: [DictionaryCapability]?, chosen: String?,
        language: String, shortcut: Shortcut?, shortcutIsRegistered: Bool = true,
        model: LocalModelState?, modelDeclined: Bool, engine: SenseEngineStatus
    ) {
        self.permissions = permissions
        self.available = available
        self.chosen = chosen
        self.language = language
        self.shortcut = shortcut
        self.shortcutIsRegistered = shortcutIsRegistered
        self.model = model
        self.modelDeclined = modelDeclined
        self.engine = engine
    }

    /// Every step, always, in a fixed order. The board shows all of them whether or not they are
    /// settled — a row that vanishes once it is done takes with it the only place the reader could
    /// go to change their mind.
    public var steps: [Step] { Step.allCases }

    /// What to offer a reader who has not chosen. Computed rather than stored, so it cannot go
    /// stale against the list it was derived from.
    public var proposal: StudyDictionaryProposal {
        .forReader(of: language, among: available ?? [])
    }

    /// The dictionary the reader chose, if it is still enabled.
    ///
    /// Nil with a non-nil `chosen` is a real and important state: the reader disabled their study
    /// dictionary in Dictionary.app, and every lookup now abstains.
    public var chosenDictionary: DictionaryCapability? {
        guard let chosen else { return nil }
        return available?.first { $0.identity.key == chosen }
    }

    /// Dictionaries that declare no language but were **measured** to index English.
    ///
    /// This is what the script probe is for, and until now nothing read it. A sideloaded
    /// conversion declares nothing and every Apple asset does — **three of the seven enabled on
    /// the development Mac declare no language, and they are the same three that are sideloaded**,
    /// measured 2026-09-24 by reading `DCSDictionaryLanguages` out of all seven bundles — so the
    /// rule in `StudyDictionaryProposal` cannot classify them: a records probe says what a
    /// dictionary indexes and never what it explains in. But "none declares it" and "you have
    /// none" are different sentences, and telling a reader with Longman and Collins enabled that
    /// they have no English dictionary is simply false.
    public var undeclaredEnglishDictionaries: [DictionaryCapability] {
        (available ?? []).filter { $0.languages.isEmpty && $0.indexes.contains(.latin) }
    }

    /// True when the reader chose a dictionary that is no longer enabled.
    public var chosenDictionaryIsMissing: Bool {
        guard chosen != nil, let available else { return false }
        return !available.contains { $0.identity.key == chosen }
    }

    public func isSettled(_ step: Step) -> Bool {
        switch step {
        case .accessibility: isGranted(.accessibility)
        case .screenRecording: isGranted(.screenRecording)
        // Settled by the reader having chosen, never by a proposal being available. A proposal is
        // an offer; until it is taken the seat is empty, and the unchosen primary is whatever comes
        // first in Dictionary.app's order — which on the development Mac is a dictionary that
        // labels its blocks `n.`/`vt.` and narrows nothing.
        case .dictionary: chosen != nil && !chosenDictionaryIsMissing
        case .shortcut: shortcut?.isUsable == true && shortcutIsRegistered
        // Downloaded, or declined. And a Mac that cannot hold even the smallest size has nothing to
        // ask of its reader: a row that stayed "needed" there could never be settled at all.
        case .localModel:
            switch model {
            case .ready: true
            // A Mac that cannot hold the model has nothing to settle — see `isAvailable`, which is
            // what keeps the row from drawing a tick over something the reader never got. Nor does
            // a board that was never told about the model.
            case .tooLittleMemory, nil: false
            // A first download is not an answer yet, whatever was chosen before it started — but an
            // upgrade is: the model it replaces is answering throughout.
            case .downloading(_, _, let replacing): replacing != nil
            case .stopped(_, _, let replacing): replacing != nil || modelDeclined
            case .notDownloaded: modelDeclined
            }
        }
    }

    /// Whether this step can be had on this Mac at all. **Not the same as settled**: a Mac with too
    /// little memory for the model is not waiting on its reader, and it has not got the model
    /// either — a tick there would claim something the reader never received.
    public func isAvailable(_ step: Step) -> Bool {
        guard step == .localModel else { return true }
        guard let model else { return false }
        return model != .tooLittleMemory
    }

    public func isGranted(_ permission: Permission) -> Bool {
        permissions.states.first { $0.permission == permission }?.isGranted ?? false
    }

    /// The steps still waiting on the reader, in board order. A step this Mac cannot have is not
    /// one of them: there is nothing for the reader to do about it.
    public var outstanding: [Step] { steps.filter { $0.needsReader && !isSettled($0) && isAvailable($0) } }

    /// Whether the reader has nothing left to do. Not whether every row shows a tick.
    ///
    /// **Unknowable while the dictionary list has not answered.** A saved choice settles its row,
    /// because an unanswered list is not evidence the dictionary went away — but "everything needed
    /// is in place" is a stronger claim than that, and making it over a service that never replied
    /// is exactly the failure rendering as confidently as a success.
    /// `model != nil` for the same reason `available != nil` is here: a board that was never told
    /// about the model does not *know* that row is settled, and `isAvailable` leaves an unknown row
    /// out of `outstanding` — so without this, "nothing left to do" was reported over a row nobody
    /// had answered, which is the onboarding invariant read backwards.
    public var isComplete: Bool { outstanding.isEmpty && available != nil && model != nil }

    /// Whether the board is still waiting to be able to say anything about the dictionary.
    public var isAsking: Bool { available == nil }
}
