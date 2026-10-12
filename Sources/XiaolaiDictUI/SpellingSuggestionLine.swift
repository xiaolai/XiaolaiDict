import SwiftUI
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// **"Look up “receive”" — under a miss, the one way out for a typo, a misread or an inflection the dictionaries do not
/// answer** (plan-spelling-suggestion §3; the owner's ruling of 2026-10-11, ADR-0054 part B).
///
/// A button under the miss, never a replacement: the miss above it is the answer and stays one until the reader presses.
/// Pressing it looks the word up as a lookup of its own; nothing presses it for the reader — mark, never jump.
///
/// **The same words for every kind of offer** — a printed form, a regular one, the checker's correction. The words say
/// what the press does and claim nothing about the reader's spelling or the word's relation to it: "Did you mean" calls
/// the reader wrong, and a label naming the evidence ("A guess from the spelling") was rejected. Why the word is offered
/// stays in the model and the instrument (`SpellingSuggestion.Evidence`, `--spelling-report`).
///
/// **A button that looks like one** — bordered and small, as the card's other in-content controls are ("Yes, That's
/// It", "Choose Another Dictionary…"): the card is paper, and tinted text with no edge said nothing about being
/// pressable (2026-10-01). Its words wrap at a large text size rather than run past the card.
struct SpellingSuggestionLine: View {
    @Environment(\.followSuggestion) private var follow
    let suggestion: SpellingSuggestion

    var body: some View {
        Button { follow(suggestion) } label: {
            // One complete sentence with its placeholder, so a translation may put the word where its language does.
            Text("Look up “\(suggestion.word)”")
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // **On the button as well as its words**: a bordered button keeps one line however narrow it is offered, so its
        // words were cut rather than wrapped until the button itself was let grow down (measured 2026-10-11, 306 pt of
        // words held to 120 pt: 20 pt tall without this, 62 pt with it).
        .fixedSize(horizontal: false, vertical: true)
        // The name is the label; the hint says what pressing does, which the name alone does not — a new lookup, the
        // miss above it left as it is.
        .help(Text("Opens a new lookup."))
        .accessibilityHint(Text("Opens a new lookup."))
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
    /// **The reader pressed "Look up “X”"** — look the word up as a new lookup, filed by the panel under the card's own
    /// request.
    public var followSuggestion: @MainActor (SpellingSuggestion) -> Void {
        get { self[FollowSuggestionKey.self] }
        set { self[FollowSuggestionKey.self] = newValue }
    }
}
