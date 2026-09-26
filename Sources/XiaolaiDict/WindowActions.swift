import SwiftUI
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// The environment's real window actions, captured from a live view.
///
/// An `NSApplicationDelegate` has no environment of its own, and `EnvironmentValues()` constructed
/// on the spot is wired to nothing — its `openWindow` silently does nothing, which is exactly how
/// a drawer came to report that it had opened while no window was ever drawn.
///
/// The menu-bar item's label is a view that exists for as long as the app does, so it is the one
/// place these can be taken from reliably.
///
/// **And they are nil until that view's `.task` runs, which is after
/// `applicationDidFinishLaunching`.** That gap was known — `openSetupOnFirstLaunch` polls up to five
/// seconds for it — and it was load-bearing in a way nothing had noticed: the hot key was registered
/// and hover started inside `applicationDidFinishLaunching`, before it. A shortcut pressed in that
/// window made `LookupPanel.show` a silent no-op, `isCurrent(ticket)` stayed true, and `LookupRunner`
/// ran the whole lookup, resolved a sense and wrote a ledger row for a panel the reader never saw —
/// breaking "a lookup nobody saw is not recorded" by exactly the mechanism the paragraph above
/// describes.
///
/// Three things close it, and the accessors here are the first: **an unwired action is loud**, not a
/// no-op. `onCapture` is the second — the delegate arms its triggers from it rather than at launch.
/// `LookupPanelController.show` answering `false` is the third.
@MainActor
final class WindowActions {
    static let shared = WindowActions()

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "windows")

    private(set) var open: OpenWindowAction?
    private(set) var dismiss: DismissWindowAction?
    /// Opening Settings, for the same reason: `SettingsLink` opens the window but cannot bring
    /// XiaolaiDict forward with it, and an accessory app's window opened behind the app the reader is
    /// using is a window they never see.
    private(set) var settings: OpenSettingsAction?

    /// Whether the actions have arrived. Read by `ready(within:)` and by the delegate's fallback.
    var areWired: Bool { open != nil && dismiss != nil && settings != nil }

    /// Called once, when the menu-bar label hands the actions over. **The delegate arms the hot key
    /// and hover from here**, so neither can fire before there is a window to draw into.
    ///
    /// Idempotent on the delegate's side: `.task` is tied to a view's lifetime rather than to any
    /// documented ordering against the app delegate, so a second capture is possible and must be
    /// harmless.
    var onCapture: (@MainActor () -> Void)?

    func capture(open: OpenWindowAction, dismiss: DismissWindowAction, settings: OpenSettingsAction) {
        let first = !areWired
        self.open = open
        self.dismiss = dismiss
        self.settings = settings
        log.notice("windows: actions captured (first: \(first, privacy: .public))")
        onCapture?()
    }

    /// Opens a window, and says whether it could.
    ///
    /// **Loud on a miss**, because the alternative is what this file's history is about: a default
    /// that skips quietly is a defect generator, and `open?(id:)` was five call sites of exactly
    /// that. `.fault` rather than `.error` — a surface the reader asked for not existing is not a
    /// degraded mode, it is the app not working.
    @discardableResult
    func openWindow(id: String) -> Bool {
        guard let open else {
            log.fault("windows: asked to open \(id, privacy: .public) before the actions were captured")
            return false
        }
        open(id: id)
        return true
    }

    @discardableResult
    func openWindow(value: some Codable & Hashable) -> Bool {
        guard let open else {
            log.fault("windows: asked to open a value window before the actions were captured")
            return false
        }
        open(value: value)
        return true
    }

    @discardableResult
    func dismissWindow(id: String) -> Bool {
        guard let dismiss else {
            log.fault("windows: asked to dismiss \(id, privacy: .public) before the actions were captured")
            return false
        }
        dismiss(id: id)
        return true
    }

    @discardableResult
    func openSettings() -> Bool {
        guard let settings else {
            log.fault("windows: asked to open Settings before the actions were captured")
            return false
        }
        settings()
        return true
    }

    /// Waits for the actions, up to `limit`; says whether they came.
    ///
    /// **One place, because three instruments needed it and only one had it.** `SettingsReport`
    /// polled for `WindowActions.shared.settings != nil` and the other two did not:
    /// `HistoryReport.run` calls `app.toggleHistory()` and `PanelReport.measure` calls
    /// `app.lookUpHovered` directly, both scheduled from `applicationDidFinishLaunching`, so neither
    /// went through the hot key or hover and neither was helped by arming those later. Codex found
    /// that; without this they would have become *reported* failures rather than working
    /// instruments, which is better and still broken.
    func ready(within limit: Duration = .seconds(5)) async -> Bool {
        await Instrument.settle(until: limit) { WindowActions.shared.areWired }
    }
}

/// Carries the menu-bar icon, and takes the window actions while it is at it.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let icon = XiaolaiDictApp.menuBarImage() {
                Image(nsImage: icon)
            } else {
                Text("XiaolaiDict")   // no image at all is still no reason to show nothing
            }
        }
        .task {
            WindowActions.shared.capture(
                open: openWindow, dismiss: dismissWindow, settings: openSettings)
        }
    }
}
