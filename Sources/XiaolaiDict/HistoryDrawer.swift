import AppKit
import XiaolaiDictCore
import Observation
import SwiftUI
import os

/// What the drawer is showing, and how much of it is fanned open.
@Observable
@MainActor
final class HistoryDrawerModel {
    /// Nil until the drawer has been laid out for a display. The root view draws nothing rather
    /// than guessing a size — a sentinel rect would reach AppKit as a window nobody can see.
    var geometry: DrawerGeometry?
    /// Drives the slide. **The window never moves while this animates.**
    var revealed = false
    var days: [ReadingDay] = []
    /// Day ids whose pile is fanned open. Today is never in here; it is never piled.
    var expandedDays: Set<String> = []
    /// Set while the ledger is being read, so the drawer can say so instead of looking empty.
    var isLoading = false
    /// A ledger that could not be read. Shown, never swallowed — an empty drawer and a broken one
    /// must not look the same.
    var problem: String?

    var totalEntries: Int { days.reduce(0) { $0 + $1.entries.count } }

    func isExpanded(_ day: ReadingDay) -> Bool { expandedDays.contains(day.id) }

    func setExpanded(_ expanded: Bool, for day: ReadingDay) {
        if expanded { expandedDays.insert(day.id) } else { expandedDays.remove(day.id) }
    }
}

/// What a read of the reading history produced.
///
/// An explicit pair rather than a `Result` carrying a string: the failure case holds the words the
/// drawer will actually show the reader, which is not an `Error` and should not pretend to be one.
enum HistoryReading: Sendable {
    case entries([ReadingEntry])
    case unavailable(String)
}

/// A borderless, non-activating panel docked to a screen edge.
///
/// `becomesKeyOnlyIfNeeded` and no `NSApp.activate()`: the drawer appears **without taking focus
/// from whatever the reader was reading**, which is the same rule the lookup panel follows. The
/// spike this came from activated the app and made the panel key, and built its Escape handling and
/// its click-away dismissal on the panel being key — neither of which survives the rule.
final class HistoryDrawerPanel: NSPanel {
    /// Key only when the reader clicks into the drawer, never just because it appeared.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        // In whichever Space the reader is in, over a full-screen app, and not a window to cycle to.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true

        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn by SwiftUI inside the window. A window shadow is computed from the
        // opaque content and would smear while the drawer slides.
        hasShadow = false

        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none   // the slide is ours, not AppKit's
    }
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
    private let panel = HistoryDrawerPanel()
    private var hostingView: NSHostingView<HistoryDrawerRootView>!
    private let escape: EscapeKey
    private let layout: DrawerLayout

    /// Reading the ledger. Injected so the drawer can be driven in a test without a database.
    private let load: @MainActor () async -> HistoryReading
    /// The displays, and where the pointer is. Injected for the same reason.
    private let screens: @MainActor () -> [ScreenMetrics]
    private let pointer: @MainActor () -> CGPoint
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
        pointer: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        clock: @escaping @MainActor () -> Date = { .now },
        load: @escaping @MainActor () async -> HistoryReading
    ) {
        self.layout = layout
        self.escape = EscapeKey(hotkeys: hotkeys)
        self.screens = screens
        self.pointer = pointer
        self.clock = clock
        self.load = load

        hostingView = NSHostingView(rootView: HistoryDrawerRootView(model: model))
        panel.contentView = hostingView

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
        // Commits the parked state *before* the window is on screen. Without it the first frame
        // shows the drawer already in place and it never appears to slide.
        hostingView.layoutSubtreeIfNeeded()

        // Ordered front without activating: the app the reader was reading keeps focus.
        panel.orderFrontRegardless()
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
            self.panel.orderOut(nil)
            self.activeScreen = nil
        }
    }

    // MARK: - What an instrument can measure

    /// Whether the panel is actually on screen — not whether the controller thinks it should be.
    var isOnScreen: Bool { panel.isVisible }
    /// The panel's frame as AppKit has it, so a report can compare it with the geometry it asked for.
    var windowFrame: CGRect { panel.frame }
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
        panel.setFrame(geometry.windowRect, display: false)
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
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}
