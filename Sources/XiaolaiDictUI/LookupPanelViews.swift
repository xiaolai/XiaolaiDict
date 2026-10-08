
import DictionaryModel
import ModelKit
import XiaolaiDictBase
import XiaolaiDictCore
import SwiftUI

public struct PanelView: View {
    @Environment(\.scale) private var scale
    public let content: PanelContent

    public init(content: PanelContent) {
        self.content = content
    }

    public var body: some View {
        switch content {
        case .message(let title, let detail):
            // **On the card, like everything else the window shows.** This was two `Text`s with
            // padding and no background, in a window that is clear on purpose: measured
            // 2026-10-01, every non-text pixel of the "Nothing to look up" panel was alpha 0, so
            // the Accessibility-permission message was black text over whatever was behind it.
            //
            // It sizes to what it says, too. The window opens at `Token.Panel.messageHeight` and
            // stayed there, half empty for two lines; the surface's fit now moves it.
            PanelSurface(accent: nil) {
                // Both arrive localized — `detail` is sometimes the reason a reader was given for a
                // selection that could not be read — so neither is looked up a second time here.
                VStack(alignment: .leading, spacing: scale.space.stack) {
                    Text(verbatim: title)
                        .font(.system(size: scale.text.heading, weight: .semibold))
                    // Primary, not secondary: this sentence is the whole message, and one of the
                    // two it can be is the instruction for granting a permission.
                    Text(verbatim: detail)
                        .font(.system(size: scale.text.body))
                        .lineSpacing(scale.text.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(scale.space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } bar: {
                EmptyView()
            }
        case .lookup(let presentation):
            LookupPanelContent(presentation: presentation, waiting: content.waitingDescription)
                .id(presentation.request)
        case .translation(let request, let text):
            SentenceTranslationView(text: text).id(request)
        }
    }
}

/// A direct translation of the selected passage, through the same engine and attribution used by
/// the dictionary card. It creates no dictionary lookup or study-history entry.
private struct SentenceTranslationView: View {
    @Environment(\.scale) private var scale
    @Environment(\.translation) private var actions
    let text: String
    @State private var pane: TranslationPane?
    @State private var retryCount = 0

    var body: some View {
        PanelSurface(accent: nil) {
            VStack(alignment: .leading, spacing: scale.space.stack) {
                Text(verbatim: text)
                    .font(.system(size: scale.text.body))
                    .textSelection(.enabled)
                if let pane {
                    TranslationPaneView(pane: pane, retry: { retryCount += 1 })
                } else {
                    ProgressView(String(localized: "Translating selection…",
                                        comment: "Direct selection translation while the engine is working"))
                }
            }
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        } bar: {
            EmptyView()
        }
        .task(id: retryCount) {
            pane = nil
            let target = actions.target
            let outcome = await actions.translate(TranslationQuestion(sentence: text, target: target, met: nil))
            guard !Task.isCancelled else { return }
            pane = TranslationPane(outcome, of: .init(sentence: text, target: target, dictionary: "", sense: nil))
        }
    }
}

/// **The lookup window's one surface: the paper, its edge, its lift, and what is pinned to it.**
///
/// The window is borderless and clear, so whatever is not drawn here is drawn on nothing. That was
/// true of two things (measured 2026-10-01): the panel's messages, which had no fill at all, and
/// the row saying whether the reading was saved, which the scene stacked *under* the card. Both
/// took their contrast from the app behind. One wrapper, so a third thing cannot be added outside
/// it without the compiler being asked where it goes.
///
/// Top to bottom it holds:
///
/// 1. **What scrolls**, bounded by `cardMaxHeight` — a sense list is unbounded (49 for *hold* in
///    the bilingual Oxford, 73 for *run* in NOAD) and the window follows its content, so without
///    the bound it grew off the display.
/// 2. **The bar**, pinned under it with `safeAreaBar`. The card's actions were the last thing in
///    the scrolled stack, so with a long list open they sat below a fold the card gave no sign of
///    having. The system's scroll-edge effect is the sign.
/// 3. **The status row**, outside the scrolling region altogether.
///
/// `.scrollBounceBehavior(.basedOnSize)` so a short panel does not rubber-band: a two-line answer
/// is not a scrollable thing and must not behave like one.
struct PanelSurface<Scrolling: View, Bar: View>: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.reportPanelFit) private var reportPanelFit
    /// The word's own colour, which the card's second shadow is thrown in. Nil for a message,
    /// which is about no word.
    let accent: Color?
    /// Whether this is the compact preview: the quick card's own, shorter measure and rounder corner. The
    /// expanded card and every message use the reading card's.
    let compact: Bool
    private let scrolling: Scrolling
    private let bar: Bar
    /// How tall the status row is drawn, so the scrolling region can give that much up.
    @State private var statusHeight: CGFloat = 0
    /// How tall the pinned bar is drawn, which the window fit has to be told — see `contentCap`.
    @State private var barHeight: CGFloat = 0

    init(accent: Color?, compact: Bool = false, @ViewBuilder scrolling: () -> Scrolling, @ViewBuilder bar: () -> Bar) {
        self.accent = accent
        self.compact = compact
        self.scrolling = scrolling()
        self.bar = bar()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                scrolling
            }
            .scrollBounceBehavior(.basedOnSize)
            // A long list says it is one: the indicator shows itself once as the content arrives,
            // whatever the reader's scroll-bar setting.
            .scrollIndicatorsFlash(onAppear: true)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // In a stack so that an empty bar still reports a height — of nothing.
                //
                // **No background here.** `EmptyView().background(fill)` is not nothing: measured
                // 2026-10-02, it drew the fill over the whole scroll view, so a message panel came
                // out as a blank card — the defect this surface exists to prevent, by another
                // road. A bar that needs paper under it brings its own (`pinnedToTheCard`).
                VStack(spacing: 0) { bar }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            // A hard edge, not a soft one: the list under the bar is dense text, and macOS draws a
            // dividing line there only while something is scrolled beneath it.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // **After the width frame, and `fixedSize` no longer fixes the height.** Measured: with
            // `.fixedSize(vertical: true)` in the chain the panel took its natural height and the
            // cap did nothing — `noPanelIsTallerThanTheCap` failed against a 1,200-point panel.
            // Fixing a size vertically is the opposite of letting a scroll view bound it.
            // **A floor as well as a cap**, because the window's fit answers nothing for a scroll
            // view given no height, and with the bar pinned outside it that is how this one
            // opened: the bars and a zero-height list (E2E Mac, 2026-10-02 — a 113-point window
            // with the footer and none of the entry).
            // **Above the bar, not from zero**: the frame holds the bar too and the fit reads the
            // container, which excludes it. A floor of 28 under a 44-point bar was still a
            // container of nothing — the same E2E Mac, the same day, a 98-point window.
            .frame(minHeight: scrollFloor, maxHeight: scrollCap)
            // **And the window is as tall as that.** The cap bounds the scrolling region; nothing
            // made the *window* take the height the content asked for, so it stayed at the opening
            // default — measured 398 × 240 for every card, three runs. `LookupPanelController.show`
            // writes the frame by hand, and a frame set by hand is not one SwiftUI revisits.
            //
            // Bounded by the same cap, so growing stops exactly where scrolling starts: a taller
            // window would hold empty space under the content.
            .fitsItsContent(upTo: contentCap, report: reportPanelFit)
            VStack(spacing: 0) {
                LookupKeepStatusRow()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
        }
        .frame(
            minWidth: compact ? scale.space.lookupMinWidth : scale.space.cardMinWidth,
            idealWidth: compact ? scale.space.lookupWidth : scale.space.cardWidth,
            maxWidth: compact ? scale.space.lookupWidth : scale.space.cardMaxWidth,
            alignment: .leading)
        // **The card is the window.** Its scene is `.plain`, which draws no background at all, so
        // the surface, the edge and the lift are the card's own — and they live here, in the
        // layer that has the tokens, rather than as literals in the scene that hosts it.
        .background(CardSurface.panel(for: scheme), in: shape)
        // Through `CardSurface`, so the hairline becomes a line when the reader has asked the
        // system for more contrast. At 12% of the label colour it was a hint either way.
        .overlay(shape.strokeBorder(
            CardSurface.neutralBorder(contrast: contrast), lineWidth: Token.Stroke.hairline))
        .clipShape(shape)
        // Depth first, then colour. The neutral shadow is what actually lifts the card off the
        // desktop; the accent one is the word's colour thrown under it, and on its own it would
        // either stain the wallpaper or do nothing.
        .shadow(
            color: .black.opacity(Token.Opacity.cardLift),
            radius: scale.shadow.panelRadius,
            x: scale.shadow.panelOffset, y: scale.shadow.panelOffset)
        .modifier(AccentGlow(accent: accent))
        // Asymmetric, because the shadows are. Uniform padding would leave dead space above and
        // to the left of a window that is exactly the size of its content.
        .padding(.top, scale.shadow.glowBefore)
        .padding(.leading, scale.shadow.glowBefore)
        .padding(.bottom, scale.shadow.glowAfter)
        .padding(.trailing, scale.shadow.glowAfter)
    }

    /// **How tall the scrolling region may grow: the card's cap, less the row pinned under it.**
    ///
    /// The cap is the *card's* — `PanelWindow.tallest`, which `--panel-report` holds the window to,
    /// is this plus the chrome and nothing else. With the status row inside the card and the whole
    /// cap still given to the scrolling region, a long sense list made the window taller than its
    /// own ceiling by the height of that row. The row is measured rather than assumed because it
    /// is 0 until the reading has been recorded and its controls set its height after that.
    private var scrollCap: CGFloat {
        max(0, scale.space.cardMaxHeight - statusHeight)
    }

    /// The least the scrolling region is laid out at: the pinned bar, and room above it for the
    /// fit to read as a container.
    private var scrollFloor: CGFloat {
        barHeight + scale.space.panelScrollFloor
    }

    /// **Where the window stops growing, in the fit's own terms: the room left for content.**
    ///
    /// The fit compares what the content wants with the scroll view's *container*, and a
    /// container excludes whatever a safe-area bar covers — measured 2026-10-02: a 200-point
    /// scroll view under a 40-point `safeAreaBar` reports a container of 160. So the ceiling it
    /// is given has to exclude the bar too. Handed `scrollCap` — the frame's bound, bar included
    /// — a long list asked for one bar's height more than the frame can give, for ever, and the
    /// window grew by that much past the card.
    private var contentCap: CGFloat {
        max(0, scrollCap - barHeight)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? scale.radius.lookup : scale.radius.panel, style: .continuous)
    }
}

/// The word's colour thrown under its card — and **no modifier at all** where there is no word.
///
/// Not a clear shadow: drawn into a bitmap, a surface with `.shadow(color: .clear, …)` came out
/// with its fill and none of its text (measured 2026-10-02, the message panel, light appearance),
/// which is the same blank card the surface exists to prevent. A message has no accent, so it has
/// no second shadow.
private struct AccentGlow: ViewModifier {
    @Environment(\.scale) private var scale
    let accent: Color?

    func body(content: Content) -> some View {
        if let accent {
            content.shadow(
                color: accent.opacity(Token.Opacity.accentShadow),
                radius: scale.shadow.glowRadius,
                x: scale.shadow.glowOffset, y: scale.shadow.glowOffset)
        } else {
            content
        }
    }
}

extension View {
    /// **Paper under a pinned bar**, so the list scrolling beneath it cannot show through its
    /// controls. The system's edge effect softens the boundary; it is not what keeps a row of
    /// icons legible over a line of text. Applied by the bar itself, never by `PanelSurface` —
    /// which cannot tell an empty bar from a full one.
    func pinnedToTheCard(in scheme: ColorScheme) -> some View {
        background(CardSurface.panel(for: scheme))
    }
}

/// Waiting for the dictionaries, saying so. Never a blank pane: the invariant that a failure must
/// not render as confidently as a success applies just as much to a result that has not arrived.
struct WaitingView: View {
    @Environment(\.scale) private var scale
    public let detail: String?

    public var body: some View {
        HStack(spacing: scale.space.column) {
            ProgressView().controlSize(.small)
            Text(verbatim: detail ?? String(localized: "Looking up…",
                                            comment: "Shown while a lookup is still being made"))
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A result that is less than it looks must say so, in the result.
///
/// **`text` is a `Text`, not a `String`, and that is the whole repair** — the same one
/// `LookupCardView.action(_:help:)` already carries. `Label(someString, …)` takes the verbatim
/// overload, so a caller that interpolated its message handed this English in a translated build
/// and the sentence never reached the catalog at all.
///
/// **A mark and ordinary text, not orange text.** The sentence was set in system orange on an
/// orange wash, which measured about 2.0:1 on the light card (2026-10-01) — the caveat was the
/// hardest thing on the card to read. `StatusLabel` carries the kind in a symbol and leaves the
/// words in the label colour; the wash stays, as the thing that says *this is a note about the
/// answer and not the answer*.
public struct Notice: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    public let text: Text

    public init(text: Text) {
        self.text = text
    }

    public var body: some View {
        StatusLabel(.caution, text: text, size: scale.text.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.column)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StatusPalette.caution.color(in: scheme, contrast: contrast)
                    .opacity(Token.Opacity.caveatWash))
    }
}

/// **The tinted block a model's answer is drawn in**, so the explanation and the translation are
/// one kind of thing on the card and visibly not the dictionary's text.
struct ModelPane<Content: View>: View {
    @Environment(\.scale) private var scale
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            content
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.vertical, scale.space.column)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(Token.Opacity.senseWash))
    }
}

/// **Under a model's answer: who wrote it, and the two things to do with it.**
///
/// Who wrote it, because a generated paragraph under a dictionary definition, in the same card,
/// reads as the publisher's (2026-10-01: the explanation's only label was "on this Mac" in
/// tertiary, the local model's translation had none). Copy, because nothing on this card can be
/// selected — the window cannot become key, and `textSelection` needs a key window, so the
/// modifier both panes carried did nothing. Retry, because asking again meant finding the same
/// footer icon a second time.
struct ModelPaneFooter: View {
    @Environment(\.scale) private var scale
    /// Nil where the pane holds no generated text — a missing language pair, a refusal.
    let provenance: Text?
    /// What Copy takes. Nil where there is nothing to take, and then there is no Copy.
    let copyable: String?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: scale.space.inline) {
            if let provenance {
                provenance
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Group {
                if let copyable { CopyTextButton(text: copyable) }
                IconButton(.retry, size: scale.text.small, action: retry)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Copies one string, and shows that it has. The checkmark is the *symbol* and never the name:
/// what was copied is a state, and VoiceOver needs the control's name.
struct CopyTextButton: View {
    @Environment(\.scale) private var scale
    let text: String
    @State private var copied = false

    var body: some View {
        IconButton(
            title: "Copy", symbol: (copied ? ActionSymbol.done : ActionSymbol.copy).symbol,
            size: scale.text.small
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        // The checkmark is about what is on the pasteboard, and a new answer is not on it.
        .onChange(of: text) { copied = false }
    }
}

/// **A model is working, and on what.** Waiting was an icon in the footer changing to an
/// ellipsis — Apple's symbol for *More* — in a row that could be scrolled out of sight. This is
/// where the answer will be, saying which answer.
struct ModelWaitingPane: View {
    @Environment(\.scale) private var scale
    let message: Text

    var body: some View {
        ModelPane {
            HStack(spacing: scale.space.inline) {
                ProgressView().controlSize(.small)
                message
                    .font(.system(size: scale.text.body))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the on-device model made of the reader's sentence — or why it could not. Never a blank
/// pane: a model that declined says so.
struct SentencePaneView: View {
    @Environment(\.scale) private var scale
    public let explanation: SentenceExplanation
    /// Asks again, with the same question.
    let retry: () -> Void

    public var body: some View {
        ModelPane {
            switch explanation {
            case .explained(let text, let tier):
                // At the card's own sizes. The reader's chosen text size reached the definition
                // and stopped short of its explanation, which was set in the system's `.callout`.
                Text(text)
                    .font(.system(size: scale.text.body))
                    .lineSpacing(scale.text.leading)
                    .fixedSize(horizontal: false, vertical: true)
                ModelPaneFooter(provenance: Self.provenance(tier), copyable: text, retry: retry)
            case .unavailable(let why):
                // `why` is already a localised sentence from the model layer, so it is shown
                // verbatim rather than re-keyed — which is what `Text(verbatim:)` says out loud.
                StatusLabel(.caution, text: Text(verbatim: why), size: scale.text.body)
                    .fixedSize(horizontal: false, vertical: true)
                ModelPaneFooter(provenance: nil, copyable: nil, retry: retry)
            }
        }
    }

    /// Who explained it, where, and that it may be wrong.
    ///
    /// **"A model on this Mac", not "the local model".** The pane asks the downloaded model first
    /// and falls to Apple's on-device model below it with no label between them, so naming the
    /// downloaded one would be untrue for a reader who has not downloaded it. Both are models, and
    /// both ran here — which is what the tier says, and what "this stayed on my Mac" rests on.
    ///
    /// **The remote arm draws nothing today, and stays.** Every `SentenceExplaining` declares
    /// `tier = .onDevice`, so only the first line can currently be shown, and the second sits in
    /// the catalog as a key nothing draws — a real but small cost. Dropping it costs more:
    /// `ExplainerTier` is a *licence* boundary, Milestone 3's frontier model is what will set
    /// `.remote`, and a pane with one label would then tell a reader their sentence stayed on this
    /// Mac while it was being sent away. That is the one thing the tier split exists to prevent.
    ///
    /// A `switch` rather than a ternary, so a third tier is a compile error here instead of
    /// silently taking the remote wording.
    static func provenance(_ tier: ExplainerTier) -> Text {
        switch tier {
        case .onDevice: Text("Explained by a model on this Mac · may be wrong")
        case .remote: Text("Explained by a remote model · may be wrong")
        }
    }
}

/// **An explanation, with the question it answers.**
///
/// The pane had no key, so an answer could outlive its own question: it was cleared by hand at the two
/// places someone remembered, and a third transition — confirming an ambiguous favourite, which tells
/// both panes the sense for the first time — was missed. `TranslationPane` has carried a key since it
/// was written, and this is the same idea. A value rather than a bare `SentenceExplanation` because
/// the pairing is the point: an answer and a question that have drifted apart are exactly what this
/// prevents.
struct SentencePane: Equatable {
    let answer: SentenceExplanation
    let of: SentenceQuestion
}

extension SentenceQuestion {
    /// **What the sentence pane is asked about a card, as a value the pane can be compared against.**
    ///
    /// Written out inside the explain button's action, where nothing could ask what it had been asked
    /// — so an answer stayed on screen after its own question changed. The translation pane has
    /// carried a key since it was written; this is the same idea, arrived at the hard way: confirming
    /// an ambiguous favourite changes the sense both panes were told, and only the translation
    /// noticed.
    ///
    /// The sense travels only where the card **answers** with one: an ambiguous card has admitted it
    /// does not know, and telling the model its favourite would present the guess twice.
    static func reading(_ card: LookupCard, sentence: String) -> SentenceQuestion {
        SentenceQuestion(sentence: sentence, term: card.term, senseText: card.leadingSense?.label)
    }
}

/// Pinning is the app's job, not the view's; the panel is handed a way to do it.
private struct PinNoteKey: EnvironmentKey {
    public static let defaultValue: @MainActor (PinnedNote) -> Void = { _ in }
}

/// So is writing to the ledger. Decision D8: an auxiliary dictionary's sense becomes a study item
/// only when the reader asks for one, and it is recorded as theirs.
private struct EnrolSenseKey: EnvironmentKey {
    static let defaultValue: @MainActor (SenseEncounter) -> Void = { _ in }
}

private struct StudySenseKey: EnvironmentKey {
    public static let defaultValue: @MainActor (SenseEncounter) -> Void = { _ in }
}

/// Opening Settings is the app's job too — and it is the one window the panel may bring forward:
/// "a window the reader *chose* must come forward; only panels must not."
/// Where the panel's window fit reports the two numbers it was computed from. The app supplies one
/// for `--panel-report`; everywhere else this is inert, as a measurement hook should be.
private struct ReportPanelFitKey: EnvironmentKey {
    public static let defaultValue: @MainActor (CGFloat, CGFloat) -> Void = { _, _ in }
}

private struct OpenDictionarySettingsKey: EnvironmentKey {
    public static let defaultValue: @MainActor () -> Void = {}
}

private struct CloseLookupKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// The close button takes the same path as Escape and clicking outside the card.
    public var closeLookup: @MainActor () -> Void {
        get { self[CloseLookupKey.self] }
        set { self[CloseLookupKey.self] = newValue }
    }

    /// Settings, on its Dictionary pane, **with the dictionary discovery its destination depends on
    /// already started.** Nothing asks the service until a menu is opened, so a route that opened the
    /// pane directly could leave it reading "Asking the dictionary service…" for good — the app's own
    /// action is injected rather than rebuilt here, so this route cannot be the one that forgets.
    /// What the panel's window was sized from: what its content wanted, and what its scroll view was
    /// given. Read by `--panel-report` so a window of the wrong height can be told from a window
    /// asked for the wrong height.
    public var reportPanelFit: @MainActor (CGFloat, CGFloat) -> Void {
        get { self[ReportPanelFitKey.self] }
        set { self[ReportPanelFitKey.self] = newValue }
    }

    public var openDictionarySettings: @MainActor () -> Void {
        get { self[OpenDictionarySettingsKey.self] }
        set { self[OpenDictionarySettingsKey.self] = newValue }
    }

    public var pinNote: @MainActor (PinnedNote) -> Void {
        get { self[PinNoteKey.self] }
        set { self[PinNoteKey.self] = newValue }
    }

    public var studySense: @MainActor (SenseEncounter) -> Void {
        get { self[StudySenseKey.self] }
        set { self[StudySenseKey.self] = newValue }
    }

    /// **The reader asked to study this meaning**, which is not the same act as meeting it.
    /// `studySense` records an encounter — something reading produces; this creates a target they
    /// intend to review. Two actions, deliberately not one: the feature ledger's §3A keeps pinning,
    /// bookmarking and enrolling apart for the same reason.
    public var enrolSense: @MainActor (SenseEncounter) -> Void {
        get { self[EnrolSenseKey.self] }
        set { self[EnrolSenseKey.self] = newValue }
    }
}

// MARK: - Previews

// The panel's states that need no dictionary behind them. The *waiting* state matters most: the
// panel is a container that fills in, not a payload that is awaited, and how it reads before the
// dictionaries answer is a design decision rather than a loading spinner.
#if DEBUG
// A function, not a global: `LookupPresentation` is not Sendable, and a shared mutable global
// would be a concurrency error rather than a convenience.
func sampleWaiting() -> LookupPresentation {
    LookupPresentation(
        request: 1,
        term: "ephemeral",
        lemma: Lemma(text: "ephemeral", basis: .tagger),
        source: "Safari · A page",
        capture: .accessibility(.accessibilityTextMarkers, context: .complete),
        sentence: "The ephemeral beauty of morning frost.",
        outcome: nil)
}

#Preview("Waiting for the dictionaries") {
    PanelView(content: .lookup(sampleWaiting()))
        .frame(width: 760, height: 520)
}

// MARK: - A word actually looked up
//
// The state the panel exists for, and the one that had no preview: an entry, its senses in the
// sidebar, a sense marked, the memory strip and the reader's own sentence. It needs no dictionary
// installed — `DictionaryEntry` takes the markup as a string, so the markup is here, and
// `EntryDocument.parse` reads it exactly as it reads Apple's. That is the point of building the
// sample this way rather than hand-assembling senses: a preview that bypassed the parser could
// look right while the parser was wrong.

/// Apple's own shape: `d:entry` with an id, a headword, a respelling, and `x_xd0` blocks holding
/// `x_xd1` senses that carry publisher ids. Trimmed from the fixture `SenseParsingTests` uses.
func sampleMarkup(_ style: String = sampleStyle) -> String {
    """
    <html xmlns="http://www.w3.org/1999/xhtml"     xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">    <head><style>\(style)</style></head><body>    <d:entry id="m_en_gbus0362750">    <span class="hg x_xh0"><span homograph="1" class="hw">fine</span>    <span d:prn="US" class="ph t_respell">fīn<d:prn></d:prn></span></span>    <span id="m_en_gbus0362750.004" class="se1 x_xd0">    <span class="posg x_xdh"><span d:pos="1" class="pos">adjective<d:pos></d:pos></span></span>    <span id="m_en_gbus0362750.005" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">of high quality<d:def></d:def></span>    <span class="eg"><span class="ex">a fine piece of filmmaking</span></span></span>    <span id="m_en_gbus0362750.020" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">in good health and feeling well</span>    <span class="eg"><span class="ex">&#8220;How are you?&#8221; &#8220;Fine, thanks.&#8221;</span></span></span>    <span id="m_en_gbus0362750.024" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">(of weather) bright and clear</span></span></span>    <span id="m_en_gbus0362750.029" class="se1 x_xd0">    <span class="posg x_xdh"><span d:pos="2" class="pos">adverb<d:pos></d:pos></span></span>    <span id="m_en_gbus0362750.030" class="msDict x_xd1 t_core">    <span d:def="1" class="df">in a satisfactory or pleasing manner</span></span></span>    </d:entry></body></html>
    """
}

/// Enough CSS that the pane reads as an entry rather than as a run-on line. Apple ships its own
/// with each dictionary; this stands in for it so the preview shows the shape the reader sees.
let sampleStyle = """
    body { font: -apple-system-body; margin: 14px 16px; color: -apple-system-label; }
    .hw { font-size: 1.5em; font-weight: 600; }
    .ph { color: -apple-system-secondary-label; margin-left: .4em; }
    .pos { font-style: italic; color: -apple-system-secondary-label; }
    .x_xd0 { display: block; margin-top: .9em; }
    .x_xd1 { display: block; margin: .35em 0 0 1.1em; text-indent: -1.1em; }
    .ex { color: -apple-system-secondary-label; font-style: italic; }
    .eg { display: block; margin-left: 1.1em; }
    """

func sampleEntry(_ name: String, style: String = sampleStyle) -> DictionaryEntry {
    let markup = sampleMarkup(style)
    return DictionaryEntry(
        dictionary: DictionaryIdentity(name: name, identifier: name, version: "2.3.1"),
        headword: "fine", lookedUp: "fine", html: markup,
        document: EntryDocument.parse(markup))
}

/// The reader has been here twice before, so the strip has something to say. Below two occasions
/// it stays away entirely, which is the state the other previews already cover.
private func sampleMemory() -> MemoryStrip? {
    MemoryStrip(PriorEncounters(occasions: [
        PriorEncounter(at: .now.addingTimeInterval(-7_200), where: "Safari", title: "A page"),
        PriorEncounter(at: .now.addingTimeInterval(-259_200), where: "Preview", title: "Ishiguro.pdf"),
    ]))
}

func sampleLookup(_ mark: SenseMark?) -> LookupPresentation {
    // Built from `fine`, not from `sampleWaiting()`. Starting from the waiting sample was the
    // first version and it was wrong in a way a preview is meant to catch: the header read
    // "ephemeral" above an entry for "fine", which is a panel showing one word and defining
    // another. What the reader looked up and what the entry is have to be the same word.
    //
    // Force-unwrapped: the list is two literal entries, so nil here would be this preview being
    // wrong about its own sample rather than anything the app could hit.
    // swiftlint:disable force_unwrapping
    let entries = NonEmpty([
        sampleEntry("New Oxford American Dictionary"), sampleEntry("Oxford Thesaurus"),
    ])!
    // swiftlint:enable force_unwrapping
    return LookupPresentation(
        request: 2,
        term: "fine",
        lemma: Lemma(text: "fine", basis: .tagger),
        source: "Safari · A page",
        capture: .accessibility(.accessibilityTextMarkers, context: .complete),
        sentence: "It was a fine piece of filmmaking, and the weather held.",
        outcome: .entries(entries, unreadable: []),
        sense: mark,
        memory: sampleMemory())
}

/// The ordinary success: the reader's own tap, which is a fact and is drawn as one.
#Preview("An entry, sense chosen by the reader") {
    PanelView(content: .lookup(sampleLookup(
        .chosen(key: "m_en_gbus0362750.005", by: .reader))))
        .frame(width: 760, height: 520)
}

/// The selector's guess. The same mark, drawn as the hypothesis it is — the difference between
/// these two previews is the whole of `chosen_by`, and it should be visible at a glance.
#Preview("An entry, sense guessed by XiaolaiDict") {
    PanelView(content: .lookup(sampleLookup(
        .chosen(key: "m_en_gbus0362750.020", by: .model))))
        .frame(width: 760, height: 520)
}

/// Marked nothing, and saying why. The other half of "the panel can mark a sense, and can say why
/// it did not" — and the state a screenshot of a good lookup never catches.
#Preview("An entry, nothing marked") {
    PanelView(content: .lookup(sampleLookup(.couldNot(.tooClose))))
        .frame(width: 760, height: 520)
}

// The panel's own two messages, previewed from the same values the app shows — a second copy here
// is how the previews came to be the only place four of these sentences were written as literals.
#Preview("Nothing to look up") {
    PanelView(content: .frontmostAppUnknown)
        .frame(width: 420, height: 150)
}

#Preview("Accessibility is off") {
    PanelView(content: .accessibilityIsOff)
        .frame(width: 420, height: 180)
}
#endif
