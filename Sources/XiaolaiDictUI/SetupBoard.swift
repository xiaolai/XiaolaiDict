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

        public var id: String { rawValue }

        /// Whether an unsettled step is something the reader still has to do.
        ///
        /// The shortcut is not: it ships with a working default, and it is on the board to *teach*
        /// the gesture rather than to ask for anything. Counting it would leave a reader with
        /// nothing left to do looking at a permanently unfinished board.
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

    public init(
        permissions: PermissionsReport, available: [DictionaryCapability]?, chosen: String?,
        language: String, shortcut: Shortcut?
    ) {
        self.permissions = permissions
        self.available = available
        self.chosen = chosen
        self.language = language
        self.shortcut = shortcut
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
        case .shortcut: shortcut?.isUsable == true
        }
    }

    public func isGranted(_ permission: Permission) -> Bool {
        permissions.states.first { $0.permission == permission }?.isGranted ?? false
    }

    /// The steps still waiting on the reader, in board order.
    public var outstanding: [Step] { steps.filter { $0.needsReader && !isSettled($0) } }

    /// Whether the reader has nothing left to do. Not whether every row shows a tick.
    public var isComplete: Bool { outstanding.isEmpty }
}
