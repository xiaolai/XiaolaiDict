import SwiftUI
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// **"Did you mean “receive”?" — under a miss, the way out for a typo or a misread** (plan-spelling-suggestion §3).
///
/// A second line, never a replacement: the miss above it is the answer and stays one. Pressing it looks the word up as
/// a lookup of its own; nothing presses it for the reader — mark, never jump.
///
/// **A button that looks like one** — bordered and small, as the card's other in-content controls are ("Yes, That's
/// It", "Choose Another Dictionary…"): the card is paper, and tinted text with no edge said nothing about being
/// pressable (2026-10-01).
struct SpellingSuggestionLine: View {
    @Environment(\.followSuggestion) private var follow
    let suggestion: SpellingSuggestion

    var body: some View {
        Button { follow(suggestion) } label: {
            Text("Did you mean “\(suggestion.word)”?")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // What the press does, which the name alone does not say — and not the name again, which VoiceOver would read
        // twice.
        .help(Text("Look up “\(suggestion.word)” in your dictionaries"))
    }
}

/// **Following a suggestion is the app's job**, as starting any lookup is; the card is handed a way to ask.
///
/// **The default is loud**: a hook nobody set is a button that takes a press and does nothing, so it logs a fault — the
/// rule `WindowActions` holds for an unwired window action.
private struct FollowSuggestionKey: EnvironmentKey {
    static let defaultValue: @MainActor (SpellingSuggestion) -> Void = { _ in
        Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup-panel")
            .fault("spelling: a suggestion was pressed with no app to look it up")
    }
}

extension EnvironmentValues {
    /// **The reader pressed "Did you mean …?"** — look the word up as a new lookup, filed by the panel under the card's
    /// own request.
    public var followSuggestion: @MainActor (SpellingSuggestion) -> Void {
        get { self[FollowSuggestionKey.self] }
        set { self[FollowSuggestionKey.self] = newValue }
    }
}
