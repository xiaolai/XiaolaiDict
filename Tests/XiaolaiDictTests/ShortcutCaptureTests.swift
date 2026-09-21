import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
import Testing

@testable import XiaolaiDictUI

/// **One recording of a shortcut, and everything that ends it.**
///
/// The field first caught keys through the responder chain — `keyDown` for plain keys and
/// `performKeyEquivalent` for modified ones — and both were wrong in a settings window.
/// `performKeyEquivalent` is offered to *every* view in the window, not just the one with focus, so
/// an unarmed field on the Lookup pane would have taken ⌘W as the new lookup shortcut and eaten the
/// close. And `keyDown` needed a zero-sized view to hold first responder, which the end-to-end run
/// measured it not doing: the field armed, the key was pressed, and nothing arrived.
///
/// A local monitor, installed only while armed and ended by anything that ends the reader's
/// attention, is what TYPE moved to for the same two reasons.
@MainActor struct ShortcutCaptureTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    // MARK: What a press means

    @Test func bareEscapeCancels() {
        #expect(ShortcutCapture.interpret(keyCode: UInt16(kVK_Escape), flags: []) == .cancel)
    }

    /// With a modifier it is someone recording, not someone reaching for the cancel key — TYPE
    /// cancelled on ⌥⎋ for a while, and a perfectly good combination could not be chosen.
    @Test func escapeWithAModifierIsAShortcut() {
        #expect(ShortcutCapture.interpret(keyCode: UInt16(kVK_Escape), flags: [.option])
            == .take(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey))))
    }

    /// A bare key is *offered*, not refused here: whether it is usable is the field's call, and it
    /// answers with a hint rather than silence.
    @Test func aBareKeyIsOfferedAsIs() {
        #expect(ShortcutCapture.interpret(keyCode: UInt16(kVK_ANSI_K), flags: [])
            == .take(Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: 0)))
    }

    /// Caps Lock and the function key ride along in `modifierFlags` and are not modifiers of a
    /// shortcut. Left in, ⌃⌥D pressed with Caps Lock on would record as something else.
    @Test func onlyTheFourShortcutModifiersCount() {
        #expect(ShortcutCapture.interpret(keyCode: UInt16(kVK_ANSI_D), flags: [.control, .option, .capsLock, .function])
            == .take(Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))))
    }

    // MARK: Its lifetime

    /// **Unarmed, it listens to nothing.** This is the ⌘W defect made structural: no monitor
    /// exists until the reader asks to record, so there is nothing to swallow a key with.
    @Test func nothingIsCapturedUntilArmed() {
        let capture = ShortcutCapture()
        #expect(!capture.isArmed)
        #expect(!capture.isListening)
    }

    @Test func armingListensAndEndingStops() {
        let capture = ShortcutCapture()
        capture.begin(in: window(), onPress: { _ in }, onEnd: {})
        #expect(capture.isArmed)
        #expect(capture.isListening)
        capture.end()
        #expect(!capture.isArmed)
        #expect(!capture.isListening, "the monitor outlived the recording and would swallow every key after it")
    }

    /// Everything that takes the reader's attention away ends the recording. TYPE's first version
    /// ended it only when the view left its window — which closing a window does not do — and the
    /// monitor stayed armed for the life of the app, saving the next key pressed anywhere.
    @Test(arguments: [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification])
    func losingTheWindowEndsIt(_ name: Notification.Name) {
        let capture = ShortcutCapture()
        let window = window()
        capture.begin(in: window, onPress: { _ in }, onEnd: {})
        NotificationCenter.default.post(name: name, object: window)
        #expect(!capture.isArmed, "\(name.rawValue) left the recording armed")
        #expect(!capture.isListening)
    }

    @Test func leavingTheAppEndsIt() {
        let capture = ShortcutCapture()
        capture.begin(in: window(), onPress: { _ in }, onEnd: {})
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!capture.isArmed)
    }

    /// Scoped to its own window: another window closing is not the reader leaving this one.
    @Test func anotherWindowDoesNotEndIt() {
        let capture = ShortcutCapture()
        capture.begin(in: window(), onPress: { _ in }, onEnd: {})
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window())
        #expect(capture.isArmed)
        capture.end()
    }

    /// `onEnd` is what puts the reader's hot key back. Called exactly once per recording however
    /// it ends — twice would be harmless today and a trap the day it is not, and never would leave
    /// the shortcut stood down until XiaolaiDict was relaunched.
    @Test func theEndIsReportedExactlyOnce() {
        let capture = ShortcutCapture()
        let window = window()
        var ends = 0
        capture.begin(in: window, onPress: { _ in }, onEnd: { ends += 1 })
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        capture.end()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(ends == 1)
    }

    /// **A recording dropped while armed still ends.** Switching Settings panes while the field was
    /// armed reached none of the ends above — the window stayed key and the app stayed active —
    /// so either the monitor went on swallowing keys from a pane the reader could no longer see,
    /// or, if SwiftUI dropped the field's state, the recorder was freed with its monitor installed
    /// and `onEnd` never called, leaving the reader's hot key stood down until XiaolaiDict was relaunched.
    @Test func aRecordingDroppedWhileArmedStillEnds() {
        var ends = 0
        var capture: ShortcutCapture? = ShortcutCapture()
        capture?.begin(in: window(), onPress: { _ in }, onEnd: { ends += 1 })
        #expect(capture?.isListening == true)
        capture = nil
        #expect(ends == 1, "the recorder was freed while armed and the hot key was never put back")
    }

    /// **Leaving the Lookup pane ends the recording — decided by the model, not the view.**
    ///
    /// Measured in the running app, twice: switching panes neither fired the field's `onDisappear`
    /// nor updated a flag handed to it, because Settings keeps a hidden pane's views alive and does
    /// not re-evaluate them. The monitor went on listening on the other pane, and a combination
    /// pressed there became the new shortcut. The one thing that does change is the model's pane.
    @Test func leavingTheLookupPaneEndsTheRecording() {
        let model = SettingsModel()
        model.pane = .lookup
        var ends = 0
        model.shortcutCapture.begin(in: window(), onPress: { _ in }, onEnd: { ends += 1 })
        model.pane = .reading
        #expect(!model.shortcutCapture.isListening, "the monitor outlived the pane it belongs to")
        #expect(ends == 1, "the hot key was not put back when the reader left the pane")
    }

    /// Selecting the pane that is already showing is not leaving it.
    @Test func reselectingTheLookupPaneKeepsTheRecording() {
        let model = SettingsModel()
        model.pane = .lookup
        model.shortcutCapture.begin(in: window(), onPress: { _ in }, onEnd: {})
        model.pane = .lookup
        #expect(model.shortcutCapture.isArmed)
        model.shortcutCapture.end()
    }

    /// Arming twice is one recording, not two monitors — the second of which nothing would remove.
    @Test func armingTwiceIsOneRecording() {
        let capture = ShortcutCapture()
        var ends = 0
        capture.begin(in: window(), onPress: { _ in }, onEnd: { ends += 1 })
        capture.begin(in: window(), onPress: { _ in }, onEnd: { ends += 1 })
        capture.end()
        #expect(ends == 1)
        #expect(!capture.isListening)
    }
}
