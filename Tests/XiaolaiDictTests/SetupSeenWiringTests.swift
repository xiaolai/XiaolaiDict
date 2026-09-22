import AppKit
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport

@testable import XiaolaiDict

/// **The board counts as shown when the reader has it, not when it was opened.**
///
/// Measured on the E2E machine 2026-09-22: launched with another app in front, the board was drawn
/// and that app stayed frontmost — macOS's cooperative activation refuses focus at launch. The app
/// wrote "shown" straight after opening it, so a reader who never saw the board never had it open
/// by itself again. These tests hold the wire, through the app's own window property, rather than
/// the store on its own.
@MainActor struct SetupSeenWiringTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func theBoardIsRememberedWhenItsWindowBecomesKey() {
        let defaults = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: defaults)
        let store = SetupPresentationStore(defaults: defaults)
        let board = window()

        app.setupWindow = board
        #expect(!store.hasOpenedBefore(), "a window that was only opened is not one anybody saw")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: board)
        #expect(store.hasOpenedBefore(), "the board became key and was not remembered")
    }

    /// Only the board's own window. Settings becoming key says nothing about whether the reader saw
    /// the board, and counting it would mark a board nobody opened.
    @Test func anotherWindowBecomingKeyDoesNotCount() {
        let defaults = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: defaults)
        let store = SetupPresentationStore(defaults: defaults)

        app.setupWindow = window()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window())
        #expect(!store.hasOpenedBefore())
    }

    /// A replaced window stops counting. The scene can hand over a new window when it reopens, and
    /// an observer left on the old one would fire for a window that is no longer the board.
    @Test func aReplacedWindowNoLongerCounts() {
        let defaults = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: defaults)
        let store = SetupPresentationStore(defaults: defaults)
        let first = window()

        app.setupWindow = first
        app.setupWindow = window()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        #expect(!store.hasOpenedBefore(), "the observer outlived the window it was attached to")
    }
}
