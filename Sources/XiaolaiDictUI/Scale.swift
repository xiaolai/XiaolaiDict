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
    /// Only where a size is set explicitly. The lookup panel and the pinned note use the
    /// platform's own semantic fonts — `.title2`, `.callout`, `.caption` — and replacing those
    /// with points would be a downgrade dressed as tidying.
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
        /// How far a child is set in from its parent — a sense under its entry.
        let indent: CGFloat
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
            indent = em * 1.25
            section = em * 1.50
            ordinal = em * 1.50
            padAcross = em * 1.50
            padDown = em * 1.25
            pad = EdgeInsets(
                top: em * 1.25, leading: em * 1.50, bottom: em * 1.25, trailing: em * 1.50)
            peek = em * 0.625
            sideInset = em * 0.80
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

        init(em: CGFloat) {
            cardRadius = em * 0.25
            cardOffset = em * 0.10
            drawerRadius = em * 1.80
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
        didSet {
            guard textSize != oldValue else { return }
            store.save(textSize)
        }
    }

    private let store: TextSizeStore

    public init(store: TextSizeStore = TextSizeStore()) {
        self.store = store
        textSize = store.load()
    }

    var scale: Scale { Scale(textSize) }
}

/// The reader's text size, kept across launches.
public struct TextSizeStore {
    static let defaultsKey = "TextSize"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unset — or unrecognised — value is `.standard` rather than a failure. A preference file
    /// written by a later version must not leave the reader with no text at all.
    func load() -> TextSize {
        defaults.string(forKey: Self.defaultsKey).flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    func save(_ size: TextSize) {
        defaults.set(size.rawValue, forKey: Self.defaultsKey)
    }
}

/// Draws a view — and everything inside it — at the reader's chosen text size.
///
/// A modifier rather than a public environment key, so the app target cannot inject a scale of its
/// own: there is one text size, it belongs to the reader, and `Appearance` is where it lives.
public extension View {
    func xiaolaiDictTextSize(_ appearance: Appearance) -> some View {
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
        content.environment(\.scale, appearance.scale)
    }
}
