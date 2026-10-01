import AppKit
import SwiftUI
import Testing

@testable import XiaolaiDictUI

/// What each accessibility display setting does to the app, as functions of the setting.
struct AccessibilityAdaptationTests {
    private let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Left alone, an animation is the one that was written.
    @Test func motionIsUntouchedUnlessTheReaderAskedForLess() {
        // Typed here, not inside `#expect`: the macro type-checks each side alone, and a
        // `CGFloat` beside a `Double` of the same value compared unequal.
        let lift: CGFloat = Token.Motion.lift
        #expect(MotionPreference.animation(spring, reduceMotion: false) == spring)
        #expect(MotionPreference.travel(380, reduceMotion: false) == 380)
        #expect(MotionPreference.scale(lift, reduceMotion: false) == lift)
        #expect(MotionPreference.duration(Token.Motion.paneResize, reduceMotion: false) == Token.Motion.paneResize)
    }

    /// Reduced, nothing travels, springs or scales: a short fade, in place.
    @Test func reduceMotionLeavesAFadeAndNothingElse() {
        let reduced = MotionPreference.animation(spring, reduceMotion: true)
        #expect(reduced != spring)
        #expect(reduced == .easeOut(duration: Token.Motion.reducedFade))
        #expect(MotionPreference.travel(380, reduceMotion: true) == 0)
        #expect(MotionPreference.scale(Token.Motion.lift, reduceMotion: true) == 1)
        #expect(MotionPreference.duration(Token.Motion.paneResize, reduceMotion: true) == 0)
    }

    /// A fade short enough that nothing appears to move, and not so short it is a cut.
    @Test func theFadeIsShort() {
        #expect(Token.Motion.reducedFade > 0)
        #expect(Token.Motion.reducedFade <= Token.Motion.reveal + Token.Motion.hover)
    }

    /// A selection in a window that is not being worked in is grey, as the platform's own is.
    @Test @MainActor func aSelectionGreysWhenItsWindowIsNotActive() throws {
        #expect(SelectionAppearance.ring(appearsActive: true) == Color.accentColor)
        #expect(SelectionAppearance.ring(appearsActive: false) != Color.accentColor)
        var saturation: CGFloat?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            saturation = NSColor(SelectionAppearance.ring(appearsActive: false))
                .usingColorSpace(.sRGB)?.saturationComponent
        }
        #expect(try #require(saturation) < 0.05, "an inactive ring is still wearing a colour")
        #expect(SelectionAppearance.fill(appearsActive: true) != SelectionAppearance.fill(appearsActive: false))
    }

    /// The edge Show Borders draws is the control's own target, rounded like a control.
    @Test func theShowBordersEdgeFitsTheTarget() {
        #expect(Token.Target.edgeRadius > 0)
        #expect(Token.Target.edgeRadius < Token.Target.minimum / 2, "a circle, not a control's edge")
    }
}

/// How a key is written after a button's name.
struct ShortcutLabelTests {
    @Test func aBareKeyIsItsCapital() {
        #expect(ShortcutLabel.text(for: KeyboardShortcut("1", modifiers: [])) == "1")
        #expect(ShortcutLabel.text(for: KeyboardShortcut("s", modifiers: [])) == "S")
    }

    @Test func modifiersComeFirstInThePlatformsOrder() {
        #expect(ShortcutLabel.text(for: KeyboardShortcut("z", modifiers: .command)) == "⌘Z")
        #expect(ShortcutLabel.text(for: KeyboardShortcut("a", modifiers: [.command, .shift])) == "⇧⌘A")
        #expect(ShortcutLabel.text(for: KeyboardShortcut("d", modifiers: [.command, .option, .control, .shift])) == "⌃⌥⇧⌘D")
    }

    @Test func keysWithNoLetterAreNamedOrDrawn() {
        #expect(ShortcutLabel.text(for: KeyboardShortcut(.space, modifiers: [])) == "Space")
        #expect(ShortcutLabel.text(for: KeyboardShortcut(.return, modifiers: [])) == "↩")
        #expect(ShortcutLabel.text(for: .defaultAction) == "↩")
        #expect(ShortcutLabel.text(for: .cancelAction) == "⎋")
        #expect(ShortcutLabel.text(for: KeyboardShortcut(.delete, modifiers: .command)) == "⌘⌫")
    }
}
