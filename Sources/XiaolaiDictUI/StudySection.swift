import StudyKit
import SwiftUI

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

/// **Settings › General › Study**: what is saved for study, and what choosing a meaning does to a
/// word saved without one. One section, because both answer "what ends up in Saved".
struct StudySection: View {
    let keepPolicy: Binding<LookupKeepPolicy>?
    let choice: StudyChoice?

    var body: some View {
        Section {
            if let keepPolicy {
                Picker("Save meanings for study", selection: keepPolicy) {
                    Text("Automatically").tag(LookupKeepPolicy.automatic)
                    Text("Only when I choose Save").tag(LookupKeepPolicy.manual)
                }
            }
            if let choice {
                Toggle("When I choose a meaning for a word I saved, replace the word-only card with it",
                       isOn: Binding(get: { choice.replacesWordCards }, set: { choice.setReplacesWordCards($0) }))
            }
        } header: {
            Text("Study")
        } footer: {
            VStack(alignment: .leading) {
                if keepPolicy != nil {
                    Text("""
                         Every reading is kept in Reading History either way. Meanings saved \
                         automatically come from your study dictionary, and a meaning that was a \
                         guess needs your confirmation before it can be reviewed.
                         """)
                }
                if choice != nil {
                    Text("""
                         Replacing gives the meaning your own answer and tags, and moves the word-only \
                         card to Archived in Saved, where it can be restored. A word-only card you have \
                         already reviewed is kept beside the meaning.
                         """)
                }
            }
        }
    }
}

/// **Settings › General › Review**: the wait after a confirmation. In General beside Study and the
/// reminder because the app has no study pane — a "Learning" tab was rejected on 2026-10-02 — and
/// this decides when a saved meaning first reaches Review, which is what those two sections are about.
struct ReviewWaitSection: View {
    let choice: StudyChoice

    var body: some View {
        Section {
            Toggle("Wait before first asking a meaning I confirm", isOn: Binding(
                get: { choice.waitsAfterConfirming }, set: { choice.setWaitsAfterConfirming($0) }))
            Picker("Wait at least", selection: Binding(
                get: { choice.minimumWait }, set: { choice.setMinimumWait($0) })) {
                ForEach(choice.minimumWaitChoices, id: \.self) { wait in
                    // A duration, which Foundation words in the reader's language — not prose.
                    Text(Duration.seconds(wait), format: .units(allowed: [.hours, .minutes], width: .wide))
                        .tag(wait)
                }
            }
            .disabled(choice.minimumWaitReason != nil)
            if choice.minimumWaitReason == .waitIsOff {
                Text("Turn on the wait to choose how long.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Review")
        } footer: {
            Text("""
                 A meaning you confirm in History, with its answer showing, is first asked on the next \
                 study day and no sooner than the time chosen, so that your first answer is recalled \
                 rather than just read. Optional and untested: it applies to half of those meanings, \
                 chosen at random, so the two halves can be compared.
                 """)
        }
    }
}
