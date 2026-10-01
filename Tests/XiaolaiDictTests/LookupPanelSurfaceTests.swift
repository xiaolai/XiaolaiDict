import AppKit
import DictionaryModel
import Foundation
import ModelKit
import SwiftUI
import Testing
import XiaolaiDictBase

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **Everything the lookup window shows is drawn on the card, because the window draws nothing.**
///
/// The window is borderless, clear and shadowless on purpose — the rounded card is the whole thing
/// the reader sees. Measured 2026-10-01 from screenshot pixels, two things in it were not on the
/// card at all: the "Nothing to look up" and Accessibility-permission messages (every non-text
/// pixel alpha 0), and the row that says whether the reading was saved, with the only Discard
/// control (near-white text over whatever app was behind, in dark mode). Their contrast was decided
/// by the wallpaper.
///
/// So these read **pixels**, from the hosted view, the way `PanelBottomPaddingTests` does: a
/// surface that is missing is transparent, and no model can say that.
@MainActor
struct LookupPanelSurfaceTests {
    private let scale = Scale.standard

    /// A hosted panel at the size it asks for, drawn into a bitmap.
    private struct Drawn {
        let size: CGSize
        let bitmap: NSBitmapImageRep

        /// The alpha at a point given in the view's own top-left coordinates.
        func alpha(x: CGFloat, fromTop y: CGFloat) -> CGFloat? {
            let perPoint = CGFloat(bitmap.pixelsHigh) / size.height
            return bitmap.colorAt(x: Int(x * perPoint), y: Int(y * perPoint))?.alphaComponent
        }

        /// The lowest row holding any dark ink, in points from the top.
        var lastInk: CGFloat? {
            let perPoint = CGFloat(bitmap.pixelsHigh) / size.height
            for y in stride(from: bitmap.pixelsHigh - 1, through: 0, by: -1) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                    if colour.alphaComponent > 0.5, colour.brightnessComponent < 0.72 {
                        return CGFloat(y) / perPoint
                    }
                }
            }
            return nil
        }
    }

    private func draw(_ view: some View, width: CGFloat? = nil) throws -> Drawn {
        let hosted = NSHostingView(
            rootView: view.environment(\.scale, scale).environment(\.colorScheme, .light))
        hosted.layoutSubtreeIfNeeded()
        var wanted = hosted.fittingSize
        if let width { wanted.width = width }
        hosted.frame = NSRect(origin: .zero, size: wanted)
        hosted.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        return Drawn(size: wanted, bitmap: bitmap)
    }

    private func lookup() -> LookupPresentation {
        var presentation = LookupPresentation(
            request: 1, term: "fine", lemma: Lemma(text: "fine", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil)
        presentation.sentence = "It was a fine piece of filmmaking."
        presentation.outcome = .entries(
            NonEmpty([sampleEntry("New Oxford American Dictionary")])!, unreadable: [])
        return presentation
    }

    /// Where the card's own padding is: inside the surface, clear of any glyph.
    private var insideTheCard: CGPoint {
        CGPoint(
            x: scale.shadow.glowBefore + scale.space.padAcross / 2,
            y: scale.shadow.glowBefore + scale.space.padDown / 2)
    }

    /// **The positive control**: a lookup's card is opaque where its padding is. Without this the
    /// two tests below could be reading a point that is transparent for every panel.
    @Test func aLookupIsDrawnOnAnOpaqueCard() throws {
        let drawn = try draw(PanelView(content: .lookup(lookup())))
        let alpha = try #require(drawn.alpha(x: insideTheCard.x, fromTop: insideTheCard.y))
        #expect(alpha > 0.95, "the lookup card is not opaque where it is sampled: \(alpha)")
    }

    /// **P1 — a message is on the same card.** It was two `Text`s on a transparent window.
    @Test func aMessageIsDrawnOnTheSameOpaqueCard() throws {
        for content in [PanelContent.frontmostAppUnknown, .accessibilityIsOff] {
            let drawn = try draw(PanelView(content: content), width: Token.Panel.messageWidth)
            let alpha = try #require(drawn.alpha(x: insideTheCard.x, fromTop: insideTheCard.y))
            #expect(alpha > 0.95, "a panel message has no surface behind it: alpha \(alpha)")
        }
    }

    /// **P2 — the row that says whether the reading was saved is inside the card.**
    ///
    /// Two halves. The view that draws the card grows when there is a status to show, so the row is
    /// the card's own and not something the window stacks under it; and the row's words sit on
    /// opaque paper, so the last ink in the panel has card beneath and beside it.
    @Test func theSavedStatusIsTheCardsOwnLastRow() throws {
        let plain = try draw(PanelView(content: .lookup(lookup())))
        let withStatus = try draw(
            PanelView(content: .lookup(lookup())).environment(\.lookupKeepStatus, .kept))
        #expect(
            withStatus.size.height > plain.size.height,
            "the card is no taller with a status than without — the row is not part of it")

        let ink = try #require(withStatus.lastInk, "the panel drew nothing")
        // Just under the status row's text, at the card's leading padding: still card.
        let alpha = try #require(withStatus.alpha(x: insideTheCard.x, fromTop: ink))
        #expect(alpha > 0.95, "the status row has no surface behind it: alpha \(alpha)")
        // And the row is the *last* thing: nothing but the card's own bottom edge and the margin
        // its shadow falls in lies under it.
        let under = withStatus.size.height - ink
        #expect(
            under <= scale.shadow.glowAfter + Token.Target.minimum,
            "\(under) pt lies under the status row — it is not the card's last row")
    }

    /// A sentence long enough that the card has to scroll.
    private func longLookup() -> LookupPresentation {
        var presentation = lookup()
        presentation.sentence = String(repeating: "It was a fine piece of filmmaking. ", count: 60)
        return presentation
    }

    /// **The status row comes out of the card's cap, not on top of it.**
    ///
    /// The cap is the card's: `PanelWindow.tallest`, which `--panel-report` holds the window to, is
    /// `cardMaxHeight` plus the chrome and nothing else. With the row inside the card and the
    /// whole cap still given to the scrolling region, a card long enough to scroll made the
    /// window taller than its own ceiling by the height of the row.
    ///
    /// The row's height is measured after the first layout, so the run loop turns once before the
    /// size is read — the same wait the window itself gets.
    @Test func aLongCardWithAStatusRowStaysWithinTheCap() throws {
        let hosted = NSHostingView(
            rootView: PanelView(content: .lookup(longLookup()))
                .environment(\.scale, scale)
                .environment(\.lookupKeepStatus, .needsConfirmation))
        hosted.layoutSubtreeIfNeeded()
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosted.layoutSubtreeIfNeeded()
        let height = hosted.fittingSize.height
        let ceiling = scale.space.cardMaxHeight + scale.shadow.glowBefore + scale.shadow.glowAfter
        #expect(height > scale.space.cardMaxHeight / 2, "the long card is not long, so this bounds nothing")
        #expect(height <= ceiling + 1, "a long card with a status row is \(height) pt against a cap of \(ceiling)")
        #expect(ceiling <= PanelWindow.tallest, "the card's cap and the report's ceiling have drifted apart")
    }

    /// **A discarded reading still says so on the card**, with its way back beside it.
    @Test func everyStatusDrawsARow() throws {
        let plain = try draw(PanelView(content: .lookup(lookup())))
        let statuses: [LookupKeepStatus] = [
            .keeping, .kept, .needsMeaning, .needsConfirmation, .manual, .failed, .discarded,
            .discardedExternally,
        ]
        for status in statuses {
            let drawn = try draw(
                PanelView(content: .lookup(lookup())).environment(\.lookupKeepStatus, status))
            #expect(drawn.size.height > plain.size.height, "\(status) draws no row on the card")
        }
    }
}

/// The wires the pixels cannot see: where the row is declared, and what the window still adds.
struct LookupPanelSurfaceWiringTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        #expect(!text.isEmpty, "\(relativePath) is empty")
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The window stacks nothing under the card.** The scene view built
    /// `VStack { PanelView; LookupKeepStatusViewBridge }`, which is how the row came to be outside
    /// a surface that belongs to `PanelView`.
    @Test func theWindowAddsNothingUnderTheCard() throws {
        let panel = try source("Sources/XiaolaiDict/LookupPanel.swift")
        #expect(panel.contains("PanelView(content: content)"), "the scene no longer shows the panel")
        #expect(!panel.contains("LookupKeepStatus"),
                "the app target draws the status row itself, outside the card's surface")
        // The status itself still has to reach the card.
        #expect(panel.contains(".environment(\\.lookupKeepStatus"),
                "nothing tells the card whether the reading was saved")
        #expect(panel.contains(".environment(\\.lookupKeepAction)"),
                "the status row's controls are wired to nothing")
    }

    /// **One wrapper draws the surface, for a message and a lookup alike**, and the status row is
    /// declared inside it — after the scrolling region, before the background.
    @Test func oneSurfaceHoldsTheScrollingContentAndThenTheStatusRow() throws {
        let views = try source("Sources/XiaolaiDictUI/LookupPanelViews.swift")
        let start = try #require(views.range(of: "struct PanelSurface<"), "there is no shared panel surface")
        let body = views[start.upperBound...]
        let scroll = try #require(body.range(of: "ScrollView {"), "the surface does not scroll its content")
        let bar = try #require(body.range(of: ".safeAreaBar(edge: .bottom"),
                               "the surface pins nothing under the scrolling content")
        let status = try #require(body.range(of: "LookupKeepStatusRow()"),
                                  "the status row is not on the surface")
        let fill = try #require(body.range(of: ".background(CardSurface.panel(for: scheme), in: shape)"),
                                "the surface has no fill")
        #expect(scroll.lowerBound < bar.lowerBound && bar.lowerBound < status.lowerBound,
                "the status row is not after the scrolling region and its pinned bar")
        #expect(status.lowerBound < fill.lowerBound,
                "the status row is declared after the fill, so it is drawn outside the card")
        // Both kinds of panel go through it.
        #expect(views.contains("PanelSurface(accent: nil"), "a message is not drawn on the surface")
        let card = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(card.contains("PanelSurface(accent: accent"), "a lookup is not drawn on the surface")
    }

    /// **P3 — the footer is pinned, not scrolled.** Last in the scrolled stack, the dictionary
    /// switcher and all five actions sat below a fold with no sign of being there.
    @Test func theFooterIsPinnedUnderTheScrollingContent() throws {
        let card = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        let content = try #require(card.range(of: "private var content: some View {"))
        let pinned = try #require(card.range(of: "private var pinnedFooter: some View {"),
                                  "the footer has no pinned home")
        let scrolled = card[content.upperBound..<pinned.lowerBound]
        #expect(!scrolled.contains("footer(entry)") && !scrolled.contains("proseFooter(card)"),
                "a footer is still inside the scrolling content")
        #expect(card[pinned.upperBound...].contains("footer(entry)"), "the pinned footer holds no actions")
    }
}

/// **P4 — the other senses are listed under the block each is numbered in.**
///
/// A dictionary restarts its numbering in every part-of-speech block. Drawn as one flat list,
/// *meet* in 牛津英汉汉英 read 1…8, 1, 3, 4, 1 (measured 2026-10-01): two rows were "1", two were
/// "3", and the 2 missing from the second run was the sense on screen.
struct SenseGroupingTests {
    private static func sense(_ block: Int, _ ordinal: Int, _ part: String?) -> SensePresentation {
        SensePresentation(
            key: "k.\(block).\(ordinal)", block: block, ordinal: ordinal, partOfSpeech: part,
            label: "sense \(block).\(ordinal)", keyKind: .publisher, standing: .unclaimed,
            metBefore: false)
    }

    private static func card(_ alternatives: [SensePresentation]) -> LookupCard {
        LookupCard(
            term: "meet", heading: "meet", partOfSpeech: "verb", pronunciation: nil,
            answer: .undecided(reason: nil), sentence: nil, alternatives: alternatives)
    }

    /// The reported case: three blocks, the second missing the sense the card leads with.
    @Test func eachBlockIsItsOwnGroupAndKeepsItsOwnNumbers() {
        let card = Self.card(
            (1...8).map { Self.sense(1, $0, "transitive verb") }
                + [1, 3, 4].map { Self.sense(2, $0, "intransitive verb") }
                + [Self.sense(3, 1, "noun")])
        let groups = card.alternativeGroups
        #expect(groups.map(\.partOfSpeech) == ["transitive verb", "intransitive verb", "noun"])
        #expect(groups.map { $0.senses.map(\.ordinal) } == [Array(1...8), [1, 3, 4], [1]])
        #expect(card.namesAlternativeGroups, "three blocks are drawn without saying which is which")
        // Nothing is lost or repeated by the grouping.
        #expect(groups.flatMap(\.senses) == card.alternatives)
    }

    /// **Within a group an ordinal names one sense**, which is the property the flat list lacked.
    @Test func noGroupHoldsAnOrdinalTwice() {
        let card = Self.card(
            (1...8).map { Self.sense(1, $0, "verb") } + [1, 3, 4].map { Self.sense(2, $0, "verb") })
        for group in card.alternativeGroups {
            let ordinals = group.senses.map(\.ordinal)
            #expect(Set(ordinals).count == ordinals.count, "\(ordinals) repeats inside one group")
        }
        // The positive control: flat, the same senses do repeat.
        let flat = card.alternatives.map(\.ordinal)
        #expect(Set(flat).count < flat.count, "the fixture has no restart, so it tests nothing")
    }

    /// **By block, never by the label.** Two blocks under one part of speech are two runs of
    /// numbers, and merging them on the label would put two "1"s back under one header.
    @Test func twoBlocksWithOnePartOfSpeechStayApart() {
        let card = Self.card([Self.sense(1, 1, "noun"), Self.sense(1, 2, "noun"), Self.sense(2, 1, "noun")])
        #expect(card.alternativeGroups.map(\.block) == [1, 2])
        #expect(card.alternativeGroups.map { $0.senses.count } == [2, 1])
    }

    /// One block is not named: the heading already prints its part of speech.
    @Test func aSingleBlockIsNotGivenAHeader() {
        let card = Self.card((1...3).map { Self.sense(1, $0, "noun") })
        #expect(card.alternativeGroups.count == 1)
        #expect(!card.namesAlternativeGroups)
        #expect(Self.card([]).alternativeGroups.isEmpty)
    }

    /// **The wire**: the block reaches the presentation from the parsed entry, and the view draws
    /// the groups rather than the flat list.
    @Test func theBlockComesFromTheEntryAndTheViewDrawsTheGroups() throws {
        let entry = sampleEntry("New Oxford American Dictionary")
        let presentation = EntryPresentation(entry: entry, mark: nil, met: [])
        // The sample has an adjective block of three senses and an adverb block of one.
        #expect(presentation.senses.map(\.block) == [1, 1, 1, 2])
        let card = LookupCard(presentation: presentation, term: "fine", sentence: nil, mark: nil)
        #expect(card.alternativeGroups.map { $0.senses.map(\.ordinal) } == [[1, 2, 3], [1]])

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appending(path: "Sources/XiaolaiDictUI/LookupCardView.swift"), encoding: .utf8)
        #expect(view.contains("ForEach(card.alternativeGroups)"), "the card does not draw the groups")
        #expect(!view.contains("ForEach(card.alternatives)"), "the card still draws the flat list")
    }
}

/// **What the status row says, in the words the rest of the app uses.**
struct LookupKeepStatusTextTests {
    /// Every status has a sentence, and none of them is an instruction or an old word. The row
    /// read "Kept · Confirm this meaning in Library" and "History kept · Choose Keep for learning
    /// to study": the reader pressed *Keep* and looked for the result under *Saved*.
    @Test func everyStatusIsSaidInTheSharedVocabulary() {
        for status in LookupKeepStatus.allCases {
            let sentence = String(localized: status.sentence)
            #expect(!sentence.isEmpty, "\(status) says nothing")
            for retired in ["Kept", "kept", "Keep", "lookup", "learning", "Choose", "Confirm this", "·", "—"] {
                #expect(!sentence.contains(retired), "\(status) still says “\(retired)”: \(sentence)")
            }
        }
        #expect(String(localized: LookupKeepStatus.kept.sentence) == "Saved")
        #expect(String(localized: LookupKeepStatus.discarded.sentence) == "Discarded")
    }

    /// **One word for undoing a discard.** *Undo* and *Restore* named the same action in two
    /// states; both states now answer to the one test, and the row offers the one control.
    @Test func bothDiscardedStatesAreUndoneTheSameWay() throws {
        #expect(LookupKeepStatus.discarded.isDiscarded)
        #expect(LookupKeepStatus.discardedExternally.isDiscarded)
        for status in LookupKeepStatus.allCases where status != .discarded && status != .discardedExternally {
            #expect(!status.isDiscarded, "\(status) is offered Restore with nothing discarded")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let row = try String(
            contentsOf: root.appending(path: "Sources/XiaolaiDictUI/LookupKeepStatus.swift"), encoding: .utf8)
        #expect(row.contains("IconButton(.restoreReading"), "a discarded reading has no way back")
        #expect(row.contains("IconButton(.discardReading"), "a reading cannot be discarded from the card")
        #expect(row.contains("IconButton(.retry"), "a failed save cannot be tried again")
        #expect(!row.contains("IconButton(.undo"), "undoing a discard has two names again")
        // Icon buttons, not worded push buttons at a forced micro size.
        #expect(!row.contains("Button(\""), "the status row has a worded push button again")
    }
}

/// **A model's answer says a model wrote it** (P16), and can be copied and asked for again (P6).
struct ModelPaneLabelTests {
    private static let key = TranslationPane.Key(sentence: "s", target: "zh-Hans", dictionary: "NOAD", sense: nil)

    /// Every translation carries one line saying who wrote it: Apple's has its caveat, the local
    /// model's had nothing at all.
    @Test func everyTranslationSaysWhoWroteIt() throws {
        let model = TranslationPane(.translated("货舱", by: .localModel), of: Self.key)
        #expect(model.caveat == nil, "the weaker-engine caveat is on the model's answer")
        let label = try #require(model.provenance, "the local model's translation is unlabelled")
        #expect(label.contains("local model") && label.contains("may be wrong"))

        let apple = TranslationPane(.translated("货舱", by: .appleTranslation), of: Self.key)
        #expect(apple.provenance == apple.caveat, "Apple's answer lost its own label")
        #expect(apple.attribution == nil, "Apple's answer is labelled twice")
    }

    /// And nothing that is not a translation claims to be one.
    @Test func onlyATranslationIsLabelledOrCopied() {
        for outcome in [TranslationOutcome.needsLanguagePack(source: "en", target: "zh-Hans"),
                        .sameLanguage, .unavailable] {
            let pane = TranslationPane(outcome, of: Self.key)
            #expect(pane.provenance == nil, "\(outcome) is labelled as a model's answer")
            #expect(pane.translatedText == nil, "\(outcome) offers text to copy")
        }
        #expect(TranslationPane(.translated("货舱", by: .localModel), of: Self.key).translatedText == "货舱")
    }

    /// Both tiers of the explanation are labelled, and the two labels differ — the tier is a
    /// licence boundary, and one label for both would say a sentence stayed on this Mac while it
    /// was being sent away.
    @MainActor @Test func bothExplanationTiersAreLabelledAndToldApart() {
        var seen: [Text] = []
        for tier in ExplainerTier.allCases {
            let label = SentencePaneView.provenance(tier)
            #expect(!seen.contains(label), "\(tier) shares its label with another tier")
            seen.append(label)
        }
        #expect(seen.count == ExplainerTier.allCases.count)
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The wires.** A pane with a retry nobody supplies, or a waiting state nothing draws, is
    /// the complete-and-unreachable shape this project has recorded three times.
    @Test func bothPanesCanBeCopiedRetriedAndSeenWaiting() throws {
        let card = try source("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(card.contains("TranslationPaneView(pane: translation, retry: translate)"))
        #expect(card.contains("SentencePaneView(explanation: explanation.answer, retry: explain)"))
        #expect(card.contains("ModelWaitingPane(message: Text(\"Translating this sentence…\"))"))
        #expect(card.contains("ModelWaitingPane(message: Text(\"Explaining this sentence…\"))"))
        // The running state is a spinner; `ellipsis` is the platform's More.
        #expect(!card.contains("\"ellipsis\""), "a running action is drawn as the More symbol again")
        #expect(card.contains("ProgressView()"), "a running action shows no progress")

        let views = try source("Sources/XiaolaiDictUI/LookupPanelViews.swift")
        #expect(views.contains("if let copyable { CopyTextButton(text: copyable) }"),
                "a model's answer cannot be copied")
        #expect(views.contains("IconButton(.retry"), "a model's answer cannot be asked for again")
        let translation = try source("Sources/XiaolaiDictUI/TranslationPane.swift")
        #expect(translation.contains("copyable: pane.translatedText, retry: retry"),
                "the translation pane's footer is not given its text or its retry")
        // **Dead, and gone.** The window cannot become key, so the modifier did nothing here.
        #expect(!views.contains(".textSelection(") && !translation.contains(".textSelection("),
                "a pane in the non-key panel asks for text selection it cannot have")
    }
}

/// **The sweeps, held in place by reading the source** — each of these was a defect with no
/// symptom a model could report: a colour, a style, a symbol name.
struct LookupSurfaceSweepTests {
    private static let files = [
        "Sources/XiaolaiDictUI/LookupCardView.swift", "Sources/XiaolaiDictUI/LookupPanelViews.swift",
        "Sources/XiaolaiDictUI/LookupKeepStatus.swift", "Sources/XiaolaiDictUI/TranslationPane.swift",
        "Sources/XiaolaiDictUI/PinnedNote.swift", "Sources/XiaolaiDictUI/PhraseNotice.swift",
        "Sources/XiaolaiDictUI/CardOptions.swift", "Sources/XiaolaiDictUI/MarkedSentence.swift",
        "Sources/XiaolaiDictUI/SentenceWindowText.swift",
    ]

    /// Code only: comments here quote the old spellings on purpose, and previews are not shipped.
    private func code(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var text = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        #expect(!text.isEmpty, "\(relativePath) is empty")
        if let previews = text.range(of: "// MARK: - Previews") { text = String(text[..<previews.lowerBound]) }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String) throws -> [String] {
        try Self.files.filter { try code($0).contains(needle) }
    }

    /// The scan reads what it claims to: nine files, and a spelling known to be in them.
    @Test func theScanSeesTheFiles() throws {
        #expect(Self.files.count == 9)
        #expect(try occurrences(of: "scale.").count >= 6, "the scan found almost nothing to read")
    }

    @Test func noStatusIsSaidInOrangeText() throws {
        #expect(try occurrences(of: ".orange").isEmpty, "orange text is back on the lookup surface")
        #expect(try occurrences(of: "Color.orange").isEmpty)
    }

    @Test func noGlassButtonSitsOnTheCard() throws {
        #expect(try occurrences(of: ".buttonStyle(.glass").isEmpty, "a glass button is in the card's content")
    }

    /// Tertiary is the disabled look and nothing else: three footer controls, each switching to it
    /// only while it cannot be pressed.
    @Test func tertiaryMeansOnlyDisabled() throws {
        for file in Self.files {
            let lines = try code(file).split(separator: "\n").filter { $0.contains(".tertiary") }
            for line in lines {
                #expect(line.contains("== nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)"),
                        "\(file) draws readable content in tertiary: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Every animation on this surface goes through the one place that answers Reduce Motion.
    @Test func everyAnimationConsultsTheMotionPreference() throws {
        for file in Self.files {
            let text = try code(file)
            for line in text.split(separator: "\n") where line.contains("withAnimation(") {
                #expect(line.contains("withAnimation(disclosure)"),
                        "\(file) animates without asking about Reduce Motion: \(line.trimmingCharacters(in: .whitespaces))")
            }
            let bare = text.split(separator: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".animation(") }
            #expect(bare.isEmpty, "\(file) uses a bare .animation modifier: \(bare)")
            if text.contains("private var disclosure: Animation") {
                #expect(text.contains("MotionPreference.animation("), "\(file) has a disclosure animation of its own")
            }
        }
    }

    /// An action's symbol is written once, in `ActionSymbol`. What is left here is not an action:
    /// the disclosure triangle and the radio mark, each named in one view.
    @Test func noActionSymbolIsSpelledOnThisSurface() throws {
        let allowed = ["\"chevron.down\"", "\"chevron.right\"", "\"largecircle.fill.circle\"", "\"circle\""]
        for file in Self.files {
            let text = try code(file)
            var rest = text[...]
            while let found = rest.range(of: "systemName: ") {
                let after = rest[found.upperBound...]
                let line = after.prefix { $0 != "\n" }
                let spelled = allowed.contains { line.contains($0) }
                #expect(spelled || !line.contains("\""),
                        "\(file) spells a symbol name: \(line)")
                rest = after
            }
            #expect(!text.contains("symbol: \""), "\(file) passes a symbol name as a string")
            #expect(!text.contains("systemImage: \""), "\(file) passes a symbol name as a string")
        }
    }

    /// **X22** — the chosen dictionary row says so to VoiceOver, not only to the eye.
    @Test func theChosenDictionaryRowCarriesTheSelectedTrait() throws {
        let card = try code("Sources/XiaolaiDictUI/LookupCardView.swift")
        #expect(card.contains(".accessibilityAddTraits(isShown ? .isSelected : [])"))
    }

    /// **P7 / X15** — the note's unpin control exists whether or not a pointer is over it.
    @Test func aPinnedNoteCanBePutAwayWithoutAPointer() throws {
        let note = try code("Sources/XiaolaiDictUI/PinnedNote.swift")
        #expect(!note.contains("if pointerIsOver"),
                "the unpin button is only in the tree under a pointer, so VoiceOver cannot reach it")
        #expect(note.contains(".opacity(pointerIsOver || unpinIsFocused ? 1 : 0)"),
                "the unpin button is not faded by opacity")
        #expect(note.contains("IconButton(.unpinNote, shortcut: KeyboardShortcut(\"w\", modifiers: .command)"),
                "Command-W does not close a note")
        #expect(note.contains(".keyboardShortcut(.cancelAction)"), "Escape does not close a note")
        #expect(note.contains(".contextMenu {"), "the note has no context menu")
        // And it follows the reader's text size: no semantic font is left in the note.
        for semantic in [".font(.title", ".font(.body", ".font(.caption", ".font(.callout", ".font(.headline"] {
            #expect(try occurrences(of: semantic).isEmpty, "a semantic font ignores the reader's size: \(semantic)")
        }
    }

    /// **P18** — the panel can be pushed aside. It is placed beside the pointer, which is beside
    /// the word, and with style mask 0 there was no way to move it off the sentence being read.
    @Test func thePanelCanBeMoved() throws {
        let panel = try code("Sources/XiaolaiDict/LookupPanel.swift")
        #expect(panel.contains("window.isMovableByWindowBackground = true"), "the panel cannot be moved")
    }
}
