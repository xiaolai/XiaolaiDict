import AppKit
import SwiftUI

/// **Where the system's accessibility display settings are answered, once.**
///
/// Measured 2026-10-01: a grep for `reduceMotion`, `reduceTransparency`, `colorSchemeContrast`,
/// `accessibilityShowBorders`, `differentiateWithoutColor` and `appearsActive` across both source
/// trees returned **zero hits** — eleven animation sites, about sixty borderless icon buttons and
/// every custom colour, none of which changed for a reader who had asked the system for less
/// motion, more contrast or visible edges. The fix is not eleven `if`s. It is that each setting has
/// one function saying what it does to this app, and a surface calls it in one line.
///
/// Everything here is a pure function of the setting, so it is tested as one; the view reads the
/// environment and passes it in. The AppKit controllers in the app target have no environment and
/// read `MotionPreference.systemReduceMotion` instead — which is why this half is public.
public enum MotionPreference {
    /// What the system says right now, for a caller with no SwiftUI environment: the drawer's
    /// and the settings window's AppKit controllers. A view reads
    /// `@Environment(\.accessibilityReduceMotion)` and must not use this — it does not update a
    /// body when the setting changes.
    @MainActor public static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The animation to use: `full` as written, or a short fade when the reader asked for less
    /// motion. **A fade and not nothing** — a state change with no transition at all reads as a
    /// glitch, and Reduce Motion asks for less movement, not for cuts.
    public static func animation(_ full: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: Token.Motion.reducedFade) : full
    }

    /// How far something travels: all the way, or not at all. For the offset half of a slide, so
    /// that under Reduce Motion the view arrives in place and only its opacity changes.
    public static func travel(_ full: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : full
    }

    /// A scale factor, or the identity. Reduce Motion names zooming and scaling specifically, so a
    /// hover lift is a motion even at 1.2%.
    public static func scale(_ full: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : full
    }

    /// Seconds for an AppKit animation — a window finding its height — or zero, which moves it at
    /// once. There is no cross-fade to fall back to for a frame change.
    public static func duration(_ full: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : full
    }
}

/// What Increase Contrast does to an edge. The colours themselves answer for it where they are
/// declared — `ReadingAccent.color(in:contrast:)` — and these are the two strengths `CardSurface`
/// draws its borders at.
enum ContrastAdaptation {
    /// A neutral hairline: a hint ordinarily, a line when contrast is increased.
    static func neutralBorderOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? Token.Opacity.borderIncreased : Token.Opacity.border
    }

    /// A card's edge in its word's colour: subordinate ordinarily, undiluted when increased.
    static func accentBorderOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? Token.Opacity.accentBorderIncreased : Token.Opacity.accentBorder
    }
}

/// How a selection is drawn in a window that is, or is not, the one being worked in.
///
/// The platform greys a selection when its window goes to the back, and a custom selection that
/// stays accent blue says the window is still listening when it is not. Pass
/// `@Environment(\.appearsActive)`.
enum SelectionAppearance {
    /// The ring round a selected card.
    static func ring(appearsActive: Bool) -> Color {
        appearsActive ? .accentColor : Color(nsColor: .secondaryLabelColor)
    }

    /// The fill behind a selected row.
    static func fill(appearsActive: Bool) -> Color {
        Color(nsColor: appearsActive ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }
}

/// An edge round a control that has none of its own, drawn only when the reader has turned on
/// Show Borders. `IconButton` applies it; any other `.plain` button a surface draws should too.
private struct ShowBordersEdge: ViewModifier {
    @Environment(\.accessibilityShowBorders) private var showsBorders

    func body(content: Content) -> some View {
        content.overlay {
            if showsBorders {
                RoundedRectangle(cornerRadius: Token.Target.edgeRadius, style: .continuous)
                    .strokeBorder(.secondary, lineWidth: Token.Stroke.hairline)
            }
        }
    }
}

/// An animation that becomes a fade under Reduce Motion, read from the environment so the call
/// site stays one line.
private struct MotionAwareAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(MotionPreference.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// A visible edge when the reader asked for one, and nothing otherwise.
    func showBordersEdge() -> some View { modifier(ShowBordersEdge()) }

    /// `.animation(_:value:)`, as a fade when the reader asked for less motion. Use this instead
    /// of `.animation` for anything that springs, slides or scales.
    func motionAwareAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }
}
