import AppKit
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import Observation
import SwiftUI
import os

/// What a read of the reading history produced.
///
/// An explicit pair rather than a `Result` carrying a string: the failure case holds the words the
/// drawer will actually show the reader, which is not an `Error` and should not pretend to be one.
enum HistoryReading: Sendable {
    case entries([ReadingEntry])
    case unavailable(String)
}

/// Shows and hides the history drawer.
///
/// **The window never animates.** It is placed at its final docked rect and the SwiftUI content
/// slides inside it. Animating the window's frame relayouts the whole hierarchy every frame and
/// stutters; this is the spike's central finding and the reason `DrawerGeometry` reports a parked
/// offset at all.
@MainActor
final class HistoryDrawerController {
    /// How far back the drawer looks, and how many cards it will hold. Both bounded: the drawer is
    /// opened often, and the read happens off the main actor but the array still has to live in it.
    static let window: TimeInterval = 60 * 60 * 24 * 14
    static let cardLimit = 400

    let model = HistoryDrawerModel()

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "drawer")
    /// The rect the scene should be placed at, worked out before it is opened and read back by
    /// `defaultWindowPlacement`. A scene cannot be handed a frame.
    private(set) var placement: CGRect?
    private let escape: EscapeKey
    private let layout: DrawerLayout

    /// Reading the ledger. Injected so the drawer can be driven in a test without a database.
    private let load: @MainActor () async -> HistoryReading
    /// The displays, and where the pointer is. Injected for the same reason.
    private let screens: @MainActor () -> [ScreenMetrics]
    private let pointer: @MainActor () -> UpPoint
    private let clock: @MainActor () -> Date

    /// Fires for clicks delivered to *other* applications. Clicks inside the drawer are local
    /// events and never reach it, which is exactly what is wanted. Mouse monitors need no
    /// permission; a global **key** monitor would need Accessibility, which is why Escape is a
    /// claimed hot key instead.
    private var clickAway: Any?

    /// Resolved when the drawer opens and held until it closes, so moving the pointer mid-session
    /// does not make the drawer hop displays.
    private var activeScreen: ScreenMetrics?
    /// The read in flight. Internal so a test can await it rather than sleeping.
    private(set) var reload: Task<Void, Never>?

    private(set) var isVisible = false

    /// Where the status item is, so a click on it is left for the status item's own action. Without
    /// this the click-away dismissal fires first and the toggle immediately reopens the drawer,
    /// which the reader experiences as a drawer that cannot be closed from the menu bar.
    var statusItemFrame: (@MainActor () -> CGRect?)?

    private let openAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)
    private let closeAnimation = Animation.spring(response: 0.26, dampingFraction: 0.95)

    init(
        layout: DrawerLayout = DrawerLayout(thickness: 380, edge: .right),
        hotkeys: HotkeyCenter = .shared,
        screens: @escaping @MainActor () -> [ScreenMetrics] = { NSScreen.screens.map(ScreenMetrics.init) },
        pointer: @escaping @MainActor () -> UpPoint = { UpPoint(NSEvent.mouseLocation) },
        clock: @escaping @MainActor () -> Date = { .now },
        load: @escaping @MainActor () async -> HistoryReading
    ) {
        self.layout = layout
        self.escape = EscapeKey(hotkeys: hotkeys)
        self.screens = screens
        self.pointer = pointer
        self.clock = clock
        self.load = load

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - Visibility

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        guard let screen = DrawerPlacement.screen(under: pointer(), among: screens()) else {
            log.error("no display to open the drawer on")
            return
        }
        isVisible = true
        activeScreen = screen

        model.revealed = false
        relayout()

        // The environment's real action, captured from the menu-bar label. `EnvironmentValues()`
        // built on the spot is wired to nothing and silently opens no window at all.
        WindowActions.shared.open?(id: XiaolaiDictScene.drawerID)
        escape.claim { [weak self] in self?.hide() }
        installClickAway()
        refresh()

        // One runloop turn, so the parked frame is on screen before the spring starts. A turn, not
        // a duration — there is no interval here that a slow machine can invalidate.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            withAnimation(self.openAnimation) { self.model.revealed = true }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeClickAway()
        escape.release()
        reload?.cancel()

        // The window is ordered out by the animation's own completion, not after a duration chosen
        // to match it. The spike used 0.38 s beside a spring it had to be kept in step with by
        // hand; a completion cannot drift out of step with the animation it belongs to.
        withAnimation(closeAnimation) {
            model.revealed = false
        } completion: { [weak self] in
            guard let self, !self.isVisible else { return }
            WindowActions.shared.dismiss?(id: XiaolaiDictScene.drawerID)
            self.activeScreen = nil
        }
    }

    // MARK: - What an instrument can measure

    /// The window SwiftUI made for the drawer's scene, or nil when it is not up.
    ///
    /// `NSApplication.shared`, never `NSApp`: the latter is an implicitly unwrapped
    /// `NSApplication!` and is nil in a process that has not made one — which is every unit test,
    /// where this trapped rather than answering "no window".
    private var window: NSWindow? {
        NSApplication.shared.windows.first { $0.title == "Reading History" }
    }

    /// Whether the **compositor** has this window on screen — not the controller's bookkeeping,
    /// and not AppKit's `isVisible` either.
    ///
    /// This exists because of a specific failure. When the drawer was briefly a SwiftUI scene,
    /// every check in `--history-report` read controller state: `appeared` asked whether the
    /// controller thought it had opened, and `dockedWhereAsked` compared the rect it had asked for
    /// with itself. Both passed, the end-to-end stages passed, and no drawer was ever drawn. A
    /// window the compositor does not list is not on screen, whatever anything else claims.
    var isDrawnOnScreen: Bool { Instrument.isOnScreen(window) }
    /// The panel's frame as AppKit has it, so a report can compare it with the geometry it asked for.
    /// The frame AppKit actually gave the window, **not** the rect that was asked for. Comparing
    /// the request with itself is an assertion that cannot fail, which is what this once became.
    var windowFrame: CGRect { window?.frame ?? .zero }
    /// Whether Escape is currently XiaolaiDict's. It must be claimed only while the drawer shows.
    var isEscapeClaimed: Bool { escape.isHeld }

    // MARK: - Contents

    /// Re-reads the ledger. The read itself is off the main actor; only the result lands on it.
    private func refresh() {
        reload?.cancel()
        model.isLoading = true
        reload = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.load()
            guard !Task.isCancelled else { return }
            self.model.isLoading = false
            switch outcome {
            case .entries(let entries):
                self.model.problem = nil
                self.model.days = ReadingHistory.days(
                    from: entries, now: self.clock(), calendar: .current)
            case .unavailable(let problem):
                // Shown, not swallowed. A drawer that is empty because nothing was read and one
                // that is empty because the ledger would not open must not look the same.
                self.model.problem = problem
                self.model.days = []
                self.log.error("history unavailable: \(problem, privacy: .public)")
            }
        }
    }

    // MARK: - Layout

    private func relayout() {
        guard let screen = activeScreen else { return }
        let geometry = DrawerGeometry.make(layout, on: screen)
        model.geometry = geometry
        placement = geometry.windowRect.cg
        // A scene already on screen is not re-placed by `defaultWindowPlacement`, so a relayout
        // while it shows has to move the window itself.
        if let window, window.isVisible { window.setFrame(geometry.windowRect.cg, display: true) }
    }

    /// Also called by the screen-parameters notification. Internal so the unplug path can be
    /// driven in a test without posting a system notification and hoping it is delivered in time.
    func screensChanged() {
        guard isVisible, let screen = activeScreen else { return }
        // The display the drawer is on may have just been unplugged.
        guard DrawerPlacement.isStillAttached(screen, among: screens()) else {
            hide()
            return
        }
        // The same display, resized or rearranged: take its new metrics.
        if let current = screens().first(where: { $0.frame == screen.frame }) {
            activeScreen = current
        }
        relayout()
    }

    // MARK: - Dismissal

    private func installClickAway() {
        removeClickAway()
        clickAway = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click on the status item belongs to the status item. Letting the dismissal
                // have it too is what made the spike need a 250 ms cooldown on top: the drawer
                // closed here and the toggle reopened it microseconds later. Removing the click
                // from this monitor removes the race rather than outrunning it.
                if let frame = self.statusItemFrame?(), frame.contains(NSEvent.mouseLocation) { return }
                self.hide()
            }
        }
    }

    private func removeClickAway() {
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
    }
}

extension ScreenMetrics {
    /// The AppKit screen as the drawer's geometry needs it.
    init(_ screen: NSScreen) {
        self.init(frame: UpRect(screen.frame), visibleFrame: UpRect(screen.visibleFrame))
    }
}
