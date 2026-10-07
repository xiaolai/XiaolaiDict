import StudyKit
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
    ///
    /// **Both edges strengthen with Increase Contrast** — `contrast` defaults for the callers that
    /// predate it, and a caller that leaves it out draws the same 12% hairline for a reader who
    /// asked the system for more.
    static func border(
        for entry: ReadingEntry, layer: CardLayer, in scheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        guard layer.showsAccent else { return neutralBorder(contrast: contrast) }
        return border(accent: ReadingPalette.color(for: entry, in: scheme, contrast: contrast), contrast: contrast)
    }

    /// A card's edge in a colour the caller already has — the Library's cards and the inspector,
    /// which hold a lemma rather than a ledger row. Pass the accent at full strength; how much of
    /// it the edge wears is decided here, so no call site multiplies an opacity of its own.
    static func border(accent: Color, contrast: ColorSchemeContrast) -> Color {
        accent.opacity(ContrastAdaptation.accentBorderOpacity(contrast))
    }

    /// The edge of a card that wears no word's colour: a buried one, a notice, a divider.
    static func neutralBorder(contrast: ColorSchemeContrast) -> Color {
        .primary.opacity(ContrastAdaptation.neutralBorderOpacity(contrast))
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
