import XiaolaiDictCore
import SwiftUI

/// What a reading card is made of — the semantic layer over `Token`.
///
/// Separate from the view because none of it is view state: it is the definition of the surface,
/// and the property that matters most about it can then be checked by reading a number rather than
/// by looking at the screen.
enum CardSurface {
    /// The card's fill. **Opaque on purpose, and the opacity is the load-bearing part.**
    ///
    /// A pile is a pile only because the front card hides the ones behind it. The 6% wash this
    /// replaced hid nothing, and barely read as a surface either: measured against the drawer it
    /// was a 3.5% step, 241 on 250. Stacked three deep the plates composited 241 → 229 → 217
    /// inward, so a closed pile drew as nested boxes darkening towards the middle, with the buried
    /// cards' top edges and coloured arcs showing straight through the front card's own text.
    static func fill(for scheme: ColorScheme, hovering: Bool) -> Color {
        switch (scheme, hovering) {
        case (.dark, false): return Shade.darkResting.color
        case (.dark, true): return Shade.darkHovered.color
        case (_, false): return Shade.lightResting.color
        case (_, true): return Shade.lightHovered.color
        }
    }

    /// The card's edge, **in the word's own colour, all the way round**.
    ///
    /// A buried card's is not: it keeps the neutral edge. Three coloured borders stacked in one
    /// closed pile is the defect `CardLayer` exists to prevent, and colouring the whole border
    /// rather than one side of it would otherwise have walked straight back into it.
    static func border(for entry: ReadingEntry, layer: CardLayer, in scheme: ColorScheme) -> Color {
        guard layer.showsAccent else { return .primary.opacity(Token.Opacity.border) }
        let accent = ReadingPalette.accent(for: entry)?.color(in: scheme) ?? ReadingPalette.miss
        return accent.opacity(Token.Opacity.accentBorder)
    }

    /// The lookup panel's own surface — **paper, not material.** `.regularMaterial` takes its
    /// colour from whatever happens to be behind the window, so the card is a different shade over
    /// a photograph than over an editor, and the word's coloured shadow has nothing steady to sit
    /// on. Near-white rather than white so the hairline and the shadow have something to be
    /// against.
    static func panel(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? Shade.darkResting.rawValue : 0.985)
    }

    /// The four fills a card can have, written out rather than computed from a base and a delta:
    /// "white" and "very slightly grey" are two decisions, not one decision and a nudge.
    ///
    /// A card is always **lighter** than the drawer it sits on, in both appearances — raised, never
    /// a recessed patch. The wash this replaced was darker than the drawer, which is what made it
    /// read as a stain rather than as a surface.
    enum Shade: Double {
        case lightResting = 1.0
        case lightHovered = 0.945
        case darkResting = 0.19
        case darkHovered = 0.26

        var color: Color { Color(white: rawValue) }
    }
}
