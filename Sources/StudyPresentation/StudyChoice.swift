import Foundation

/// **Two study options the reader chooses, and what changes them** (R1b, R1c — 2026-10-05), handed in
/// by the app like the reminder: the keys and the code that reads them are the app's, and this layer
/// reaches neither. Both are off by default.
public struct StudyChoice {
    /// R1b: choosing a meaning for a word saved without one replaces the word-only card with it —
    /// the reader's answer and tags carried over, the word-only card archived (`Ledger.replaceWordCards`).
    public var replacesWordCards: Bool
    /// R1c: a meaning confirmed in History beside its answer waits before it is first asked.
    public var waitsAfterConfirming: Bool
    /// How long at least it waits — one of `minimumWaitChoices`.
    public var minimumWait: TimeInterval
    public var minimumWaitChoices: [TimeInterval]

    public var setReplacesWordCards: @MainActor (Bool) -> Void
    public var setWaitsAfterConfirming: @MainActor (Bool) -> Void
    public var setMinimumWait: @MainActor (TimeInterval) -> Void

    public init(replacesWordCards: Bool, waitsAfterConfirming: Bool, minimumWait: TimeInterval,
                minimumWaitChoices: [TimeInterval],
                setReplacesWordCards: @escaping @MainActor (Bool) -> Void,
                setWaitsAfterConfirming: @escaping @MainActor (Bool) -> Void,
                setMinimumWait: @escaping @MainActor (TimeInterval) -> Void) {
        self.replacesWordCards = replacesWordCards
        self.waitsAfterConfirming = waitsAfterConfirming
        self.minimumWait = minimumWait
        self.minimumWaitChoices = minimumWaitChoices
        self.setReplacesWordCards = setReplacesWordCards
        self.setWaitsAfterConfirming = setWaitsAfterConfirming
        self.setMinimumWait = setMinimumWait
    }

    /// Why the minimum cannot be chosen — nil while it can. A disabled control says why before the
    /// click (AGENTS.md).
    public enum MinimumWaitReason: Equatable, Sendable {
        case waitIsOff
    }

    public var minimumWaitReason: MinimumWaitReason? { waitsAfterConfirming ? nil : .waitIsOff }
}
