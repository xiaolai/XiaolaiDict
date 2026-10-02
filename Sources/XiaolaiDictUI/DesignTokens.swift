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
public enum Token {
    /// Window and column sizes. **Not em multiples**, and deliberately so: a panel is sized against
    /// the screen and against what has to fit side by side in it, not against its own type. Forcing
    /// 760 into "63.3 em" would be arithmetic pretending to be a reason.
    /// The Review window, which the reader opens deliberately and types into.
    ///
    /// **Public**, unlike its neighbours, because the scene that opens the window lives in the app
    /// target and a window's opening size is a design value like any other. The alternative — a
    /// literal in the scene — is the one-off override that turns a token system into decoration.
    public enum Review {
        /// What it **opens** at. A window the reader manages, so this is a starting size and not a
        /// measurement of anything: they resize it and the system remembers. Wide enough for a
        /// sentence at the standard text size without the cue wrapping into a paragraph, which is
        /// what makes a cue read as a sentence rather than as a block of text.
        public static let width: CGFloat = 480
        /// Tall enough for a sentence, the word, the question and the buttons, with the answer's
        /// space **unreserved** — a gap the size of a definition is the definition's shape, and the
        /// window growing on reveal is the honest version of that.
        public static let height: CGFloat = 320
    }

    /// The library window, where the reader takes stock. **Public** for the same reason as
    /// `Review`: the scene that opens it lives in the app target, and a window's opening size is a
    /// design value rather than a literal for a scene to invent.
    public enum Library {
        /// The search field's width. Wide enough for a phrase, narrow enough that the state filter
        /// beside it is not pushed off the edge at the largest text size.
        static let searchWidth: CGFloat = 240
        /// The tag field. Narrow: a tag is a word, and a field the width of a sentence invites one.
        static let tagWidth: CGFloat = 120
        /// How many times a field that has just been brought on screen is asked to take the caret,
        /// and how long between askings — the tag field when the inspector is opened for it, the
        /// search field when the magnifier opens into it. A column sliding in and a toolbar item
        /// being swapped both refuse focus until they have settled; ten askings a tenth apart
        /// cover that three times over and then stop, so a field that never appears is not asked
        /// for ever.
        static let focusAttempts = 10
        static let focusInterval = 0.1
        /// How tall the inspector's two histories may grow before they scroll. A window's worth
        /// of reading, not a screen's: past this the pane would push its own controls off.
        static let inspectorHistoryHeight: CGFloat = 220
        /// The same, for the set-aside list under the suggestions.
        static let setAsideHeight: CGFloat = 160
        /// The sidebar's width, replacing a seven-way segmented picker on 2026-10-01 — a control
        /// that had one segment per state and no room to name any of them. Wide enough for the
        /// longest label, *Needs attention*, beside its symbol. Not derived from the em: the labels
        /// are the system's own sidebar font, and a sidebar that grew with the reader's chosen text
        /// size would move the list sideways for a reason that has nothing to do with it.
        static let sidebarWidth: CGFloat = 200
        /// How far the reader may drag the sidebar either way from `sidebarWidth`, which is its
        /// ideal. The floor still fits *Needs Attention* beside its symbol; the ceiling stops a
        /// sidebar of seven short labels from taking a column of cards.
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarMaxWidth: CGFloat = 280
        /// The glyph of an icon button in the window's toolbar. Not an em multiple: the toolbar is
        /// the system's chrome and keeps the system's size, so the selection's buttons there do not
        /// grow with the reader's text as the same buttons on a card do. The size the system
        /// draws its own toolbar symbols at.
        static let toolbarGlyph: CGFloat = 15
        /// The most columns the grid ever has, however wide the window. Newest to oldest runs across
        /// a rank and then down, and past four cards the eye does not find its way back to the start
        /// of the next rank; a wider window makes the cards wider instead. A count, so it does not
        /// grow with the reader's text — the width a card needs does, and that is `cardMinWidth`.
        static let maxColumns = 4
        /// The window, which is the sidebar and the list beside it.
        ///
        /// **Wide enough for two columns of cards beside the inspector** at the standard text size:
        /// two cards at their narrowest and their gutters come to 669 pt, the inspector to 312. At
        /// 720 pt the inspector's arrival took the grid from two columns to one, so the card just
        /// clicked moved under the pointer. Tall enough for four or five cards rather than two.
        /// An opening size only — a window the reader has resized keeps the size they gave it.
        public static let width: CGFloat = 1000 + sidebarWidth
        public static let height: CGFloat = 760
        /// The smallest the window goes. **The sidebar at its narrowest and two-thirds of a card**
        /// at the standard text size — enough of a card to read its word and its sentence, which is
        /// the point below which the window shows the reader nothing they came for. Measured against
        /// the card and not the em because it is a window's floor, like `width`: at a larger text
        /// size the grid drops to one column sooner, and the floor does not move under the reader.
        /// It had none: the window could be dragged down to its toolbar (audit L19, 2026-10-02).
        public static let minWidth: CGFloat = sidebarMinWidth + Scale.standard.space.cardMinWidth * 2 / 3
        /// Tall enough for the toolbar and one card of ordinary length, by the same reasoning.
        public static let minHeight: CGFloat = 360
    }

    enum Panel {
        /// A two-line answer with its sentence, roughly — **the size the window opens at, before its
        /// content has any say.** Wrong for a long answer and wrong for a short one, which is why
        /// `fitsItsContent(upTo:)` then moves the window to the height the card actually wants.
        ///
        /// This comment used to claim the window already hugged its content. It did not: measured
        /// 2026-09-25, three runs and three different cards, the window was 398 × 240 every time, with
        /// the whole footer below the fold. A claim in a comment is not a mechanism, and there was
        /// none behind this one.
        static let cardOpeningHeight: CGFloat = 240
        /// What the card adds outside the frame its scrolling region is capped at — its surface,
        /// border and shadow padding. Measured at 21 pt at `standard`; 32 is that rounded up rather
        /// than fitted to it, so the allowance says "the chrome, generously" instead of pretending to
        /// a precision it has not got. The panel's window may be this much taller than the cap and no
        /// more, which is what `theHeightStopsGrowingOnceTheCapIsReached` and `--panel-report` both
        /// measure against.
        static let cardChrome: CGFloat = 32
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
    }

    /// **How small a thing a pointer can be asked to hit.**
    ///
    /// A new role rather than a new number: none of the existing tokens is about *aim*. And in `Token`
    /// rather than `Scale`, which is a claim about the value and a deliberate one — a reader asking for
    /// larger text is not asking for a larger mouse, so this does not grow with the type. The glyph
    /// inside it does, which is why it is applied as a **minimum** and not as a size: at
    /// `TextSize.large` a symbol wider than the floor keeps its own width.
    ///
    /// Measured before it existed: the card's and the drawer's icon buttons were **13 to 19 pt**
    /// (`NSImage.SymbolConfiguration` at `text.body`, per symbol), six of them 6 pt apart, with no
    /// padding and no `contentShape` — so the clickable region was the glyph's own box. On a history
    /// card the destructive trash sat 6 pt from open-in-Dictionary at 14 × 16 pt.
    enum Target {
        /// macOS's own default control size, from Apple's accessibility guidance. Not derived from the
        /// em for the reason above: it is a property of pointing, not of reading.
        static let minimum: CGFloat = 28
        /// The corner of the edge an icon-only control draws when the reader has turned on Show
        /// Borders. The platform's own small-control corner, and fixed for the reason the floor is:
        /// it rounds a 28 pt target, which does not grow with the text.
        static let edgeRadius: CGFloat = 6
        /// The smallest an app's icon is drawn. Sixteen points is the smallest size an app icon
        /// is designed at; drawn at the 10.8 pt of the text beside it, TextEdit's — a ruled white
        /// page — was a blank white square on every card (measured 2026-10-02: 378 of its 620
        /// opaque pixels at 32 px are white, against none of Terminal's).
        static let sourceIcon: CGFloat = 16
    }

    /// The Reading History panel, measured against the screen it docks to.
    enum Drawer {
        /// The widest the panel gets, whatever the reader's text size. Its width grows with the
        /// em so a card keeps its measure, and stops here so that at `extraLarge` and `huge` it
        /// still leaves 720 pt of a 1280 pt display to whatever the reader was reading.
        static let maxWidth: CGFloat = 560
    }

    /// Type that does **not** grow with the reader's size — which is one value, the floor.
    enum Text {
        /// The smallest any text is ever set, whatever the reader chose. Apple's floor for macOS,
        /// and not an em multiple for the reason it exists: at `compact` the scale's own ratios
        /// gave `small` 9.90 pt and `micro` 9.35 pt (measured 2026-10-01), so the two tokens that
        /// carry most of the app's text were under it. `Scale.Text` takes the larger of this and
        /// its ratio; nothing else reads it.
        static let minimum: CGFloat = 10
        /// The system's own control-text size, for the one explicitly sized view — `StatusLabel`
        /// — when it sits in a settings form. Measured against the platform rather than the em:
        /// the rows around it are set in the system font, and a status line at the reader's
        /// reading size would be the only text in the window that moved with it.
        static var form: CGFloat { NSFont.systemFontSize }
    }

    enum Stroke {
        /// A selection edge must remain distinct from the card’s hairline on a desktop display.
        static let selection: CGFloat = 2
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
        /// How much of the reader's own sentence a library row shows. Two lines: enough to
        /// recognise the row, not enough to read instead of reviewing.
        static let excerptLines = 2

        /// The most any label wraps to. Enough of a sentence to be a cue, not so much that a card
        /// becomes a paragraph.
        static let wrapLines = 2
        /// Cards deeper than this hide exactly behind the last visible one, so a fifty-card pile is
        /// no taller — and no more work to draw — than a three-card one.
        static let pileDepth = 2

        /// How tall the inspector's answer editor is, in lines. **A count, not a height**: it grows
        /// with the reader's text because the lines do. Three is a definition; eight is where an
        /// answer has stopped being a card and the editor should scroll rather than the window.
        static let answerLinesAtLeast = 3
        static let answerLinesAtMost = 8
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
        /// Both edges with Increase Contrast on. The neutral one goes from a hint to a line — 12%
        /// of the label colour is about 1.3:1 against the card, this is over 5:1 in both
        /// appearances — and the accent stops being diluted at all, because the increased shade it
        /// is drawn in was chosen to be read.
        static let borderIncreased = 0.60
        static let accentBorderIncreased = 1.0
        /// A card's lift off the drawer. Load-bearing: in a light appearance a white card on
        /// near-white glass has almost no fill contrast, so this and the border are the edge.
        static let cardShadow = 0.12
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
        /// A pane tinted to say what it is: a warning, or what the model made of the sentence.
        /// Two steps because they stack — a wash that reads as emphasis on its own reads as noise
        /// next to another.
        static let caveatWash = 0.08
        static let senseWash = 0.05
        /// A word that was never found has no colour of its own, and its edge says so quietly.
        static let missAccent = 0.45
        /// A line of text on a card that can be pressed — a disclosure, a row to choose — under
        /// the pointer, and while it is held down. The wash is the label colour, so it darkens a
        /// light card and lightens a dark one; the two steps are what a list row does, and the
        /// press is twice the hover so the change on mouse-down is visible on either paper.
        static let controlHover = 0.06
        static let controlPressed = 0.12
    }

    /// Waits, as opposed to animations. Both are durations and neither is the other: a spring that
    /// took as long as a timeout would be broken, and a timeout tuned like an animation would fire
    /// while the thing it is waiting for is still working.
    enum Timing {
        /// How often the settings window re-asks the system about a permission. macOS posts
        /// nothing when one changes, and the reader grants it in another app and comes back.
        static let permissionPoll: Duration = .seconds(1)
        /// How long the screen-recording probe may take before it counts as having said nothing.
        /// Generous against its measured ~70 ms, because this bounds a wedged capture service
        /// rather than setting a performance target: anything resembling a stall is one. It exists
        /// because that probe is awaited by the menu refresh, by the setup board's polling and by
        /// `askForDictionaries()` — one unanswering call used to hold all three.
        static let permissionProbe: Duration = .seconds(3)
    }

    enum Motion {
        /// A hover: fast enough to feel attached to the pointer.
        static let hover = 0.12
        /// The drawer's content sliding in behind its own window.
        static let reveal = 0.16
        /// The Reading History panel arriving from its screen edge, and leaving for it. Springs,
        /// and two of them: it arrives with a little give and leaves without any, because a panel
        /// that bounces on its way out reads as coming back. Named here since 2026-10-02 — they
        /// were bare numbers in the controller, beside an implicit `.easeOut` on the view that
        /// replaced them, so the motion these describe was never the one on screen.
        static let drawerOpenResponse = 0.34
        static let drawerOpenDamping = 0.86
        static let drawerCloseResponse = 0.26
        static let drawerCloseDamping = 0.95
        /// A pile fanning open. A spring, because the cards are objects being dealt.
        static let fanResponse = 0.38
        static let fanDamping = 0.82
        /// What every custom animation becomes with Reduce Motion on: a short cross-fade, with no
        /// travel, spring or scale. Long enough to be seen as a change rather than a cut, short
        /// enough that nothing appears to move.
        static let reducedFade = 0.15
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
