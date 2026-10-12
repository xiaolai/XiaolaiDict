import AppKit
import CaptureModel
import DictionaryModel
import Foundation
import SwiftUI
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **"Look up “X”" on the card** (plan-spelling-suggestion §3; the owner's ruling of 2026-10-11): one button, drawn only
/// under the service's own miss of the card's own term, on the compact card and the detailed one, in the same words for
/// every kind of evidence, handing the suggestion to the app — and the app's hook set where the panel's other hooks are.
///
/// Decided in the model where a rule can be asked (`LookupPresentation.offeredSuggestion`), and seen in a hosted card
/// by the height it adds and the control it puts in the accessibility tree: a grouped `Form` and glass cannot be
/// pixel-tested (AGENTS.md), and this card is neither.
@MainActor
struct SpellingSuggestionLineTests {
    private static let the = SpellingSuggestion(term: "teh", word: "the", evidence: .correction(.transposition))

    private static func presentation(_ outcome: LookupOutcome?, suggestion: SpellingSuggestion? = the,
                                     term: String = "teh") -> LookupPresentation {
        var presentation = LookupPresentation(
            request: 7, term: term, lemma: Lemma(text: term, basis: .surface), source: "TextEdit",
            capture: .accessibility(.accessibilityTextRange, context: .complete), sentence: "I saw \(term) cat.",
            outcome: outcome)
        presentation.suggestion = suggestion
        return presentation
    }

    private static var found: LookupOutcome {
        .entries(NonEmpty([sampleEntry("New Oxford American Dictionary")])!, unreadable: [])
    }

    // MARK: - The rule, in the model

    /// **Offered only under the service's own miss, and only for the card's own term.**
    @Test func theLineIsOfferedOnlyUnderTheServicesOwnMissOfThisTerm() {
        #expect(Self.presentation(.notFound(serviceFailure: nil)).offeredSuggestion == Self.the)
        // A miss the service could not answer already says so; a line under it would read as a confirmed absence.
        #expect(Self.presentation(.notFound(serviceFailure: "crashed")).offeredSuggestion == nil)
        #expect(Self.presentation(.plainText("prose", serviceFailure: "crashed")).offeredSuggestion == nil)
        #expect(Self.presentation(Self.found).offeredSuggestion == nil)
        // Still waiting: nothing is drawn while anything is being checked.
        #expect(Self.presentation(nil).offeredSuggestion == nil)
        // A suggestion made for another lookup is never drawn on this one.
        #expect(Self.presentation(.notFound(serviceFailure: nil), term: "thier").offeredSuggestion == nil)
        #expect(Self.presentation(.notFound(serviceFailure: nil), suggestion: nil).offeredSuggestion == nil)
    }

    // MARK: - The line, on both cards

    private func hosted(_ presentation: LookupPresentation, compact: Bool,
                        follow: @escaping @MainActor (SpellingSuggestion) -> Void = { _ in }) -> NSHostingView<some View> {
        let view = NSHostingView(rootView: LookupPanelContent(presentation: presentation)
            .environment(\.scale, Scale.standard)
            .environment(\.cardOptions, CardOptions(usesCompactLookup: compact))
            .environment(\.followSuggestion, follow))
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// **The line is a button whose press hands its own suggestion to the app** — read from the source, as
    /// `IconButtonTests` reads a tooltip, because no press can be made here: measured 2026-10-09, SwiftUI builds no
    /// accessibility tree in a test process (a hosted card exposes one empty group), puts no `NSButton` under a
    /// bordered button, and lets no mouse event reach its action in a window that is not on screen — and ordering one
    /// on screen would put a window in front of whoever is at the building Mac. The real press is the `lookup` E2E
    /// stage's: the panel's button pressed by its name, and the word's card read back.
    ///
    /// **Its words are "Look up “X”" for every kind of offer, its VoiceOver hint "Opens a new lookup."**, and nothing
    /// names the evidence: "Did you mean" and "A guess from the spelling" are gone (the owner's ruling of 2026-10-11).
    @Test func theLineIsAButtonThatHandsItsOwnSuggestionToTheApp() throws {
        let line = try String(contentsOf: AppModules.repository.appending(path: "Sources/XiaolaiDictUI/SpellingSuggestionLine.swift"),
                              encoding: .utf8)
        #expect(line.contains("Button { follow(suggestion) } label:"), "the line's press does not hand its suggestion over")
        #expect(line.contains("@Environment(\\.followSuggestion) private var follow"), "the line does not ask the app")
        #expect(line.contains("Text(\"Look up “\\(suggestion.word)”\")"), "the line does not say what it offers")
        #expect(line.contains(".accessibilityHint(Text(\"Opens a new lookup.\"))"), "VoiceOver is not told what a press does")
        // Read past the comments, which say why the old words went.
        let code = line.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for gone in ["Did you mean", "A guess from the spelling", "suggestion.evidence", "suggestion.term"] {
            #expect(!code.contains(gone), "the line still says or branches on \(gone)")
        }
    }

    /// **The card grows by the line, and only where the rule offers it** — on the compact card and the detailed one. A
    /// suggestion the rule refuses — under a service failure, under a found word, made for another term — leaves the
    /// card exactly the size it is without one.
    @Test(arguments: [false, true])
    func theLineIsDrawnOnlyWhereTheRuleOffersIt(compact: Bool) {
        func size(_ presentation: LookupPresentation) -> CGSize { hosted(presentation, compact: compact).fittingSize }
        let bare = size(Self.presentation(.notFound(serviceFailure: nil), suggestion: nil))
        let offered = size(Self.presentation(.notFound(serviceFailure: nil)))
        #expect(bare.height > 0, "the card laid out to nothing, so nothing below measures anything")
        #expect(offered.height > bare.height, "the line added no height: \(bare.height) then \(offered.height)")
        let refused: [(LookupOutcome, String)] = [
            (.notFound(serviceFailure: "crashed"), "teh"), (Self.found, "teh"), (.notFound(serviceFailure: nil), "thier"),
        ]
        for (outcome, term) in refused {
            #expect(size(Self.presentation(outcome, term: term)) == size(Self.presentation(outcome, suggestion: nil, term: term)),
                    "a refused suggestion changed the card: \(outcome) / \(term)")
        }
    }

    /// **Every kind of evidence draws the same button** — a printed form, a regular one, an agreement and the checker's
    /// correction of the same word make the same card, on both: nothing the reader sees says which it was.
    @Test(arguments: [false, true])
    func everyKindOfEvidenceDrawsTheSameButton(compact: Bool) {
        let kinds: [SpellingSuggestion.Evidence] = [.printed, .regular(.ed), .agreement(.s), .correction(.transposition)]
        let sizes = kinds.map { evidence in
            hosted(Self.presentation(.notFound(serviceFailure: nil),
                                     suggestion: SpellingSuggestion(term: "teh", word: "the", evidence: evidence)),
                   compact: compact).fittingSize
        }
        #expect(Set(sizes.map(\.height)).count == 1 && Set(sizes.map(\.width)).count == 1, "\(sizes)")
        let bare = hosted(Self.presentation(.notFound(serviceFailure: nil), suggestion: nil), compact: compact).fittingSize
        #expect(sizes[0].height > bare.height, "the button added no height: \(bare.height) then \(sizes[0].height)")
    }

    /// **The button's words wrap at a large text size rather than run past the card**: held to a width narrower than
    /// its words, it grows down.
    @Test func theButtonWrapsInANarrowWidth() {
        let long = SpellingSuggestion(term: "antidisestablishmentarianisms", word: "antidisestablishmentarianism",
                                      evidence: .printed)
        func size(width: CGFloat?) -> CGSize {
            let line = SpellingSuggestionLine(suggestion: long).environment(\.scale, Scale(TextSize.huge))
            let view = NSHostingView(rootView: line.frame(width: width))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize
        }
        let natural = size(width: nil)
        let narrow = size(width: natural.width / 2)
        #expect(narrow.height > natural.height, "the words did not wrap: \(natural) then \(narrow)")
    }

    // MARK: - The app's wire

    /// **The panel hands the press to the app under the card's own request, and the app sets the hook** — read from
    /// the source, as the phrase's Save is (`PhraseCollectWiringTests`): the card's request is the one the runner kept
    /// the suggestion under, and a press filed under another would follow nothing.
    @Test func thePanelForwardsThePressUnderTheCardsOwnRequest() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: AppModules.repository.appending(path: path), encoding: .utf8)
        }
        let panel = try source("Sources/XiaolaiDict/LookupPanel.swift")
        #expect(panel.contains(".environment(\\.followSuggestion)"), "the panel never hands the card a way to follow")
        #expect(panel.contains("follow(suggestion, request)"), "the press is not filed under the card's request")
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(app.contains("panel.onFollowSuggestion = "), "the app never sets the panel's hook")
        #expect(app.contains("runner.followUp("), "the app does not ask the runner what the press looks up")
        // **The follow-up is launched as a word in no position of the sentence** (audit, 2026-10-09), or the card and
        // the tagger look for it there and find another occurrence.
        #expect(app.contains("placement: .notInSentence"), "the follow-up is launched as though the word were in the sentence")
        // **And as a replacement in place** (audit of 2026-10-10), or a card the reader dragged aside jumps back to the
        // misspelling — what the controller does with such a ticket is `CardDragTests`'.
        #expect(app.contains("ticket: panel.newRequest(replacingInPlace: true)"),
                "the follow-up is placed afresh instead of replacing the card where the reader has it")
    }

    /// **The hook is set by the app itself**, not left for a test to wire: a press on a panel with no hook is a
    /// broken switch.
    @Test func theAppSetsThePanelsHook() {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite))
        #expect(app.panelController.onFollowSuggestion != nil, "a press on the line reaches nothing")
    }

    /// **A press the runner was not offered looks nothing up** — the app refuses it, loudly, rather than launching a
    /// lookup of a word nobody suggested.
    @Test func aPressOnALineTheRunnerNeverOfferedStartsNothing() {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite))
        app.panelController.onFollowSuggestion?(Self.the, 1)
        #expect(app.lookup == nil, "a lookup was started for a suggestion nobody was offered")
    }
}
