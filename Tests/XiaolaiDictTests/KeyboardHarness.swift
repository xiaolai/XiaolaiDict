import AppKit
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// **A key pressed into a window hosting a SwiftUI view, reaching its keyboard shortcuts through
/// SwiftUI's own machinery**: the action SwiftUI keeps for a shortcut, not a closure the test hands it.
///
/// **Why that distinction is the whole point** (WI-8 follow-up, 2026-10-05, ADR-0048). SwiftUI keeps a
/// shortcut's action from when the shortcut was registered and registers it again only when the
/// button changes — its label, its enabled state — never for a new closure alone. A review card drawn
/// over the last one, with the same buttons enabled, kept the last card's actions, so its keys named a
/// card the sitting had left and the model refused them: on the E2E Mac a held `2` graded nothing.
/// `aHeldKeyRepeatReachesNoAction` called `ReviewView.press` with the right card itself, and could not
/// see it. A test that calls the closure asks whether the closure is right; this asks whether the key
/// reaches it.
///
/// **The key is sent to the window, never through the application's event queue.** `postEvent` and
/// `nextEvent` in a test process start AppKit pulling window-server events, and the wake-up it posts for
/// one later stops the test runner's own run loop: measured, the process exited 0 mid-suite with no
/// result line — a run that reads as green. So the key that would be `NSApplication.currentEvent` is
/// handed to the view as `pressingEvent`, the one thing substituted; the window is never ordered on
/// screen, and every test that uses this fails if no action arrives.
@MainActor
final class KeyboardHarness<Content: View> {
    struct Undelivered: Error, CustomStringConvertible {
        let description: String
    }

    let window: NSWindow
    let host: NSHostingView<Content>
    private let delivering: DeliveredKey

    /// `make` builds the view from the event source it must read the pressing key from — set it as the
    /// view's `pressingEvent`, or ignore it where nothing reads one.
    init(_ make: (_ pressingEvent: @escaping @MainActor @Sendable () -> NSEvent?) -> Content) {
        let delivering = DeliveredKey()
        self.delivering = delivering
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: make { delivering.event })
        host.frame = window.contentLayoutRect
        window.contentView = host
        render()
    }

    /// Draws the view again with new inputs, as a model publishing a new presentation does: the same
    /// view, re-rendered, never a new one.
    func show(_ make: (_ pressingEvent: @escaping @MainActor @Sendable () -> NSEvent?) -> Content) {
        let delivering = delivering
        host.rootView = make { delivering.event }
        render()
    }

    /// Brings the hosted view up to date, and lets what it scheduled for after the update run —
    /// `onAppear`, a focus change.
    func render() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
    }

    /// One keyDown sent to the window, current while it is handled, then the view brought up to date.
    func press(_ key: HarnessKey, repeating: Bool = false) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: repeating, keyCode: key.code)
        else { throw Undelivered(description: "the key event for \(key.characters) could not be made") }
        delivering.event = event
        defer { delivering.event = nil }
        window.sendEvent(event)
        render()
    }

    /// The autorepeats of a key already held down: each keyDown flagged as a repeat.
    func repeats(_ key: HarnessKey, count: Int) throws {
        for _ in 0..<count { try press(key, repeating: true) }
    }

    func close() {
        window.close()
    }
}

/// The key a harness is delivering, which the hosted view reads as the event that pressed it.
@MainActor
private final class DeliveredKey {
    var event: NSEvent?
}

/// A key as the keyboard sends it: the characters it types and its virtual key code.
struct HarnessKey {
    let characters: String
    let code: UInt16

    static let one = HarnessKey(characters: "1", code: 18)
    static let two = HarnessKey(characters: "2", code: 19)
    static let space = HarnessKey(characters: " ", code: 49)
    static let e = HarnessKey(characters: "e", code: 14)
    static let s = HarnessKey(characters: "s", code: 1)
    static let t = HarnessKey(characters: "t", code: 17)
}
