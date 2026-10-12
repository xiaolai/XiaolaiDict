import DictionaryModel
import Foundation
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// **"Dictionaries…" on every card the reader can be shown** (plan-card-refinements WI-1).
///
/// The only way to Settings › Dictionary was "Choose Another Dictionary…", drawn where the entry marks no senses. The
/// compact card mounts no footer, a detailed miss mounts none, and prose mounts only Copy — so the way out was absent on
/// exactly the miss that asks for it. Decided as a value, so every state is a row of a table rather than a branch of a
/// view body nobody can ask.
struct CardExitsTests {
    private static func entries(_ names: [String]) -> LookupOutcome {
        .entries(NonEmpty(names.map { sampleEntry($0) })!, unreadable: [])
    }

    /// **The full outcome matrix**: one dictionary, several, none, prose, a service that could not be asked — each on
    /// the detailed card — and each of them again on the compact card, which has no footer of its own.
    @Test func everyCardStateOffersTheWayToTheDictionarySettings() {
        let detailed: [(LookupOutcome, CardExits.Footer, String)] = [
            (Self.entries(["New Oxford American Dictionary"]), .entry, "an entry from one dictionary"),
            (Self.entries(["New Oxford American Dictionary", "Oxford Thesaurus"]), .entry, "entries from several"),
            (.notFound(serviceFailure: nil), .miss, "a miss"),
            (.plainText("prose", serviceFailure: "crashed"), .prose, "the prose fallback"),
            (.notFound(serviceFailure: "crashed"), .miss, "a service that could not be asked"),
        ]
        for (outcome, footer, state) in detailed {
            #expect(CardExits.of(outcome, compact: false) == CardExits(footer: footer, dictionaries: .footer),
                    "detailed card, \(state)")
            // The compact card mounts no footer, so the exit is on the card itself.
            #expect(CardExits.of(outcome, compact: true) == CardExits(footer: .none, dictionaries: .compactCard),
                    "compact card, \(state)")
        }
    }

    /// **Nothing to leave while nothing has answered.** The waiting card is not a card about any dictionary.
    @Test func theWaitingCardOffersNothing() {
        for compact in [false, true] {
            #expect(CardExits.of(nil, compact: compact) == CardExits(footer: .none, dictionaries: .none))
        }
    }

    /// **The exit is wired to the setting, on both cards**, and the conditional "Choose Another Dictionary…" stays —
    /// read from the source, because a test process builds no accessibility tree and cannot press a SwiftUI button
    /// (`SpellingSuggestionLineTests`); the press is the `lookup` E2E stage's.
    @Test func bothCardsDrawTheExitTheDecisionNamesAndItOpensTheSetting() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: AppModules.repository.appending(path: path), encoding: .utf8)
        }
        let panel = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(panel.contains("CardExits.of(presentation.outcome, compact: isCompact)"), "the panel does not ask the decision")
        #expect(panel.contains("IconButton(.dictionarySettings, action: openDictionarySettings)"),
                "the footer's exit does not open the dictionary settings")
        #expect(panel.contains("Button(\"Choose Another Dictionary…\") { openDictionarySettings() }"),
                "the conditional exit changed")
        let compact = try source("Sources/XiaolaiDictUI/CompactLookupCardView.swift")
        #expect(compact.contains("IconButton(.dictionarySettings, action: openDictionarySettings)"),
                "the compact card's exit does not open the dictionary settings")
    }

    @Test func theExitIsNamedAsTheSettingsItOpens() {
        #expect(ActionSymbol.dictionarySettings.title.key == "Dictionaries…")
    }
}
