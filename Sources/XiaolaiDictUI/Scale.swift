import AppKit
import SwiftUI

/// How large the reader has asked XiaolaiDict's text to be.
///
/// A short named set rather than a free number. macOS has no system-wide UI text size — unlike
/// iOS Dynamic Type, an app that does not offer one offers nothing — so this is the only control
/// the reader has, and it has to be a control rather than a slider that can produce a layout
/// nobody designed. Four steps is what a reading app offers, and each one is a size the drawer has
/// actually been looked at.
public enum TextSize: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case comfortable
    case large

    /// The em this size sets. Everything spatial in the app is a multiple of it.
    ///
    /// `compact` is the platform's `smallSystemFontSize`, which is a size for secondary chrome;
    /// it is offered because some readers want density, and it is not the default because the
    /// drawer's content is prose. `large` exists for CJK especially: Chinese glyphs need more size
    /// than Latin to resolve their strokes at all.
    public var em: CGFloat {
        switch self {
        case .compact: return 11
        case .standard: return 12
        case .comfortable: return 13.5
        case .large: return 15
        }
    }

    /// Named for the reading, not for the number: a reader choosing this is choosing how the
    /// drawer feels, and "13.5 pt" is not a thing anyone wants.
    public var label: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .standard: return String(localized: "Standard")
        case .comfortable: return String(localized: "Comfortable")
        case .large: return String(localized: "Large")
        }
    }
}

/// Everything that grows with the reader's chosen text size.
///
/// **A value, not a set of static constants**, and that is the whole point: the size is a
/// preference, so the scale derived from it has to be able to change while the app is running.
/// Views read it from the environment, which is also what makes it testable — a card can be
/// rendered at any em without touching a global.
///
/// What is *not* here is as deliberate as what is. An opacity, a duration, a hairline and a
/// window's minimum size do not grow with the reader's text, and they stay in `Token`. Where a
/// value lives says whether it scales.
struct Scale: Equatable, Sendable {
    /// The root. Every length below is a multiple of it, so the whole surface rescales from one
    /// number and the proportions between the parts survive the rescale.
    let em: CGFloat

    let text: Text
    let space: Space
    let radius: Radius
    let shadow: Shadow

    init(em: CGFloat) {
        self.em = em
        text = Text(em: em)
        space = Space(em: em)
        radius = Radius(em: em)
        shadow = Shadow(em: em)
    }

    init(_ size: TextSize) { self.init(em: size.em) }

    /// What a preview, a test, and any view drawn before the scene has injected anything get.
    /// Defaulted rather than optional: a missing scale must not be a card of size zero.
    static let standard = Scale(.standard)

    /// Type, as ratios of the em. A short scale on purpose: every extra step is one more
    /// near-identical choice at a call site, and a surface this small cannot show the difference.
    ///
    /// Only where a size is set explicitly. The **pinned note** uses the platform's own semantic
    /// fonts — `.title3`, `.body`, `.caption` — and replacing those with points would be a
    /// downgrade dressed as tidying.
    ///
    /// The lookup panel was in that sentence and no longer is. `LookupCardView` sets every size
    /// from here, because the card's width is `space.cardWidth` and a measure only holds if the
    /// type it measures is the type this scale describes: semantic fonts would size themselves
    /// against the system while the card sized itself against the em, and the line length the
    /// width exists to protect would drift away from the text in it.
    struct Text: Equatable, Sendable {
        /// A window's own title.
        let display: CGFloat
        /// A section or row title — and the drawer's header.
        let heading: CGFloat
        /// The word on a card. The one thing the eye should land on first.
        let strong: CGFloat
        /// The reader's sentence, and anything else that is prose.
        let body: CGFloat
        /// An action that is not a button — "Show All", a settings hint.
        let label: CGFloat
        /// Where it was read, and when. Present, never competing with the word.
        let small: CGFloat
        /// Inside a capsule, which supplies its own emphasis.
        let micro: CGFloat
        /// A glyph standing in for a whole empty state.
        let icon: CGFloat
        /// Extra air between the wrapped lines of a sentence. SwiftUI's default leading is set for
        /// dense chrome; this is prose the reader is trying to recall from.
        let leading: CGFloat

        /// The tallest a passage in `body` may be and still be `lines` lines: one point short of
        /// the height of one line more. So a candidate that is `lines` lines fits and one that is
        /// `lines + 1` does not, with most of a line to spare against rounding either way. From
        /// the system font's own metrics — ascender, descender and leading — which is what `Text`
        /// sets a line with.
        func height(ofLines lines: Int) -> CGFloat {
            let font = NSFont.systemFont(ofSize: body)
            let line = font.ascender - font.descender + font.leading
            return line * CGFloat(lines + 1) + leading * CGFloat(lines) - 1
        }

        init(em: CGFloat) {
            display = em * 1.36
            heading = em * 1.18
            strong = em * 1.15
            body = em * 1.00
            label = em * 0.95
            small = em * 0.90
            micro = em * 0.85
            icon = em * 2.00
            leading = em * 0.20
        }
    }

    /// Space, as multiples of the em, named for the job rather than for the size. `stack` is not
    /// "9 points", it is "the gap between siblings", and it stays that through a retune.
    struct Space: Equatable, Sendable {
        /// Between a capsule's text and its own edge, where anything more would make a pill.
        let tight: CGFloat
        /// Between lines inside one block of text.
        let line: CGFloat
        /// Between items sitting on one line.
        let inline: CGFloat
        /// Between siblings: card to card, a header to what it heads, one kind of fact to another.
        let stack: CGFloat
        /// Between a block of text and whatever is parked at the far end of its row.
        let column: CGFloat
        /// Between one day and the next — the only gap meant to read as a break.
        let section: CGFloat
        /// The ordinal column in front of a sense, so labels line up however many digits the
        /// numbers run to.
        let ordinal: CGFloat

        /// **The inner padding of anything holding content** — a card, the drawer's list, its
        /// header, an empty state.
        ///
        /// Across and down differ, and that is typography rather than fussiness: line-height
        /// already supplies vertical air and nothing supplies horizontal, so equal insets read
        /// looser top-to-bottom than side-to-side. `pad` is the pair, for the common case of
        /// padding a whole surface; the scalars are for edges taken singly.
        let padAcross: CGFloat
        let padDown: CGFloat
        let pad: EdgeInsets

        /// **The lookup card's width, in ems — so the measure survives a change of text size.**
        ///
        /// It was a fixed 400 pt, which is the right line length at exactly one size: the same
        /// 400 pt holds about sixty characters at `standard` and about forty-five at `large`, and
        /// a definition set that narrow breaks into slivers. A line wants roughly 55–70
        /// characters, a character at body size averages about half an em, and the card spends
        /// 3 em on padding — so ~33 em is sixty characters at any size the reader picks.
        let cardWidth: CGFloat
        let cardMinWidth: CGFloat
        let cardMaxWidth: CGFloat

        /// **How tall the card may grow before it scrolls instead.**
        ///
        /// In ems and not a share of the screen, for the reason the width is: a reader at `large`
        /// needs more points to show the same eight senses, so a height fixed in points would show
        /// fewer of them at exactly the size that asked for more. `Token.Panel`'s sizes are measured
        /// against the screen; this one is measured against the text, so it lives here.
        ///
        /// The number is a proportion rather than a count: the card may grow until it is about as
        /// tall as it is wide at `cardWidth` (33 em), and past that it is a column rather than a
        /// card. At `standard` that is 384 pt — under half the visible height of the smallest
        /// display XiaolaiDict runs on, so the reader keeps most of the text they looked the word up
        /// from.
        ///
        /// It is a default and not a ceiling: the reader can drag the panel taller and
        /// `rememberChosenSize` keeps that size for the next lookup of the same kind.
        let cardMaxHeight: CGFloat

        /// How a pile of cards is offset behind its front card. Smaller than `stack`: these are
        /// the same cards shown stacked rather than listed, so the gap has to read as depth
        /// rather than as separation.
        let peek: CGFloat
        let sideInset: CGFloat

        init(em: CGFloat) {
            tight = em * 0.125
            line = em * 0.25
            inline = em * 0.50
            stack = em * 0.75
            column = em * 1.00
            section = em * 1.50
            ordinal = em * 1.50
            padAcross = em * 1.50
            padDown = em * 1.25
            // From the scalars, never from the multipliers again: written out twice, retuning
            // `padAcross` alone left whole-surface padding disagreeing with edge-specific padding
            // on the same card — a difference nobody would go looking for.
            pad = EdgeInsets(
                top: padDown, leading: padAcross, bottom: padDown, trailing: padAcross)
            cardWidth = em * 33
            cardMinWidth = em * 26
            cardMaxWidth = em * 46
            cardMaxHeight = em * 32
            peek = em * 0.625
            // **Narrower than `peek`, and that ordering is the whole effect.** At `em * 0.80` the
            // side step was larger than the vertical one, so the second plate gave up 19.2 pt of
            // width per side while gaining 15 pt of visible height — which reads as three cards of
            // three different sizes rather than as one card with two behind it. Depth is announced
            // by the peek; the inset only has to hint that the edges are not the same edge.
            sideInset = em * 0.40
        }
    }

    struct Radius: Equatable, Sendable {
        /// Close to the em, so a card's corner stays in proportion to its text at any size.
        let card: CGFloat
        /// A raised surface in a window, which is larger than a card and rounds a little more.
        let panel: CGFloat

        init(em: CGFloat) {
            card = em * 0.90
            panel = em * 1.00
        }
    }

    /// Shadow geometry. The opacities live in `Token`, because how dark a shadow is does not
    /// depend on how large the text is.
    struct Shadow: Equatable, Sendable {
        let cardRadius: CGFloat
        /// Down only: light comes from above, so a card sits on the drawer rather than floating.
        let cardOffset: CGFloat
        let drawerRadius: CGFloat

        /// **The lookup card's own shadow — small, because the card is.** Kept apart from the
        /// drawer's: that is a docked panel the width of a sidebar and needs a shadow to match,
        /// while this appears beside a word and goes away again. Sharing one radius gave the card
        /// the drawer's, a 22 pt blur under a 270 pt card — a cast shadow rather than a lift.
        let panelRadius: CGFloat
        /// The colour, a little wider than the depth so it reads as light at the edge rather than
        /// as a second outline. Only a little.
        let glowRadius: CGFloat

        /// **How far they fall, across and down.** Light comes from the top left, so a shadow
        /// belongs at the bottom right — and that means offsetting by most of the blur radius
        /// rather than by a nudge. A blur of radius *r* spreads *r* in every direction before the
        /// offset moves it, so at `y = r * 0.1` the halo above the card is nearly as wide as the
        /// shadow below: a glow on four sides, which is what it was.
        ///
        /// Short of the radius on purpose. At exactly *r* the shadow separates from the card and
        /// reads as a second shape behind it; the remainder is what keeps it attached.
        let panelOffset: CGFloat
        let glowOffset: CGFloat
        /// What the card is padded by so its shadows have somewhere to fall: almost nothing above
        /// and to the left, the whole spread below and to the right. Uniform padding would leave
        /// dead space on two sides of a window sized to its content.
        let glowBefore: CGFloat
        let glowAfter: CGFloat

        init(em: CGFloat) {
            cardRadius = em * 0.25
            cardOffset = em * 0.10
            drawerRadius = em * 1.80
            panelRadius = em * 0.50
            glowRadius = em * 0.85
            panelOffset = em * 0.35
            glowOffset = em * 0.60
            // From the shadow, not from its multipliers. Repeated, a retuned glow kept the old
            // reserved space — so the shadow would either be clipped by the window or float in a
            // margin sized for a shadow that no longer exists.
            glowBefore = max(0, glowRadius - glowOffset)
            glowAfter = glowRadius + glowOffset
        }
    }
}

extension EnvironmentValues {
    /// Defaulted, never optional: a view drawn before the scene injects anything must come out at
    /// a sensible size rather than at zero.
    @Entry var scale = Scale.standard
}

/// The reader's appearance choices, and where they are kept.
///
/// Observable so that changing the size redraws what is already on screen. A preference that only
/// took effect on relaunch would be the kind of half-working control that is worse than none.
@Observable
@MainActor
public final class Appearance {
    public var textSize: TextSize {
        didSet { if textSize != oldValue { store.save(textSize) } }
    }

    /// Whether a card shows the minute a word was looked up. Off unless the reader turns it on.
    public var showsTime: Bool {
        didSet { if showsTime != oldValue { store.save(showsTime: showsTime) } }
    }

    /// Whether a card spells out the app a word was read in, beside its icon.
    public var showsPlaceName: Bool {
        didSet { if showsPlaceName != oldValue { store.save(showsPlaceName: showsPlaceName) } }
    }

    /// How the word is picked out of the reader's own sentence.
    public var emphasis: WordEmphasis {
        didSet { if emphasis != oldValue { store.save(emphasis) } }
    }

    /// Whether the panel says when a word was read off the screen rather than from an app's own
    /// text. **Off by default** — see `CardOptions.warnsAboutScreenReading` for why the measured
    /// rate does not support interrupting for it, and who it is still worth turning on for.
    public var warnsAboutScreenReading: Bool {
        didSet {
            if warnsAboutScreenReading != oldValue {
                store.save(warnsAboutScreenReading: warnsAboutScreenReading)
            }
        }
    }

    /// How much of what is behind the history drawer shows through it.
    public var drawerGlass: DrawerGlass {
        didSet { if drawerGlass != oldValue { store.save(drawerGlass) } }
    }

    private let store: AppearanceStore

    public init(store: AppearanceStore = AppearanceStore()) {
        self.store = store
        textSize = store.loadTextSize()
        showsTime = store.loadShowsTime()
        showsPlaceName = store.loadShowsPlaceName()
        emphasis = store.loadEmphasis()
        warnsAboutScreenReading = store.loadWarnsAboutScreenReading()
        drawerGlass = store.loadDrawerGlass()
    }

    var scale: Scale { Scale(textSize) }
    var cardOptions: CardOptions {
        CardOptions(
            showsTime: showsTime, showsPlaceName: showsPlaceName, emphasis: emphasis,
            warnsAboutScreenReading: warnsAboutScreenReading)
    }
}

/// The reader's appearance choices, kept across launches.
public struct AppearanceStore {
    static let defaultsKey = "TextSize"
    static let showsTimeKey = "CardShowsTime"
    static let warnsAboutScreenReadingKey = "WarnsAboutScreenReading"
    static let showsPlaceNameKey = "CardShowsPlaceName"
    static let emphasisKey = "WordEmphasis"
    static let drawerGlassKey = "DrawerGlass"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unset — or unrecognised — value is `.standard` rather than a failure. A preference file
    /// written by a later version must not leave the reader with no text at all.
    func loadTextSize() -> TextSize {
        defaults.string(forKey: Self.defaultsKey).flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    func save(_ size: TextSize) {
        defaults.set(size.rawValue, forKey: Self.defaultsKey)
    }

    /// `object(forKey:)` rather than `bool(forKey:)`: the latter answers false for a key that was
    /// never set, which is indistinguishable from a reader who turned it off. Here the two happen
    /// to agree, and relying on that would be the kind of accident that breaks the next default.
    /// The fallbacks are `CardOptions`' own, never a second copy of them. Written out here, a
    /// changed default would apply to a view drawn without an injected appearance and not to a
    /// fresh install — the same app disagreeing with itself about what "default" means.
    func loadShowsTime() -> Bool {
        defaults.object(forKey: Self.showsTimeKey) as? Bool ?? CardOptions().showsTime
    }

    func save(showsTime: Bool) {
        defaults.set(showsTime, forKey: Self.showsTimeKey)
    }

    func loadWarnsAboutScreenReading() -> Bool {
        defaults.object(forKey: Self.warnsAboutScreenReadingKey) as? Bool ?? CardOptions().warnsAboutScreenReading
    }

    func save(warnsAboutScreenReading: Bool) {
        defaults.set(warnsAboutScreenReading, forKey: Self.warnsAboutScreenReadingKey)
    }

    func loadShowsPlaceName() -> Bool {
        defaults.object(forKey: Self.showsPlaceNameKey) as? Bool ?? CardOptions().showsPlaceName
    }

    func save(showsPlaceName: Bool) {
        defaults.set(showsPlaceName, forKey: Self.showsPlaceNameKey)
    }

    func loadEmphasis() -> WordEmphasis {
        defaults.string(forKey: Self.emphasisKey).flatMap(WordEmphasis.init(rawValue:))
            ?? CardOptions().emphasis
    }

    func save(_ emphasis: WordEmphasis) {
        defaults.set(emphasis.rawValue, forKey: Self.emphasisKey)
    }

    /// Unrecognised is the default, never a failure — the same rule as the text size.
    func loadDrawerGlass() -> DrawerGlass {
        defaults.string(forKey: Self.drawerGlassKey).flatMap(DrawerGlass.init(rawValue:)) ?? .standard
    }

    func save(_ glass: DrawerGlass) {
        defaults.set(glass.rawValue, forKey: Self.drawerGlassKey)
    }
}

/// Draws a view — and everything inside it — the way the reader has asked for.
///
/// A modifier rather than public environment keys, so the app target cannot inject choices of its
/// own: there is one set of them, they belong to the reader, and `Appearance` is where they live.
public extension View {
    func xiaolaiDictAppearance(_ appearance: Appearance) -> some View {
        ScaledContent(appearance: appearance, content: self)
    }
}

/// Reads the appearance **inside a view's body**, which is what makes changing the size redraw
/// what is already on screen. Written as a view rather than as a plain `environment(_:_:)` call in
/// the scene for exactly that reason: observation is tracked where a body is evaluated, and a
/// preference that only took effect on relaunch would be worse than no preference.
private struct ScaledContent<Content: View>: View {
    let appearance: Appearance
    let content: Content

    var body: some View {
        content
            .environment(\.scale, appearance.scale)
            .environment(\.cardOptions, appearance.cardOptions)
            .environment(\.drawerGlass, appearance.drawerGlass)
    }
}
