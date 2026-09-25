import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
import XiaolaiDictUI
import SwiftUI
import os

/// What a lookup needs of the panel: present it, fill it in, and say whether this lookup is still
/// the one the reader is waiting on. `LookupPanelController` is it in the app; a test puts a
/// recorder in its place, because the *order* — panel first, content later — is the thing under
/// test and cannot be seen from outside.
@MainActor
protocol LookupPanelPresenting: AnyObject {
    func newRequest() -> PanelTicket
    func isCurrent(_ ticket: PanelTicket) -> Bool
    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket)
    /// Replaces a shown panel's content without moving or resizing it. A panel the reader has
    /// dragged somewhere must not jump when its entry arrives.
    func update(_ content: PanelContent, for ticket: PanelTicket)
}

/// A request for the panel. A newer request supersedes every older one, and closing the panel
/// supersedes them all: a result that arrives late is dropped, not shown over a newer one or
/// reopened after the reader dismissed it.
struct PanelTicket: Equatable {
    let number: Int
}

/// The lookup panel: floats over the app being read — in its Space, even full screen — without
/// activating XiaolaiDict or taking keyboard focus, so typing stays where the reader left it. A click in
/// the panel focuses it; Escape closes it either way.
/// What the panel is showing. A scene's content reads this; nothing hands a window a view.
@Observable
@MainActor
final class LookupPanelModel {
    var content: PanelContent?
    /// Per kind, so a panel of one kind does not inherit the minimum of another.
    var minimumSize: NSSize = PanelContent.Kind.lookup.minimumSize
}

@MainActor
final class LookupPanelController: LookupPanelPresenting {
    let model = LookupPanelModel()
    private var current = 0
    private var shownKind: PanelContent.Kind?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
    /// Sizes the reader chose by resizing, per kind of content; kept for the next panel of that kind.
    private var chosenSizes: [PanelContent.Kind: NSSize] = [:]
    private let escape: EscapeKey
    /// Held only while the panel is on screen — a monitor that outlived it would dismiss a panel
    /// that is not there and keep a closure alive for every lookup the reader ever made.
    private var clickAway: Any?
    /// The local half of the same watch. A global monitor is never offered its own application's
    /// events, so without this a click in Settings or the drawer left the panel up.
    private var clickAwayLocal: Any?
    /// The one resize observer, kept so it can be **replaced** rather than added to. The window
    /// accessor's closure runs on every update of the view it is attached to, and the panel's body
    /// reads the model download's progress — so a 3 GB download registered a fresh observer a few
    /// hundred times, each one outliving its window and calling back for every resize after.
    private(set) var resizeObserver: (any NSObjectProtocol)?
    /// Separate from `resizeObserver` because they watch different notifications for opposite
    /// reasons: that one fires only when the reader finishes a drag, this one on every resize
    /// including the ones the content causes — which are exactly the ones nothing used to notice.
    private(set) var fitObserver: (any NSObjectProtocol)?
    /// Which window the two observers above are registered on, held weakly so a closed window is
    /// not kept alive by the bookkeeping that exists to avoid re-registering on it.
    private weak var watched: NSWindow?
    /// Pinned notes outlive the panel that made them, so they are owned here rather than by a view.
    let notes = PinnedNoteController()
    /// Where the last panel was put, so a note pinned from it lands beside it.
    private(set) var lastPointer = UpPoint(.zero)
    /// Where the scene should be placed, worked out before it opens. A scene cannot be handed a
    /// frame, so `defaultWindowPlacement` reads this back.
    private(set) var placement = NSRect(origin: .zero, size: PanelContent.Kind.lookup.defaultSize)

    init(hotkeys: HotkeyCenter = .shared) {
        escape = EscapeKey(hotkeys: hotkeys)
    }

    /// What the reader asked to study, as they ask for it. Set by the app, which owns the ledger.
    /// **With the request it belongs to.** The reader can tap a sense as soon as the entry is on
    /// screen, which is well before the lookup's own row exists — so a tap carries the request that
    /// made the panel, and the app holds it until that row is written rather than hanging it off
    /// whichever lookup happens to have been recorded last.
    var onStudySense: (@MainActor (SenseEncounter, Int) -> Void)?


    /// The window SwiftUI made for the panel's scene, or nil when it is not up.
    ///
    /// `NSApplication.shared`, never `NSApp`: the latter is implicitly unwrapped and nil in a
    /// process that has not made one, where it traps instead of answering "no window".
    private var window: NSWindow? {
        NSApplication.shared.windows.first { $0.identifier?.rawValue.contains(XiaolaiDictScene.lookupID) == true }
            ?? NSApplication.shared.windows.first { $0.title == XiaolaiDictScene.lookupTitle }
    }

    func newRequest() -> PanelTicket {
        current += 1
        return PanelTicket(number: current)
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { ticket.number == current }

    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        lastPointer = pointer
        let kind = content.kind
        let screen = NSScreen.screens.first { $0.frame.contains(pointer.cg) } ?? NSScreen.main
        let visible = UpRect(screen?.visibleFrame ?? NSRect(origin: .zero, size: kind.defaultSize))
        placement = PanelPlacement.frame(
            for: chosenSizes[kind] ?? kind.defaultSize, near: pointer, within: visible)

        model.minimumSize = kind.minimumSize
        model.content = content
        shownKind = kind
        // The environment's real action, captured from the menu-bar label. An `EnvironmentValues()`
        // built on the spot is wired to nothing and silently opens no window at all.
        WindowActions.shared.open?(id: XiaolaiDictScene.lookupID)
        // A scene already on screen is not re-placed, so a panel being reused is moved by hand.
        if let window, window.isVisible { window.setFrame(placement, display: true) }
        escape.claim { [weak self] in self?.close() }
        watchForClicksAway()
    }

    /// Fills in a panel already on screen. Same kind, so the size and the minimum stay as they
    /// were, and **the placement is not touched**: the reader may have moved or resized it while
    /// waiting. Setting the content is all it takes — a scene is not re-placed because its content
    /// changed, which the hand-built panel had to be careful to preserve.
    func update(_ content: PanelContent, for ticket: PanelTicket) {
        guard isCurrent(ticket), shownKind == content.kind else {
            // A kind that changed mid-lookup is a mistake in the caller, not something to paper
            // over by silently resizing the panel under the reader.
            if isCurrent(ticket), let shownKind, shownKind != content.kind {
                log.error("panel update changed kind from \(String(describing: shownKind), privacy: .public)")
            }
            return
        }
        model.content = content
    }

    func close() {
        WindowActions.shared.dismiss?(id: XiaolaiDictScene.lookupID)
        closed()
    }

    /// Dismisses when the reader clicks anywhere else.
    ///
    /// A card goes away when you look away, and this is the "look away". A **global** monitor,
    /// because the panel never becomes key — a local one only fires while the app is active,
    /// which for this panel is never. Mouse events need no Accessibility grant; only keys do,
    /// which is why Escape is a claimed hot key instead.
    ///
    /// The click that *opened* the panel must not close it, and a click inside it belongs to the
    /// card — so the panel's own frame is hit-tested rather than starting a cooldown. The drawer
    /// spike learned that one: a timer to outrun a race leaves the race there.
    /// **Two monitors, because one of them cannot see half the clicks.** A global monitor is not
    /// offered events delivered to its own application, so a click in Settings, the history drawer
    /// or a pinned note left the lookup panel sitting there. The local monitor covers those and
    /// **returns the event** — swallowing it would stop the click reaching the control it was aimed
    /// at.
    ///
    /// `.otherMouseDown` is in the mask for the same reason the other two are: a middle click is a
    /// click somewhere else.
    private func watchForClicksAway() {
        stopWatchingForClicksAway()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.closeIfClickWasAway(event) }
        }
        clickAwayLocal = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.closeIfClickWasAway(event) }
            return event
        }
    }

    /// Where the click actually landed, which is not always where the pointer is now.
    ///
    /// A global monitor's event arrives asynchronously, so a reader who clicks outside and moves
    /// into the panel before delivery used to have the click ignored — the position was read from
    /// `NSEvent.mouseLocation` at handling time rather than from the event. For a monitor event
    /// there is no window to be relative to and `locationInWindow` is already in screen
    /// coordinates; where there is one, the window converts it. The live pointer stays as the last
    /// resort, which is what this used to be first.
    private func closeIfClickWasAway(_ event: NSEvent) {
        guard let window, window.isVisible else { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? (event.locationInWindow == .zero ? NSEvent.mouseLocation : event.locationInWindow)
        guard !window.frame.contains(point) else { return }
        close()
    }

    private func stopWatchingForClicksAway() {
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
        if let clickAwayLocal { NSEvent.removeMonitor(clickAwayLocal) }
        clickAwayLocal = nil
    }

    /// Everything still running for the panel is now stale. Also called when the reader closes the
    /// window themselves, which the scene reports through `onDisappear`.
    func closed() {
        guard shownKind != nil else { return }
        shownKind = nil
        model.content = nil
        current += 1
        escape.release()
        stopWatchingForClicksAway()
        // The window this watched has gone with the panel. Left registered, the observer holds the
        // closed window alive and waits for a resize that cannot come.
        stopWatchingForResize()
    }

    /// Watches one window for the reader finishing a drag. Registering again replaces the last
    /// watch rather than adding to it, and closing the panel ends it.
    ///
    /// The window is held **weakly**: a notification closure is kept by the notification centre, so
    /// capturing it strongly would keep a closed window alive for as long as the app runs.
    func watchForResize(of window: NSWindow) {
        // **Nothing to do for a window already watched.** `WindowAccessor` reports on every update,
        // and the panel's download progress is observable — so this ran repeatedly for one window,
        // tearing both observers down and building them again each time. Replacement stopped them
        // accumulating; it did not stop the churn.
        if let watched, watched === window, resizeObserver != nil, fitObserver != nil { return }
        // Teardown first, then record: `stopWatchingForResize` clears `watched`, so assigning
        // before it left the guard above permanently unable to fire. The suite did not catch that
        // — it asserted the two registrations differ, which an inert guard satisfies — so the
        // assertion changed with the contract.
        stopWatchingForResize()
        watched = window
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { self?.rememberChosenSize(window.frame.size) }
        }
        fitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { self?.keepWhollyOnScreen(window) }
        }
    }

    /// Puts a window the **content** resized back onto the screen it is on.
    ///
    /// The scene is `.windowResizability(.contentSize)`, so the window grows when the entry fills in
    /// and again when the reader opens the other senses — while `show()` placed it once, against a
    /// size chosen before any of that existed, and `update()` deliberately does not re-place it.
    /// A lookup near the bottom of the display therefore drew its sense list past the edge.
    ///
    /// **A reader's drag is left alone.** `inLiveResize` is the whole of that test: a panel dragged
    /// half off the screen on purpose is the reader's business, and snapping it back mid-drag would
    /// fight their hands.
    ///
    /// **The screen is asked per resize, not remembered.** The window may have grown onto a
    /// different display than the pointer was on, and each one has its own `visibleFrame` — a
    /// menu bar on one, a Dock on whichever edge.
    ///
    /// Guarded by comparing frames rather than by a flag: `setFrame` posts this same notification,
    /// so an unconditional call would recurse. `PanelPlacement.fitted` is idempotent — asserted in
    /// `PanelPlacementTests` — which is what makes that comparison terminate.
    func keepWhollyOnScreen(_ window: NSWindow) {
        guard !window.inLiveResize else { return }
        guard let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(lastPointer.cg) })
                ?? NSScreen.main
        else { return }
        let fitted = PanelPlacement.fitted(window.frame, within: UpRect(screen.visibleFrame))
        guard fitted != window.frame else { return }
        window.setFrame(fitted, display: true)
    }

    func stopWatchingForResize() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        // Removed together with it: an observer left registered holds the closed window alive and
        // waits for a resize that cannot come.
        if let fitObserver { NotificationCenter.default.removeObserver(fitObserver) }
        fitObserver = nil
        watched = nil
    }

    /// `isolated` so it can reach the observer at all: a nonisolated `deinit` cannot touch a
    /// non-`Sendable` property. A panel controller lives as long as the app, so this is the
    /// belt to `closed()`'s braces.
    isolated deinit {
        stopWatchingForResize()
        // **Both watches, not one.** This removed only the resize observers, so a controller
        // released without `closed()` left its click monitor registered — AppKit goes on holding
        // and invoking it, and the weak capture that stops it retaining the controller is exactly
        // what stops anyone noticing.
        stopWatchingForClicksAway()
    }

    /// Only a size the reader chose by dragging is remembered — not one the panel was given, or
    /// shrunk to, to fit a smaller screen.
    func rememberChosenSize(_ size: NSSize) {
        guard let shownKind else { return }
        chosenSizes[shownKind] = size
    }
}

/// The lookup panel's scene content.
struct LookupPanelSceneView: View {
    let controller: LookupPanelController
    @Bindable var model: LookupPanelModel
    /// Read inside this body, never the scene's: the model's download progress is observable, and
    /// reading it in an `App`'s body would re-evaluate every scene on each update.
    let translation: @MainActor () -> TranslationActions
    /// Read here for the same reason, and read at the click rather than when the panel was built:
    /// a model downloaded while the panel was open explains from the panel that is already up.
    let explainer: @MainActor () -> ExplanationActions

    var body: some View {
        Group {
            if let content = model.content {
                PanelView(content: content)
                    .environment(\.pinNote) { [controller] note in
                        controller.notes.pin(note, near: controller.lastPointer)
                    }
                    // **The request this card is**, not the one the panel is on. `newRequest()`
                    // moves the counter when the next lookup begins — before its selection has
                    // been read, let alone drawn — so a tap on the card still in front of the
                    // reader was being filed under a lookup that had not happened.
                    .environment(\.studySense) { [controller] encounter in
                        guard let request = content.request else { return }
                        controller.onStudySense?(encounter, request)
                    }
                    .environment(\.translation, translation())
                    .environment(\.explainer, explainer())
            }
        }
        .frame(minWidth: model.minimumSize.width)
        .xiaolaiDictPanelBehaviour(transient: true) { window in
            // No chrome and no background of its own: the rounded card is the whole thing the
            // reader sees, and the shadow needs somewhere to fall.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            controller.watchForResize(of: window)
        }
        // The reader closing the window is as final as Escape: whatever is still arriving for this
        // lookup is stale.
        .onDisappear { controller.closed() }
    }
}
/// Accessibility it never hears it.)
@MainActor
final class EscapeKey {
    static let shortcut = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    private let hotkeys: HotkeyCenter
    private var held: Hotkey?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")

    init(hotkeys: HotkeyCenter) {
        self.hotkeys = hotkeys
    }

    var isHeld: Bool { held != nil }

    func claim(_ action: @escaping @MainActor () -> Void) {
        guard held == nil else { return }
        do {
            held = try hotkeys.register(Self.shortcut, action: action)
        } catch {
            // The panel still has its close button; Escape stays with the app being read.
            log.error("Escape not claimed for the panel: \(String(describing: error), privacy: .public)")
        }
    }

    func release() {
        held = nil
    }
}

/// Where the panel goes: below and to the right of the pointer, and wholly on the screen — shrunk
/// first when the screen is smaller than the panel, so no clamp can push it off an edge.
enum PanelPlacement {
    static let margin: CGFloat = 8

    /// Answers a bare `NSRect` because its one caller hands it straight to `NSPanel.setFrame`.
    static func frame(for size: NSSize, near pointer: UpPoint, within visible: UpRect) -> NSRect {
        let pointer = pointer.cg
        // **Shrinking belongs to `fitted` alone.** This used to shrink first and then call `fitted`,
        // which shrank again — the same normalisation owned in two places, where a change to one is
        // a silent divergence. Handing over the rectangle the pointer asks for, unshrunk, works
        // because `fitted` anchors by the top edge: whatever height survives, the panel's top stays
        // at `pointer.y - 24`. That is the case which makes the top anchor observable, and there
        // was none when it was written.
        let wanted = NSRect(
            origin: NSPoint(x: pointer.x + 12, y: pointer.y - 24 - size.height), size: size)
        return fitted(wanted, within: visible)
    }

    /// The same shrink-then-clamp, applied to a frame that **already exists** — a window the
    /// content has since resized.
    ///
    /// `frame(for:near:within:)` runs once, at `show()`, against a size chosen before the content
    /// existed. The scene is `.windowResizability(.contentSize)`, so the window then grows when the
    /// entry fills in and again when the reader opens the other senses, and nothing put it back on
    /// the screen: a lookup near the bottom of the display drew its sense list past the edge.
    ///
    /// **All four edges, not just the one that was reported.** Height growth runs off the bottom and,
    /// once pushed up, can run off the top; width growth runs off the right and, once pushed back,
    /// off the left. Both axes shrink first, for the reason the pointer placement already shrinks:
    /// clamping a frame larger than its bounds puts the upper limit below the lower one.
    ///
    /// Written from the **top edge** (`maxY - height`) rather than from `minY`. Today the two are
    /// provably the same — with no shrink `maxY - height == minY` by definition, and with a shrink
    /// `shrunk` fills the screen's height exactly, so the y clamp collapses to a single point.
    /// Checked rather than argued: 200,000 random rectangles, zero disagreements.
    ///
    /// It is kept in this form because it stops being equivalent the moment a panel is capped below
    /// the screen's height — then the clamp has room and the anchor decides whether the headword or
    /// the last sense survives. **A test asserting the difference was written, found unfalsifiable,
    /// and deleted**: there is no input today that separates them.
    static func fitted(_ rect: NSRect, within visible: UpRect) -> NSRect {
        let bounds = visible.cg
        let size = shrunk(rect.size, within: visible)
        let origin = NSPoint(
            x: clamp(rect.minX, bounds.minX + margin, bounds.maxX - margin - size.width),
            y: clamp(rect.maxY - size.height, bounds.minY + margin, bounds.maxY - margin - size.height))
        return NSRect(origin: origin, size: size)
    }

    /// Never larger than the space there is to put it in. Separate from the clamp because the order
    /// matters and has been got wrong here before.
    private static func shrunk(_ size: NSSize, within visible: UpRect) -> NSSize {
        let bounds = visible.cg
        return NSSize(
            width: max(0, min(size.width, bounds.width - 2 * margin)),
            height: max(0, min(size.height, bounds.height - 2 * margin)))
    }

    /// Bounds in the wrong order — a screen narrower than its margins — pin to the lower one.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
