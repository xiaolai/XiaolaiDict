import AppKit
import Capture
import StudyKit
import StudyModels
import XiaolaiDictBase
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
    /// Begins and claims at once — for a request made at the panel, where nothing can overtake it.
    func newRequest() -> PanelTicket
    /// A number for a request that will claim the panel later — a hover, between the gesture and
    /// the word. Supersedes nothing. See `RequestSequence`.
    func begin() -> Int
    /// The panel for `request`, or nil when a later request has claimed it or it was closed since.
    func claim(_ request: Int) -> PanelTicket?
    func isCurrent(_ ticket: PanelTicket) -> Bool
    /// Shows the panel; answers whether it is on screen. `LookupRunner` stops on `false`, so a
    /// panel that could not be drawn never becomes a ledger row.
    ///
    /// `word` is where the looked-up word is on screen, where a capture knew it: the card is kept clear of it, now and
    /// as it grows (plan-card-refinements WI-2). Nil is today's pointer rule.
    @discardableResult
    func show(_ content: PanelContent, near pointer: UpPoint, protecting word: WordBounds?, for ticket: PanelTicket) -> Bool
    /// Replaces a shown panel's content without moving or resizing it. A panel the reader has
    /// dragged somewhere must not jump when its entry arrives.
    func update(_ content: PanelContent, for ticket: PanelTicket)
    /// Whether the compositor lists the panel as on screen for `ticket`, waiting a bounded moment
    /// for it to be drawn. **The only evidence the reader saw it** — `show` answers for the request.
    func seenOnScreen(_ ticket: PanelTicket) async -> Bool
}

extension LookupPanelPresenting {
    /// A panel with no word to keep clear — every caller but a lookup a capture located.
    @discardableResult
    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket) -> Bool {
        show(content, near: pointer, protecting: nil, for: ticket)
    }
}

/// A request for the panel. A newer request supersedes every older one, and closing the panel
/// supersedes them all: a result that arrives late is dropped, not shown over a newer one or
/// reopened after the reader dismissed it.
struct PanelTicket: Equatable {
    let number: Int
    /// **A replacement of the card on screen, where it is** — a followed suggestion's (audit of 2026-10-10). Its showing
    /// keeps the window where the reader has it, and a card the reader dragged off its word stays let go.
    var inPlace = false
}

/// What the panel is showing. A scene's content reads this; nothing hands a window a view.
@Observable
@MainActor
final class LookupPanelModel {
    var content: PanelContent?
    /// Per kind, so a panel of one kind does not inherit the minimum of another.
    var minimumSize: NSSize = PanelContent.Kind.lookup.minimumSize(for: .standard)
    /// **Which way, and how far, the content fit may grow the window** — away from the word the card keeps clear
    /// (plan-card-refinements WI-2; up as well as down, the owner's decision of 2026-10-09), nil for down to the screen's
    /// bottom, as before. Read by `fitsItsContent` through the environment.
    var growth: PanelGrowth?
    /// **The tail the card carries, pointing at its word** — nil for a card placed by the pointer. Read by the card's
    /// surface through the environment, and moved by every later fit so it keeps pointing at the word.
    var tail: CardTail?
    /// **Which outline the card drew** — written by its surface, read by the click-away test.
    @ObservationIgnored let drawn = DrawnCard()

    /// Moved by every `show`, so the scene can say which showing it has drawn.
    private(set) var generation = 0
    /// The newest generation the window has **drawn** — written by `RenderAcknowledger` from AppKit's
    /// display pass, never by the controller. A reused window is listed by the compositor
    /// before SwiftUI has drawn the next card on it, so "the window is on screen" alone took the last
    /// card's drawing as this one's (audit round 3, #17).
    private(set) var rendered = 0

    func present(_ content: PanelContent) -> Int {
        self.content = content
        generation += 1
        return generation
    }

    func acknowledgeRendered(_ generation: Int) { rendered = max(rendered, generation) }
}

/// The lookup panel: floats over the app being read — in its Space, even full screen — without
/// activating XiaolaiDict or taking keyboard focus, so typing stays where the reader left it.
///
/// ## What that costs, and why it is paid (recorded 2026-10-02)
///
/// **The panel never becomes key, so nothing on the card can be reached from the keyboard.** Its
/// scene is `.plain`, which gives a borderless window whose `canBecomeKey` is false (measured
/// 2026-09-25 by `--panel-report`). Escape closes it, through a claimed hot key; confirming a
/// meaning, choosing another, saving, discarding, copying, pinning, translating and explaining are
/// pointer-only. A reader who works from the keyboard can open the panel and close it, and
/// nothing between. This comment used to say "a click in the panel focuses it"; it never did.
///
/// It is a departure from the platform's keyboard guidance and it is deliberate. The alternative
/// to a window that cannot take the keyboard is a window that takes it — and this one appears
/// beside a word the reader hovered or selected, usually while their hands are on the keyboard in
/// another app. A panel that became key would swallow the next thing they typed.
///
/// **Giving the card's actions claimed hot keys, the way Escape has one, was considered and not
/// done.** A Carbon hot key is system-wide and exclusive: while it is held, the key does not reach
/// the app being read at all. Escape is a fair trade — the reader is dismissing something. Return
/// to confirm, or a letter to save, is not: a hover panel appears without the reader asking for
/// it mid-sentence, and for as long as it was up their editor would not receive that key. The
/// failure is silent and lands in somebody else's document, which is the one thing this panel is
/// built never to do.
///
/// What a keyboard reader has instead is the Library, a window they chose and which takes focus:
/// every reading is there, with the same confirm, choose, save and discard.
@MainActor
final class LookupPanelController: LookupPanelPresenting {
    let model = LookupPanelModel()
    /// Which request the panel belongs to — see `RequestSequence`, which holds the rule.
    private var requests = RequestSequence()
    private var shownKind: PanelContent.Kind?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
    private let escape: EscapeKey
    /// Held only while the panel is on screen — a monitor that outlived it would dismiss a panel
    /// that is not there and keep a closure alive for every lookup the reader ever made.
    private var clickAway: Any?
    /// The local half of the same watch. A global monitor is never offered its own application's
    /// events, so without this a click in Settings or the drawer left the panel up.
    private var clickAwayLocal: Any?
    /// The resize observer, kept so it can be **replaced** rather than added to. The window
    /// accessor's closure runs on every update of the view it is attached to, and the panel's body
    /// reads the model download's progress — so a 3 GB download registered a fresh observer a few
    /// hundred times, each one outliving its window and calling back for every resize after.
    ///
    /// **There used to be two.** The other watched `didEndLiveResizeNotification` to remember a size
    /// the reader had chosen by dragging, per kind of panel. The panel's window is borderless — style
    /// mask 0, and `isResizable` false, both measured by `--panel-report` on 2026-09-25 — so it has no
    /// edge to drag and that notification could never be posted. A memory nothing could write, feeding
    /// a placement nothing could vary: deleted rather than repaired, because there is no drag to
    /// remember and the window's height is the content's to decide now.
    private(set) var fitObserver: (any NSObjectProtocol)?
    /// The move observer, which tells a reader's drag from the controller's own moves. Replaced with `fitObserver`.
    private(set) var moveObserver: (any NSObjectProtocol)?
    /// Which window the two observers above are registered on, held weakly so a closed window is
    /// not kept alive by the bookkeeping that exists to avoid re-registering on it.
    private weak var watched: NSWindow?
    /// Pinned notes outlive the panel that made them, so they are owned here rather than by a view.
    let notes = PinnedNoteController()
    /// Where the last panel was put, so a note pinned from it lands beside it.
    private(set) var lastPointer = UpPoint(.zero)
    /// Where the scene should be placed, worked out before it opens. A scene cannot be handed a
    /// frame, so `defaultWindowPlacement` reads this back.
    /// The word the shown card keeps clear of, and the room it was given for that — nil where none was located. A
    /// followed suggestion is the same word on screen, so it is placed against it again.
    private(set) var lastWord: WordBounds?
    /// What the card is anchored on — its word, the side it went on and the room there — re-applied after every fit;
    /// nil for a card placed by the pointer, and once the reader has dragged the card off its word.
    private(set) var anchor: PanelPlacement.Anchor?
    /// The frame this controller last gave the window, and the last it saw — what tells the reader's drag from a move of
    /// its own (`PanelPlacement.isReadersDrag`).
    private var gaveFrame: NSRect?
    private var sawFrame: NSRect?
    private(set) var placement = NSRect(origin: .zero, size: PanelContent.Kind.lookup.defaultSize(for: .standard))
    /// The reader's text size, asked at each showing: the window opens as wide as the card is at
    /// that size. Set by the app once its appearance model exists; a test leaves it standard.
    var textSize: @MainActor () -> TextSize = { .standard }

    /// How the panel's window is opened and dismissed.
    ///
    /// **Injected, because it is a seam and was a global.** `WindowActions.shared` is filled in by
    /// a view's `.task`, so in a unit test it is never wired and `show` correctly refuses — which is
    /// right for the product and made three existing panel tests assert against a panel that had
    /// declined to open. A test hands in a pair that succeeds; the app hands in the real one.
    struct Windows: Sendable {
        var open: @MainActor (String) -> Bool
        var dismiss: @MainActor (String) -> Bool
        /// Whether the compositor lists the window as on screen — the only evidence it is drawn.
        var drawn: @MainActor (NSWindow?) -> Bool = { Instrument.isOnScreen($0) }

        static let shared = Windows(
            open: { WindowActions.shared.openWindow(id: $0) },
            dismiss: { WindowActions.shared.dismissWindow(id: $0) })
        /// For a test that is about the panel rather than about whether a window exists.
        static let alwaysOpen = Windows(open: { _ in true }, dismiss: { _ in true }, drawn: { _ in true })
    }

    private let windows: Windows

    init(hotkeys: HotkeyCenter = .shared, windows: Windows = .shared) {
        escape = EscapeKey(hotkeys: hotkeys)
        self.windows = windows
    }

    /// What the reader asked to study, as they ask for it. Set by the app, which owns the ledger.
    /// **With the request it belongs to.** The reader can tap a sense as soon as the entry is on
    /// screen, which is well before the lookup's own row exists — so a tap carries the request that
    /// made the panel, and the app holds it until that row is written rather than hanging it off
    /// whichever lookup happens to have been recorded last.
    var onStudySense: (@MainActor (SenseEncounter, Int) -> Void)?
    /// The reader asked to study the meaning on screen. Separate from meeting it.
    var onEnrolSense: (@MainActor (SenseEncounter, Int) -> Void)?
    /// The reader asked to keep the phrase on the card as a study card (ADR-0049) — under the request the
    /// card is, for the reason the two above carry one. Answers whether the ask was taken.
    var onCollectPhrase: (@MainActor (PhraseCollection, Int) -> Bool)?
    /// Settings, on its Dictionary pane. Set by the app, which owns the window and the discovery.
    var onOpenDictionarySettings: (@MainActor () -> Void)?
    /// The reader pressed "Look up “X”" on the card `Int` drew (plan-spelling-suggestion §3). Set by the app, which
    /// starts lookups — under the card's request, for the reason the study hooks carry one: the runner kept the
    /// suggestion under it, and a press filed under another card follows nothing.
    var onFollowSuggestion: (@MainActor (SpellingSuggestion, Int) -> Void)?
    /// The last two numbers the window fit was computed from: what the card's content wanted, and
    /// what its scroll view was given. Read by `--panel-report`, and by nothing else — the window's
    /// height can be seen from outside, but not what it was asked for.
    private(set) var lastFit: (wanted: CGFloat, given: CGFloat)?


    /// The window SwiftUI made for the panel's scene, or nil when it is not up.
    ///
    /// `NSApplication.shared`, never `NSApp`: the latter is implicitly unwrapped and nil in a
    /// process that has not made one, where it traps instead of answering "no window".
    ///
    /// **Not private: `--panel-report` reads it.** What this window *is* — its class, its style mask,
    /// whether it can become key — is the thing that report exists to establish, and it cannot be
    /// asserted from the source: `xiaolaiDictPanelBehaviour` applies panel behaviour only
    /// `if let panel = window as? NSPanel`, and whether a SwiftUI `Window` scene with
    /// `.windowStyle(.plain)` satisfies that has never been measured.
    var window: NSWindow? {
        // **By the scene's identifier and nothing else.** A second lookup by title stood here as a
        // fallback, and a title is localisable: in any translated build it matched nothing, quietly.
        XiaolaiDictScene.window(of: XiaolaiDictScene.lookupID)
    }

    func newRequest() -> PanelTicket { PanelTicket(number: requests.next()) }

    /// A request whose card replaces the one on screen in place (`PanelTicket.inPlace`).
    func newRequest(replacingInPlace: Bool) -> PanelTicket {
        PanelTicket(number: requests.next(), inPlace: replacingInPlace)
    }

    func begin() -> Int { requests.begin() }

    func claim(_ request: Int) -> PanelTicket? {
        requests.claim(request) ? PanelTicket(number: request) : nil
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { requests.isCurrent(ticket.number) }

    /// How long a shown panel is given to reach the compositor. A frame or two in practice; the
    /// bound is what stops a window that never draws from holding a lookup's record for ever.
    static let drawnWithin: Duration = .seconds(1)

    /// **Gives up at once on a ticket that is no longer current, or a caller that left** — a
    /// superseded or dismissed lookup has nothing to wait for, and polled out the full second.
    func seenOnScreen(_ ticket: PanelTicket) async -> Bool {
        switch await Poll.until(within: Self.drawnWithin, abandonIf: { !isCurrent(ticket) }, { isDrawn(ticket) }) {
        case .met: return true
        case .abandoned: return false
        case .timedOut: break
        }
        // **Out of time and still ours: put it away.** The lookup stops on `false`, and a panel left
        // armed behind it kept its content, its click monitors and the Escape claim — a window that
        // arrived late drew an abandoned loading card. Only this ticket's panel: a superseded check
        // returned above and must not close the lookup that replaced it.
        log.error("panel \(ticket.number, privacy: .public) never reached the compositor; closed")
        close()
        return false
    }

    /// Which request the panel was last shown for, and the generation that showing stamped.
    private var showing: (request: Int, generation: Int)?

    /// **Both halves of "the reader can see this card"**: the scene has rendered this showing's
    /// content, and the compositor lists the window. Either alone was taken for both — the compositor
    /// alone credited a reused window with a card it had not drawn yet.
    private func isDrawn(_ ticket: PanelTicket) -> Bool {
        guard let showing, showing.request == ticket.number, model.rendered >= showing.generation else { return false }
        return windows.drawn(window)
    }

    /// Shows the panel, and **says whether it is actually on screen**.
    ///
    /// The answer is not decoration: `LookupRunner` stops on `false`, so no lookup is recorded for a
    /// panel the reader never saw. Before this the window action was optional-chained, so a nil
    /// action made this a silent no-op while `isCurrent(ticket)` went on answering true — the whole
    /// lookup ran, a sense was resolved, and a ledger row was written for nothing.
    @discardableResult
    func show(_ content: PanelContent, near pointer: UpPoint, protecting word: WordBounds?, for ticket: PanelTicket) -> Bool {
        guard isCurrent(ticket) else { return false }
        lastPointer = pointer
        lastWord = word
        let kind = content.kind
        let screen = NSScreen.screens.first { $0.frame.contains(pointer.cg) } ?? NSScreen.main
        let size = textSize()
        let visible = UpRect(screen?.visibleFrame ?? NSRect(origin: .zero, size: kind.defaultSize(for: size)))
        // **A replacement in place keeps the reader's place** (audit of 2026-10-10): a followed suggestion replaces the
        // card on screen, and where the reader has let that card go of its word — dragged it aside — placing afresh against
        // the misspelling moved it back and pointed it again. Its frame and its let-go tail stay; an anchored card is
        // placed on the same word again, which puts it where it was.
        if ticket.inPlace, shownKind != nil, anchor == nil,
           let current = (window?.isVisible == true ? window?.frame : nil) ?? sawFrame {
            placement = current
            model.growth = nil
            gaveFrame = current
        } else {
            let placed = PanelPlacement.placed(
                for: kind.defaultSize(for: size), near: pointer, protecting: word, within: visible,
                chrome: CardChrome(textSize: size))
            placement = placed.frame
            // **Every later fit is held to the anchor** — the card centred on its word, on its side, growing away from
            // it, its tail following the word. Without a word there is no anchor, and both are the screen, as they were.
            anchor = placed.anchor
            model.growth = placed.growth
            model.tail = placed.tail
            gaveFrame = placed.frame
        }

        model.minimumSize = kind.minimumSize(for: size)
        showing = (ticket.number, model.present(content))
        shownKind = kind
        // The environment's real action, captured from the menu-bar label. An `EnvironmentValues()`
        // built on the spot is wired to nothing and silently opens no window at all.
        guard windows.open(XiaolaiDictScene.lookupID) else {
            // **Unwound, not left half-shown.** `shownKind` set with no window makes `update` accept
            // content for a panel that does not exist, and `closed()` would then be the only thing
            // able to clear it — from a close nothing will ask for.
            shownKind = nil
            showing = nil
            model.content = nil
            return false
        }
        // A scene already on screen is not re-placed, so a panel being reused is moved by hand.
        if let window, window.isVisible { window.setFrame(placement, display: true) }
        escape.claim { [weak self] in self?.close() }
        watchForClicksAway()
        return true
    }

    /// Fills in a panel already on screen. Same kind, so the minimum stays as it was, and **the
    /// placement is not touched**: the reader may have dragged the card aside while waiting — it
    /// moves by its background, see `LookupPanelSceneView` — and it must not jump back when its
    /// entry arrives. (It cannot be *resized*: the window is borderless and has no edge to drag.
    /// Its height follows its content.) Setting the content is all it takes — a scene is not
    /// re-placed because its content changed, which the hand-built panel had to be careful to
    /// preserve.
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
        _ = windows.dismiss(XiaolaiDictScene.lookupID)
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
    /// coordinates; where there is one, the window converts it. **`.zero` is a place, not a
    /// missing value** — the bottom-left corner of the primary display — so it is never replaced
    /// by the live pointer, which would bring back the dependence on where the pointer went next.
    ///
    /// **On the card, not merely in its window, where the card carries a tail** (the owner's decision of 2026-10-09): the
    /// strip beside the tail is the window's but not the card's, and a click there — which reaches the app beneath — is
    /// a click away. A card with no tail answers with its whole window, as before.
    private func closeIfClickWasAway(_ event: NSEvent) {
        guard let window, window.isVisible else { return }
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        guard !CardChrome(textSize: textSize()).holds(point, inWindow: window.frame, tail: model.tail,
                                                           compact: model.drawn.compact) else { return }
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
        showing = nil
        model.content = nil
        requests.close()
        escape.release()
        stopWatchingForClicksAway()
        // The window this watched has gone with the panel. Left registered, the observer holds the
        // closed window alive and waits for a resize that cannot come.
        stopWatchingForResize()
        anchor = nil
        model.tail = nil
        model.growth = nil
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
        if let watched, watched === window, fitObserver != nil { return }
        // Teardown first, then record: `stopWatchingForResize` clears `watched`, so assigning
        // before it left the guard above permanently unable to fire. The suite did not catch that
        // — it asserted the two registrations differ, which an inert guard satisfies — so the
        // assertion changed with the contract.
        stopWatchingForResize()
        watched = window
        fitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated {
                self?.keepWhollyOnScreen(window)
                self?.sawFrame = window.frame
            }
        }
        // **A move the reader makes lets go of the word**: a card dragged aside keeps no tail pointing at a word it has
        // left, and is not pulled back to the word by the next fit (WI-2 held it to the room whatever the reader did).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { self?.windowMoved(window, buttonDown: NSEvent.pressedMouseButtons & 1 != 0) }
        }
    }

    /// The window moved: the reader's drag releases the anchor, and any move is remembered as the last frame seen.
    func windowMoved(_ window: NSWindow, buttonDown: Bool) {
        defer { sawFrame = window.frame }
        guard anchor != nil, let sawFrame,
              PanelPlacement.isReadersDrag(from: sawFrame, to: window.frame, ours: gaveFrame, buttonDown: buttonDown)
        else { return }
        releaseAnchor()
    }

    /// **The card is the reader's now**: its tail stops pointing, keeping its strip so the card does not jump, and it
    /// grows down to the screen as a card placed by the pointer does.
    func releaseAnchor() {
        anchor = nil
        model.tail = model.tail?.released
        model.growth = nil
    }

    /// Puts a window the **content** resized back onto the screen it is on.
    ///
    /// `fitsItsContent(upTo:)` grows the window when the entry fills in and again when the reader
    /// opens the other senses — while `show()` placed it once, against the opening size, and
    /// `update()` deliberately does not re-place it. A lookup near the bottom of the display
    /// therefore drew its sense list past the edge.
    ///
    /// **This used to credit `.windowResizability(.contentSize)` with the growing, and that was not
    /// true.** The scene has always carried it and the window was the opening height for every card —
    /// 398 × 240, measured three runs — because `show()` writes the frame by hand and a frame set by
    /// hand is not one SwiftUI revisits. The fit is what grows it now; this still has to put the
    /// result back on the screen, and the two agree because the fit never asks for more than
    /// `visibleFrame.minY` allows.
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
    ///
    /// **An anchored card is re-anchored instead** (the owner's decision of 2026-10-09): centred on its word again at
    /// whatever width the content gave it, held to its side's room, the edge nearest the word kept, and its tail moved to
    /// the word's middle.
    func keepWhollyOnScreen(_ window: NSWindow) {
        guard !window.inLiveResize else { return }
        if let anchor {
            let placed = anchor.placed(window.frame)
            if model.tail != placed.tail { model.tail = placed.tail }
            guard placed.frame != window.frame else { return }
            gaveFrame = placed.frame
            window.setFrame(placed.frame, display: true)
            return
        }
        guard let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(lastPointer.cg) })
                ?? NSScreen.main
        else { return }
        let fitted = PanelPlacement.fitted(window.frame, within: UpRect(screen.visibleFrame))
        guard fitted != window.frame else { return }
        gaveFrame = fitted
        window.setFrame(fitted, display: true)
    }

    func recordFit(wanted: CGFloat, given: CGFloat) { lastFit = (wanted, given) }

    func stopWatchingForResize() {
        // An observer left registered holds the closed window alive and waits for a resize that
        // cannot come.
        if let fitObserver { NotificationCenter.default.removeObserver(fitObserver) }
        fitObserver = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
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

}

/// The lookup panel's scene content.
struct LookupPanelSceneView: View {
    let controller: LookupPanelController
    let recorder: LookupRecorder?
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
                // **Nothing is stacked under the card.** The row that says whether the reading was
                // saved used to be a sibling here, below `PanelView` — and the window is clear, so
                // it was drawn on whatever app was behind (measured 2026-10-01: black at alpha 60
                // over the Library, near-white over nothing in a dark appearance). The card draws
                // it now, inside its own surface; what it needs still arrives through the
                // environment below.
                PanelView(content: content)
                    .environment(\.panelGrowth, model.growth)
                    .environment(\.panelTail, model.tail)
                    .environment(\.drawnCard, model.drawn)
                    .modifier(LookupCardWiring(
                        request: content.request, recorder: recorder, controller: controller,
                        translation: translation(), explainer: explainer()))
                    // **What this window has drawn, said by AppKit's display pass** — see
                    // `RenderAcknowledger`; the controller's "seen" needs it and the compositor's listing.
                    .background(alignment: .topLeading) {
                        RenderAcknowledger(generation: model.generation) { model.acknowledgeRendered($0) }
                    }
            }
        }
        .frame(minWidth: model.minimumSize.width)
        .xiaolaiDictPanelBehaviour(transient: true) { window in
            // No chrome and no background of its own: the rounded card is the whole thing the
            // reader sees, and the shadow needs somewhere to fall.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // **The card can be pushed aside.** It is placed beside the pointer, which is beside
            // the word — so it can land on the sentence being read, and with style mask 0 there
            // was no way to move it. Two comments in this file already spoke of a panel "the
            // reader has dragged"; nothing let them.
            //
            // It does not fight the click-away dismissal: that closes the panel for a click
            // *outside* its frame, and a drag begins inside it. Nor the card's controls: a button
            // takes its own mouse-down, and only the paper between them drags.
            window.isMovableByWindowBackground = true
            controller.watchForResize(of: window)
        }
        // The reader closing the window is as final as Escape: whatever is still arriving for this
        // lookup is stale.
        .onDisappear { controller.closed() }
    }
}
/// **What the card needs from the app, kept out of the scene's body**: the reading's status and its
/// actions, pinning, studying and enrolling — each filed under **the request this card is**, not the
/// one the panel is on. `newRequest()` moves the counter when the next lookup begins, before its
/// selection has been read, so a tap on the card still in front of the reader was being filed under
/// a lookup that had not happened.
private struct LookupCardWiring: ViewModifier {
    let request: Int?
    let recorder: LookupRecorder?
    let controller: LookupPanelController
    let translation: TranslationActions
    let explainer: ExplanationActions

    func body(content: Content) -> some View {
        content
            .onChange(of: LedgerChanges.shared.revision) { _, _ in
                if let request { Task { await recorder?.refreshStatus(request: request) } }
            }
            .environment(\.lookupKeepStatus, request.flatMap { recorder?.states[$0] })
            .environment(\.lookupKeepAction) { action in
                guard let request else { return }
                switch action {
                case .retry: recorder?.retry(request: request)
                case .discard: recorder?.discard(request: request)
                case .undo: recorder?.undoDiscard(request: request)
                }
            }
            // The close button takes the same path as Escape and a click outside the card.
            .environment(\.closeLookup) { [controller] in controller.close() }
            .environment(\.pinNote) { [controller] note in
                controller.notes.pin(note, near: controller.lastPointer)
            }
            .environment(\.studySense) { [controller] encounter in
                guard let request else { return }
                controller.onStudySense?(encounter, request)
            }
            // The same request discipline, for the same reason: an enrollment filed under the lookup
            // that happened to be recorded last is a card about another word.
            .environment(\.enrolSense) { [controller] encounter in
                guard let request else { return }
                controller.onEnrolSense?(encounter, request)
            }
            // **And a phrase saved as a card**, filed under this card's request. Unwired, it is loud and
            // answers false, so the card says the save did not happen rather than taking the press.
            .environment(\.collectPhrase) { [controller] phrase in
                guard let request, let collect = controller.onCollectPhrase else {
                    Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
                        .fault("phrase: Save This Phrase reached a panel with no request or no app hook")
                    return false
                }
                return collect(phrase, request)
            }
            .environment(\.phraseCollectStatuses, request.flatMap { recorder?.phraseStates[$0] } ?? [:])
            // **"Look up “X”", under this card's request.** Unwired, it is loud: a press that reaches nothing is a
            // broken switch.
            .environment(\.followSuggestion) { [controller] suggestion in
                guard let request, let follow = controller.onFollowSuggestion else {
                    Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
                        .fault("spelling: a suggestion was pressed on a panel with no request or no app hook")
                    return
                }
                follow(suggestion, request)
            }
            // The one window the panel may bring forward: a window the reader chose. The app's own
            // action, so the dictionary discovery that pane depends on is started by the same code
            // path every other route uses.
            .environment(\.openDictionarySettings) { [controller] in controller.onOpenDictionarySettings?() }
            .environment(\.reportPanelFit) { [controller] wanted, given in
                controller.recordFit(wanted: wanted, given: given)
            }
            .environment(\.translation, translation)
            .environment(\.explainer, explainer)
    }
}

/// One surface's claim on Escape, held only while that surface shows.
///
/// A hot key rather than a key monitor: a global monitor cannot consume the press — the app being
/// read gets it too — and without Accessibility it never hears it.
@MainActor
final class EscapeKey {
    /// Kept, though only the stack is used: the stack refers to its centre without owning it, so
    /// something has to keep the centre alive for as long as this claim can be made.
    private let hotkeys: HotkeyCenter
    private let stack: EscapeStack
    private var entry: EscapeStack.Entry?

    /// **A place in the centre's one Escape stack, not a registration of its own.** Each surface
    /// used to register Escape for itself; the second was refused as a duplicate, and the panel lost
    /// Escape whenever the drawer was open — see `EscapeStack`.
    init(hotkeys: HotkeyCenter) {
        self.hotkeys = hotkeys
        stack = hotkeys.escape
    }

    /// Whether Escape reaches this surface: it is in the stack, and the stack holds the key.
    var isHeld: Bool { entry != nil && stack.isClaimed }

    /// Called every time the surface is shown. A surface already waiting moves to the top, so
    /// Escape dismisses whichever was shown last.
    func claim(_ action: @escaping @MainActor () -> Void) {
        if let entry, stack.contains(entry) {
            stack.raise(entry)
        } else {
            entry = stack.push(action)
        }
    }

    func release() {
        if let entry { stack.pop(entry) }
        entry = nil
    }

    isolated deinit {
        if let entry { stack.pop(entry) }
    }
}

/// Where the panel goes: below and to the right of the pointer, and wholly on the screen — shrunk
/// first when the screen is smaller than the panel, so no clamp can push it off an edge.
enum PanelPlacement {
    /// The gap kept between the panel and the screen's edge.
    static let margin: CGFloat = 8
    /// How far right of the pointer the panel's left edge sits — clear of the cursor's own bitmap
    /// without putting the card somewhere the eye has to travel to.
    static let pointerGap = NSSize(width: 12, height: 24)

    /// Answers a bare `NSRect` because its one caller hands it straight to `NSPanel.setFrame`.
    static func frame(for size: NSSize, near pointer: UpPoint, within visible: UpRect) -> NSRect {
        let pointer = pointer.cg
        // **Shrinking belongs to `fitted` alone.** This used to shrink first and then call `fitted`,
        // which shrank again — the same normalisation owned in two places, where a change to one is
        // a silent divergence. Handing over the rectangle the pointer asks for, unshrunk, works
        // because `fitted` anchors by the top edge: whatever height survives, the panel's top stays
        // at `pointer.y - pointerGap.height`. That is the case which makes the top anchor
        // observable, and there was none when it was written.
        let wanted = NSRect(
            origin: NSPoint(x: pointer.x + pointerGap.width,
                            y: pointer.y - pointerGap.height - size.height),
            size: size)
        return fitted(wanted, within: visible)
    }

    /// The gap kept between the card and the word it protects.
    static let wordGap: CGFloat = 4

    /// **Where the card goes, and what every later fit is held to** (plan-card-refinements WI-2; anchored on the word
    /// by the owner's decision of 2026-10-09).
    struct Placed: Equatable {
        let frame: NSRect
        /// The screen, or the side of the word the card was put on. `fitted(_:within:)` against it keeps the card
        /// there: its margins land the window's edge exactly `wordGap` from the word.
        let room: UpRect
        /// Which way, and how far, the content may grow the window: away from the word. Nil where no word is
        /// protected, which leaves the fit as it was — down, to the screen's bottom.
        let growth: PanelGrowth?
        /// The tail at the word's middle; nil with no word.
        let tail: CardTail?
        /// What every later fit re-applies; nil with no word.
        let anchor: Anchor?
    }

    /// **With the word's rectangle the card is anchored on it** — centred across it, below it where it fits and above
    /// where it does not (the larger side, shrunk, where neither does, so it scrolls rather than covers), its tail at the
    /// word's middle. **No rectangle is the pointer's rule, bit for bit, and no tail.**
    static func placed(for size: NSSize, near pointer: UpPoint, protecting word: WordBounds?, within visible: UpRect,
                       chrome: CardChrome) -> Placed {
        guard let word else {
            return Placed(frame: frame(for: size, near: pointer, within: visible), room: visible, growth: nil, tail: nil,
                          anchor: nil)
        }
        let screen = visible.cg
        let box = word.rect.cg
        // The window's edge may come no nearer the word than the gap; the room's edge is one margin further, because
        // `fitted` keeps a margin inside whatever room it is given.
        let belowTop = min(screen.maxY, box.minY - wordGap + margin)
        let aboveBottom = max(screen.minY, box.maxY + wordGap - margin)
        let below = UpRect(x: screen.minX, y: screen.minY, width: screen.width, height: max(0, belowTop - screen.minY))
        let above = UpRect(x: screen.minX, y: aboveBottom, width: screen.width, height: max(0, screen.maxY - aboveBottom))
        let belowSpace = below.cg.height - margin - margin
        let aboveSpace = above.cg.height - margin - margin
        let goesBelow = belowSpace >= size.height || (aboveSpace < size.height && belowSpace >= aboveSpace)
        let anchor = Anchor(word: word.rect, room: goesBelow ? below : above, edge: goesBelow ? .top : .bottom,
                            chrome: chrome)
        // Only the size is given: `Anchor.placed` puts the edge nearest the word at the word's gap and centres it.
        return anchor.placed(NSRect(origin: .zero, size: size))
    }

    /// **A card anchored on its word** — which word, the side it went on and the room there — so every later fit can put
    /// the card back on it: the content growing it, the content widening it, the screen clamp.
    struct Anchor: Equatable {
        let word: UpRect
        let room: UpRect
        /// The card's edge that faces the word, and so the one its tail leaves from.
        let edge: CardTail.Edge
        let chrome: CardChrome

        /// `frame`, anchored: no larger than the room; across, the card's middle on the word's as far as the room
        /// allows; up and down, **the edge nearest the word at the room's edge by the word** — the word's gap, or the
        /// screen's margin where the screen ends first — whatever the frame's own position; the tail at the word's
        /// middle, clear of the card's corners. A fixed point — applying it to its own answer changes nothing — so a
        /// resize it causes asks again and stops.
        ///
        /// **Only the frame's size is read, never its position.** Holding the frame's own edge to the room let any
        /// resize that kept the *far* edge carry the near one off the word while staying inside the room: measured on
        /// the E2E Mac at the huge text size, a resize made by neither the fit nor this kept a card's top as it went
        /// from 906 to 798 and left its tail 108 points above the word (2026-10-12).
        func placed(_ frame: NSRect) -> Placed {
            let bounds = room.cg
            let size = shrunk(frame.size, within: room)
            let insets = chrome.insets(tail: CardTail(edge: edge, tip: nil))
            let card = max(0, size.width - insets.leading - insets.trailing)
            let middle = word.cg.midX
            let x = clamp(middle - card / 2 - insets.leading, bounds.minX + margin, bounds.maxX - margin - size.width)
            // `max`: a room shorter than its margins pins to the lower bound, as `clamp` does.
            let lowest = bounds.minY + margin, highest = bounds.maxY - margin - size.height
            let y = edge == .top ? max(lowest, highest) : lowest
            let growth: PanelGrowth = edge == .top
                ? .down(lowestBottom: bounds.minY + margin) : .up(highestTop: bounds.maxY - margin)
            return Placed(
                frame: NSRect(x: x, y: y, width: size.width, height: size.height), room: room, growth: growth,
                tail: CardTail(edge: edge, tip: chrome.tip(at: middle - x - insets.leading, cardWidth: card)), anchor: self)
        }
    }

    /// **Whether a move is the reader dragging the card** — the mouse button down, the size unchanged, and not a frame
    /// this controller gave the window. Its own moves resize, or land exactly where it put them.
    static func isReadersDrag(from before: NSRect, to after: NSRect, ours: NSRect?, buttonDown: Bool) -> Bool {
        buttonDown && before.size == after.size && before.origin != after.origin && after != ours
    }

    /// The same shrink-then-clamp, applied to a frame that **already exists** — a window the
    /// content has since resized.
    ///
    /// `frame(for:near:within:)` runs once, at `show()`, against a size chosen before the content
    /// existed. `fitsItsContent(upTo:)` then grows the window when the entry fills in and again when
    /// the reader opens the other senses — not SwiftUI, see `watchForResize` — and nothing put it
    /// back on the screen: a lookup near the bottom of the display drew its sense list past the edge.
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
            width: max(0, min(size.width, bounds.width - margin - margin)),
            height: max(0, min(size.height, bounds.height - margin - margin)))
    }

    /// Bounds in the wrong order — a screen narrower than its margins — pin to the lower one.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
