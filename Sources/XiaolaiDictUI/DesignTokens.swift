import QuartzCore
import SwiftUI

/// The drawer's design tokens.
///
/// **This file is the only place in the drawer where a bare number is allowed to appear**, and
/// every one of them is a root with a stated reason rather than a value someone liked. Everything
/// else refers to a token, which is what `NoMagicValuesTests` checks by reading the source.
///
/// Two layers, on purpose. `Token` holds the primitives — one root size and the scales derived
/// from it. `CardSurface` and `ReadingPalette` hold the *semantic* tokens, named for the job they
/// do, and views only ever read those. A primitive can then be retuned without hunting for the
/// places that meant something by it.
/// ## Where a value lives
///
/// **If it grows with the reader's text size, it belongs in `Scale`; if it does not, it belongs
/// here.** An opacity, a duration, a hairline and a window's minimum size do not grow — the
/// reader asking for larger text is not asking for a darker shadow or a slower animation. Which
/// of the two files a value is in is therefore a statement about it, not filing.
///
/// ## Adding a value
///
/// The question is never "what number do I want". It is, in order:
///
/// 1. **Which token's job is this?** Match on the role — the gap between siblings, the padding of a
///    surface, a card's corner. If one fits, use it even when the number it yields is a step from
///    what you pictured. The scale is the design.
/// 2. **If none fits, what job is this that no token does?** Say it in a sentence. If the sentence
///    is "like `stack` but a bit smaller", it is `stack`. If it is a real job — an indent, a title
///    bar's clearance, a wash that has to sit under two others — it is a new token, and that
///    sentence is its doc comment.
/// 3. **Write it as `em * n`.** A bare number is allowed only where the em is the wrong reference,
///    and then the comment has to say what the right one is. `Stroke.hairline` answers to the
///    display; `Panel` answers to the screen.
///
/// What never happens: arithmetic at a call site, a one-off override, or a second token that is the
/// first one plus two points. `NoMagicValuesTests` catches the first of those mechanically; the
/// other two are why this note exists.
enum Token {
    /// Window and column sizes. **Not em multiples**, and deliberately so: a panel is sized against
    /// the screen and against what has to fit side by side in it, not against its own type. Forcing
    /// 760 into "63.3 em" would be arithmetic pretending to be a reason.
    enum Panel {
        /// What the lookup window **opens** at, before the card has laid itself out — the scene
        /// is `.contentSize`, so the card's own width and its content decide the rest.
        ///
        /// The widths live in `Scale`, not here, because they grow with the reader's text: a fixed
        /// 400 pt is the right measure at one size and too narrow at every larger one. This is
        /// `Scale.standard`'s, which is what a reader who has never changed the setting gets.
        static let cardOpeningWidth = Scale.standard.space.cardWidth
        /// A two-line answer with its sentence, roughly. Wrong for a long one and wrong for a
        /// short one — which is why the window hugs its content rather than trusting this.
        static let cardOpeningHeight: CGFloat = 240
        static let messageWidth: CGFloat = 420
        static let messageHeight: CGFloat = 150
        static let messageMinWidth: CGFloat = 320
        static let messageMinHeight: CGFloat = 120
        /// **One width, every pane** — measured against the content rather than derived from the
        /// em, which is why it is a number with a reason instead of a ratio. Asked for their own
        /// ideal width the panes answer 744, 714 and 131 points, so letting each one decide would
        /// make the window jump sideways on every click. A grouped `Form` at the old 420 put the
        /// segmented pickers and their footers into a column narrower than any settings window on
        /// the system, which is most of why this one did not look like one.
        static let settingsWidth: CGFloat = 580
        /// The floor a pane is padded up to, so a two-row pane is still a window rather than a
        /// strip. About and Dictionary are the short ones.
        static let settingsMinHeight: CGFloat = 260
        /// And the ceiling, past which a pane scrolls rather than growing. Measured against the
        /// smallest display XiaolaiDict runs on — an M1 MacBook Air at its default scaling, 900 points
        /// tall: less its 24-point menu bar, a Dock along the bottom at about 70, and this window's
        /// own title bar and tabs, measured at 88, leaves 718 for the pane. 700 keeps the window
        /// off both edges. Needed rather than hypothetical: before its password managers were
        /// folded into one row, the Lookup pane measured 1,184 points and would have run off that
        /// screen — and at 680 it clipped the 697-point pane it became by 17, which scrolls just
        /// enough to look like a mistake.
        static let settingsMaxHeight: CGFloat = 700
        /// How large an app icon is rasterised and cached at. Fixed rather than scaled: it is the
        /// source bitmap the card downscales from, and one raster has to serve every text size.
        static let appIconRaster: CGFloat = 32
        /// How large XiaolaiDict's own icon is drawn on the About pane. A different job from
        /// `appIconRaster`, which is a source bitmap for a card: this one is shown at its size and
        /// nothing downscales from it. Fixed rather than scaled — the icon is the app's mark, and
        /// a reader asking for larger text is not asking for a larger logo.
        static let aboutIcon: CGFloat = 64
        /// Clears a transparent title bar's own controls. A structural offset, not a padding, and
        /// not scaled: the traffic lights are where they are whatever size the reader's text is.
        static let titleBarClearance: CGFloat = 28
    }

    enum Stroke {
        /// One point. Not derived from the em: a hairline is a property of the display, and a
        /// border that grew with the type would stop being a hairline.
        static let hairline: CGFloat = 1
        /// The outline of a place where something used to be — a removed card, until the reader
        /// runs out of time to take it back. Dashed because a solid border draws a thing, and the
        /// point of that row is that the thing is gone.
        static let absent: [CGFloat] = [4, 3]
    }

    /// Counts, not lengths. How many of a thing is shown does not change with how large it is.
    enum Limit {
        /// The most any label wraps to. Enough of a sentence to be a cue, not so much that a card
        /// becomes a paragraph.
        static let wrapLines = 2
        /// How many pronunciations a heading carries. A word with five is telling the reader about
        /// the dictionary rather than about the word.
        static let pronunciations = 2
        /// A dictionary that answers in prose rather than in senses. Enough to be the answer,
        /// capped because the card is not the entry.
        static let proseLines = 6
        /// Cards deeper than this hide exactly behind the last visible one, so a fifty-card pile is
        /// no taller — and no more work to draw — than a three-card one.
        static let pileDepth = 2
    }

    /// Opacities, named for what they are dimming.
    enum Opacity {
        /// A neutral card edge — a buried card, which must not wear a word's colour.
        static let border = 0.12
        /// How loudly a card's own edge wears the word's colour. Separate from the palette because
        /// the palette answers "which colour" and this answers "how much of it": an accent has to
        /// stay subordinate to the word it is marking, and a full-strength outline all the way
        /// round makes the container the loudest thing on the card.
        static let accentBorder = 0.45
        /// A card's lift off the drawer. Load-bearing: in a light appearance a white card on
        /// near-white glass has almost no fill contrast, so this and the border are the edge.
        static let cardShadow = 0.12
        /// The drawer's own lift off the desktop.
        static let drawerShadow = 0.22
        /// The rule under the header: present, not a line to read.
        static let divider = 0.40
        /// Today's count, which is tinted, against any other day's, which is not.
        static let countToday = 0.18
        static let count = 0.08
        /// The capsule behind "not found".
        static let missBadge = 0.15
        /// The lookup card's lift. Lower than the drawer's: the drawer is docked against a screen
        /// edge and has to separate from a whole desktop, the card sits beside a word for a few
        /// seconds.
        static let cardLift = 0.13
        /// The word's colour, thrown under its own card. Two shadows rather than one: a neutral
        /// dark one carries the depth, and this carries the colour — a single coloured shadow dark
        /// enough to lift the card reads as a stain, and one light enough to read as colour does
        /// not lift it at all. Subtle on purpose; the card is white and the colour is a hint of
        /// where it came from, not a theme.
        static let accentShadow = 0.20
        /// A capsule tinted with a word's own colour. Low, because the digit on top of it is at
        /// full strength and the pair has to read as one small mark rather than as two.
        static let badgeWash = 0.18
        /// A pane tinted to say what it is: a warning, a memory strip, a sense the reader kept.
        /// Three steps because they stack — a wash that reads as emphasis on its own reads as
        /// noise next to two others.
        static let caveatWash = 0.08
        static let memoryWash = 0.07
        static let senseWash = 0.05
        /// A word that was never found has no colour of its own, and its edge says so quietly.
        static let missAccent = 0.45
    }

    /// Waits, as opposed to animations. Both are durations and neither is the other: a spring that
    /// took as long as a timeout would be broken, and a timeout tuned like an animation would fire
    /// while the thing it is waiting for is still working.
    enum Timing {
        /// How often the settings window re-asks the system about a permission. macOS posts
        /// nothing when one changes, and the reader grants it in another app and comes back.
        static let permissionPoll: Duration = .seconds(1)
        /// A local document of a few kilobytes renders in milliseconds; one still loading after
        /// this is stuck, and says so rather than staying a blank pane.
        static let entryLoad: Duration = .seconds(5)
        /// How long a removed card can still be brought back. Long enough for the reader to see
        /// the row and reach it, short enough that a drawer left open all afternoon is not still
        /// holding a deletion the reader considers done.
        static let undoGrace: Duration = .seconds(6)
    }

    enum Motion {
        /// A hover: fast enough to feel attached to the pointer.
        static let hover = 0.12
        /// The drawer's content sliding in behind its own window.
        static let reveal = 0.16
        /// A pile fanning open. A spring, because the cards are objects being dealt.
        static let fanResponse = 0.38
        static let fanDamping = 0.82
        /// How far a closed pile rises under the pointer. Small on purpose — it says "one object,
        /// clickable", and anything larger says "this is about to move".
        static let lift = 1.012
        /// The settings window finding the height of the pane just chosen. Measured in TYPE, where
        /// the same window moves the same way: 0.3 s reads as one movement rather than a jump.
        /// Seconds rather than an `Animation`, because the window is moved by AppKit — SwiftUI
        /// moving it was measured to overshoot and correct itself.
        static let paneResize: TimeInterval = 0.3
        /// Prompt at the start, unhurried at the end. `easeInOut` eases *into* the movement as
        /// well, which on a height change reads as hesitation before anything happens.
        static var paneResizeCurve: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        }
    }
}
