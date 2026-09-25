import DictionaryModel
import Foundation
import Testing

/// **What reached the panel, not what the panel could do.**
///
/// This project has recorded the same defect three times — a type that is complete, unit-tested and
/// connected to nothing, because the *wire* was the missing part and every test exercised the value.
/// `HoverPause` had three durations and a menu item nobody wrote; `LookupRunner` took a
/// `priorEncounters` reader and never called it; `Speech.caveat` was memoised and measured while no
/// call site asked for it. Each passed a green suite for months.
///
/// So the controls added for the lookup card are checked at their call sites. A source scan rather
/// than a rendered view because SwiftUI cannot be asked which arguments a view was built with, and a
/// test that rendered one would be asserting on pixels rather than on the wire.
struct PanelWiringTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The source with comment-only lines removed. These files explain themselves at length, and a
    /// scanner that cannot tell a declaration from an explanation is satisfied by the call site
    /// written out inside a comment — which is exactly how a rule comes to hold on paper and not in
    /// the view.
    private func source(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        #expect(!text.isEmpty, "\(relativePath) is empty")
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var cardView: String { (try? source("Sources/XiaolaiDictUI/LookupCardView.swift")) ?? "" }

    /// **The confirmation is handed to the card.** Without this the control is a parameter defaulting
    /// to nil that nothing supplies — the `HoverPause` shape exactly, and every test over
    /// `LookupCard` would still pass.
    @Test func thePanelHandsTheCardAWayToConfirm() throws {
        let source = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(source.contains("onConfirm: confirmable(entry)"),
                "the card is built without a confirmation, so the control can never appear")
    }

    /// **And it is offered only where it can act.** One function answers both "may this be offered?"
    /// and "what is written if it is", because two conditions that have to agree are the arrangement
    /// that produced every broken switch on this card.
    @Test func whatMayBeConfirmedIsWhatWouldBeRecorded() throws {
        let source = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(source.contains("private func confirmable(_ entry: DictionaryEntry) -> SenseEncounter?"),
                "the eligibility of the control and what it records are no longer one answer")
    }

    /// **Confirming clears no pane, and this is the check that keeps it that way.**
    ///
    /// The rule is easy to "fix" away: `choose` clears the panes, `confirm` sits beside it, and
    /// making them match looks like tidying. It is not — promoting a *different* sense makes
    /// everything said about the old one wrong, while agreeing with this one changes what the card
    /// claims and not what it says. A translation the reader asked for, taken away as the reward for
    /// agreeing, is the worst possible answer to the most valuable thing they can do here.
    ///
    /// Where a pane's question really did change — the ambiguous favourite, which neither pane was
    /// told — the pane is dropped by its own key. `ConfirmingASenseTests` is that half.
    @Test func confirmingDoesNotClearThePanes() throws {
        let source = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        let start = try #require(
            source.range(of: "private func confirm(_ encounter: SenseEncounter, in entry: DictionaryEntry) {"),
            "the confirmation is not where this check looks for it")
        let after = source[start.upperBound...]
        let end = try #require(after.range(of: "\n    }"), "the confirmation's body has no end")
        let body = after[..<end.lowerBound]
        #expect(!body.contains("clearPanes()"),
                "confirming the sense on screen throws away a translation the reader asked for")
        // The other half, and the reason this is not simply "call nothing": the pasteboard still
        // holds "(a guess — not confirmed)", so a standing checkmark would promise a clipboard the
        // reader does not have.
        #expect(body.contains("copied = false"),
                "the copy checkmark outlives the caveat that is on the pasteboard")
        // And it is recorded as the reader's, which is the entire point.
        #expect(body.contains("studySense(encounter)") && body.contains("selection.choose("),
                "confirming does not reach the ledger, or does not change what the card draws")
    }

    /// **A pane is drawn only beside the question it answers.** The explanation had no key at all, so
    /// an answer outlived its own question; the translation has had one since it was written.
    @Test func bothPanesAreDrawnAgainstTheirOwnQuestion() {
        #expect(cardView.contains("explanation.of == SentenceQuestion.reading("),
                "the sentence pane is drawn without checking what it was asked")
        #expect(cardView.contains("translation.of == translationKey(for: entry)"),
                "the translation pane is drawn without checking what it was asked")
    }

    /// **Translate is absent where translating could say nothing**, and the decision is read from the
    /// translator rather than recomputed — two copies of that condition would drift, and the drift is
    /// a control that lies about what is about to happen.
    @Test func translateIsHiddenWhereItCouldSayNothing() {
        #expect(cardView.contains("if !alreadyInTheReadersLanguage { translateButton }"),
                "the translate control is drawn for a sentence already in the reader's language")
        #expect(cardView.contains("translator.sourceLanguage(sentence)"),
                "the sentence's language is not read through the translator's own detector")
        // Off the layout path: `NLLanguageRecognizer` is the cost that forced `Speech.caveat` to
        // memoise at 43 ms a call, and a view body is evaluated many times per layout.
        #expect(cardView.contains(".task(id: presentation.sentence)"),
                "the language is detected from a view body rather than once per sentence")
    }

    /// **The route to the dictionary setting exists, and the app supplies it.** A default of `{}` is
    /// what a missing wire looks like here, and it would be a button that does nothing.
    @Test func theRouteToTheDictionarySettingIsSuppliedByTheApp() throws {
        #expect(cardView.contains("openDictionarySettings()"),
                "nothing on the card asks for the dictionary setting")
        let panel = try source("Sources/XiaolaiDict/LookupPanel.swift")
        #expect(panel.contains(".environment(\\.openDictionarySettings)"),
                "the panel is shown without a way to open the dictionary setting")
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(app.contains("panel.onOpenDictionarySettings ="),
                "the app never gives the panel controller its route to Settings")
    }

    /// **The window is asked to be as tall as the card.**
    ///
    /// This is the assertion the defect was invisible without. The view always reported its height
    /// correctly — `PanelHeightTests` measures 267 pt for a one-line answer and 405 for a long one —
    /// and the *window* took none of it: 398 × 240 for every card, measured three runs, with the
    /// dictionary control, translate, explain, copy and pin below a fold the panel gives no sign of
    /// having. Two comments in the source asserted the opposite, one of them on the very token that
    /// supplies the 240.
    ///
    /// A source scan because there is no window in a unit test to measure — and it is the *wire* that
    /// went missing here, not the arithmetic. `PanelFitTests` covers the arithmetic;
    /// `--panel-report` measures the real window on a real screen.
    @Test func theWindowIsFittedToTheCard() {
        // Matched up to the ceiling, not to the whole call: the measurement hook after it is an
        // argument this rule has no opinion about, and pinning the exact spelling made the scan fail
        // the moment one was added — a scan that breaks on its subject changing shape teaches people
        // to loosen it.
        #expect(cardView.contains(".fitsItsContent(upTo: scale.space.cardMaxHeight"),
                "nothing asks the panel's window to be the height of its content")
    }

    /// **And the fit is bounded by the same cap the scrolling region has.** Unbounded, the window
    /// would grow past the height its content is clipped to and hold empty space under the card.
    @Test func theFitStopsWhereTheScrollingStarts() {
        let capped = cardView.contains(".frame(maxHeight: scale.space.cardMaxHeight)")
        #expect(capped, "the scrolling region is no longer capped, so the fit's ceiling means nothing")
    }

    /// **And that route starts the discovery its destination depends on.** Nothing asks the
    /// dictionary service until a menu is opened, so a route that opens the pane directly could leave
    /// it reading "Asking the dictionary service…" for good.
    @Test func openingTheDictionaryPaneAsksWhichDictionariesThereAre() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let start = try #require(
            app.range(of: "func showSettings(on pane: SettingsPane? = nil) {"),
            "showSettings is not where this check looks for it")
        let after = app[start.upperBound...]
        let end = try #require(after.range(of: "\n    }"), "showSettings has no end")
        #expect(after[..<end.lowerBound].contains("askForDictionaries()"),
                "opening Settings on the Dictionary pane can leave it asking for ever")
    }
}
