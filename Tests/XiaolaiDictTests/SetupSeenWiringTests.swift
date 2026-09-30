import AppKit
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **The board counts as shown when the reader has it, not when it was opened.**
///
/// Measured on the E2E machine 2026-09-22: launched with another app in front, the board was drawn
/// and that app stayed frontmost — macOS's cooperative activation refuses focus at launch. The app
/// wrote "shown" straight after opening it, so a reader who never saw the board never had it open
/// by itself again. These tests hold the wire, through the app's own window property, rather than
/// the store on its own.
///
/// **The pane test is what the move to a settings pane added.** The board had a window of its own
/// until 2026-10-01, and that window becoming key could only mean one thing. The settings window is
/// opened for six reasons, and a reader who came to change their text size has not seen setup.
@MainActor struct SetupSeenWiringTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    private func app(_ defaults: UserDefaults, on pane: SettingsPane) -> XiaolaiDictApp {
        let app = XiaolaiDictApp(defaults: defaults, models: .temporary(defaults: defaults))
        app.settings.pane = pane
        return app
    }

    @Test func theBoardIsRememberedWhenSettingsBecomesKeyShowingIt() {
        let defaults = TemporaryDefaults.suite()
        let app = app(defaults, on: .setup)
        let store = SetupPresentationStore(defaults: defaults)
        let settings = window()

        app.settingsWindow = settings
        #expect(!store.hasOpenedBefore(), "a window that was only opened is not one anybody saw")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        #expect(store.hasOpenedBefore(), "the board became key and was not remembered")
    }

    /// **The pane decides.** Settings coming forward on Reading is a reader changing their text
    /// size; counting it would mark a board they never looked at, and it would never open by
    /// itself again — which is the whole defect this wire exists to prevent, arriving by a new
    /// route the moment the board stopped having a window of its own.
    @Test func settingsBecomingKeyOnAnotherPaneDoesNotCount() {
        for pane in SettingsPane.allCases where pane != .setup {
            let defaults = TemporaryDefaults.suite()
            let app = app(defaults, on: pane)
            let store = SetupPresentationStore(defaults: defaults)
            let settings = window()

            app.settingsWindow = settings
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
            #expect(!store.hasOpenedBefore(), "\(pane.name) counted as having seen the board")
        }
    }

    /// And switching to the board while the window is already key still counts — the reader is
    /// looking at it either way, and only the order differs.
    @Test func switchingToTheBoardOnAKeyWindowCounts() {
        let defaults = TemporaryDefaults.suite()
        let app = app(defaults, on: .reading)
        let store = SetupPresentationStore(defaults: defaults)
        let settings = window()

        app.settingsWindow = settings
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        #expect(!store.hasOpenedBefore())

        app.settings.pane = .setup
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        #expect(store.hasOpenedBefore(), "the reader switched to the board and it was not remembered")
    }

    /// Only this window. Another one becoming key says nothing about whether the reader saw the
    /// board, and counting it would mark a board nobody opened.
    @Test func anotherWindowBecomingKeyDoesNotCount() {
        let defaults = TemporaryDefaults.suite()
        let app = app(defaults, on: .setup)
        let store = SetupPresentationStore(defaults: defaults)

        app.settingsWindow = window()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window())
        #expect(!store.hasOpenedBefore())
    }

    /// A replaced window stops counting. The scene can hand over a new window when it reopens, and
    /// an observer left on the old one would fire for a window that is no longer the reader's.
    @Test func aReplacedWindowNoLongerCounts() {
        let defaults = TemporaryDefaults.suite()
        let app = app(defaults, on: .setup)
        let store = SetupPresentationStore(defaults: defaults)
        let first = window()

        app.settingsWindow = first
        app.settingsWindow = window()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        #expect(!store.hasOpenedBefore(), "the observer outlived the window it was attached to")
    }
}
