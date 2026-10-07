import AppKit
import CaptureModel
import os
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI

/// **What the lookup panel's window actually is, and what an ordinary click on it costs the reader.**
///
/// Every control on the lookup card is a control the reader clicks while they are mid-sentence in
/// another app. Nothing in this repository measured what that click does. `--history-report` asserts
/// `activatedTheApp == false` for the *drawer* — a surface the reader never clicks into — and the
/// panel, which is the surface they do, had no equivalent. Three separate claims rested on the gap:
///
/// - **That panel behaviour is applied at all.** `xiaolaiDictPanelBehaviour` used to set
///   `becomesKeyOnlyIfNeeded` `if let panel = window as? NSPanel`. **Answered 2026-09-25 by a
///   throwaway SwiftUI app: it is not one** — a `Window` scene is a `SwiftUI.AppKitWindow` under both
///   styles this app uses — so that line never ran and has been deleted. This report still reads the
///   class, because the spike was a stand-in and the app's own window is the thing that decides.
/// - **That the card can offer text selection.** `textSelection(.enabled)` needs the window to be
///   key. The translated answer already carries that modifier, so whether it works is a fact about
///   this window and not about a change anyone has to make first. The spike says `.plain` gives a
///   borderless window with `canBecomeKey` false, which would mean it cannot — this report is what
///   confirms it of the real panel rather than of a stand-in.
/// - **That a popup-based control is usable here.** The click-away monitor closes the panel on any
///   mouse-down outside `window.frame`, and a menu is another window. Whether the monitors fire at
///   all during `NSMenu` tracking decides whether the footer can hold a menu.
///
/// **What is measured and what is inferred.** The click is posted at the centre of the panel, over
/// the card's own text rather than over a button: activation and key status are properties of the
/// window, so a click anywhere inside it answers the question, and a click on the answer text cannot
/// set off a pin or a translation as a side effect. Where typing goes afterwards is read as the
/// frontmost application and `NSApp.isActive` rather than by synthesising a keystroke — an instrument
/// may not type into whatever app the reader left in front.
///
/// The menu is the instrument's own `NSMenu`, not a control from the product: what is in question is
/// whether the monitors see events during menu tracking, which is the mechanism SwiftUI's `Menu` sits
/// on top of. The residual risk is stated in the report rather than hidden — `menuKind` says which
/// kind of menu was tracked, so nobody reads this as having measured a SwiftUI `Menu`.
@MainActor
enum PanelReport {

    /// How long to wait for the panel to be listed by the compositor. Generous: the first lookup in a
    /// cold process pays for the XPC service starting.
    static let appearance: Duration = .seconds(20)
    /// How long to let a posted click be delivered and acted on before reading the state again.
    static let delivery: Duration = .seconds(2)
    /// How long the menu is left up before the click meant to dismiss it is posted.
    ///
    /// `nonisolated` because the thread that waits it out is not the main one — deliberately, since
    /// `NSMenu.popUp` blocks the main thread for the whole of tracking.
    nonisolated static let menuSettling: Duration = .milliseconds(400)
    /// How long a menu may stay up before tracking is cancelled from under it.
    ///
    /// **Not a settling time — a way out.** Nothing else in this instrument can end menu tracking:
    /// `popUp` holds the main thread, so `withDeadline` cannot fire. Generous against
    /// `menuSettling`, so a slow but working click is never cut off.
    static let menuTrackingBound: Duration = .seconds(8)
    /// How long the runloop is given after menu tracking ends, before the panel's survival is
    /// read. A dismissal is not synchronous with `popUp` returning.
    static let dismissalSettling: Duration = .milliseconds(400)
    /// How long the panel is given to stop resizing before its height is read. Long enough for the
    /// dictionaries, the memory strip and the sense to have arrived and grown it.
    static let contentSettling: Duration = .seconds(15)
    /// The whole report's own bound. An instrument sets its own deadline; the reader's budget is not
    /// the measurement's.
    static let budget: Duration = .seconds(60)

    /// The word this looks up, and the sentence it is looked up in. A real lookup through the real
    /// path, because a synthetic presentation would measure a card the product never draws — and the
    /// footer's controls only exist where a dictionary answered.
    static let term = "fine"
    static let sentence = "It was a fine piece of filmmaking, and the weather held."

    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        // **The window actions first, or this measures nothing.** They are captured by
        // `MenuBarLabel`'s `.task`, which runs after `applicationDidFinishLaunching` — and this is
        // scheduled from there. Without the wait the instrument drives the app before there is a
        // window to draw into: it used to read as a failure of the surface being measured, and once
        // `WindowActions` became loud it reads as a reported failure, which is better and still not
        // a working instrument. `--settings-report` always waited; these two never did.
        guard await WindowActions.shared.ready() else {
            _ = Instrument.write(["problem": "the window actions never arrived, so nothing could open"])
            return .failure
        }
        guard let bounded = try? await withDeadline(budget, { await measure(in: app) }) else {
            _ = Instrument.write(["problem": "the panel report exceeded its own \(budget) budget"])
            return .failure
        }
        return bounded
    }

    private static func measure(in app: XiaolaiDictApp) async -> CommandStatus {
        let range = (sentence as NSString).range(of: term)
        let selection = Selection(
            text: term, sentence: sentence,
            rangeInSentence: range.location == NSNotFound ? nil : range,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))

        // Who was in front before anything was shown. Everything below is compared against this: the
        // panel must not change it, and a click on the panel changing it is the finding.
        let frontBefore = frontmost()
        let activeBefore = NSApp.isActive
        // **Recorded, because a wait that was already satisfied measured nothing.** If the app
        // was active or the window key before the click, `settle` returns at once and
        // "afterClick" is sampled before delivery — a click whose effect is unobservable
        // reported as a click that changed nothing.
        let wasAlreadyActive = activeBefore

        // The app's own hover path, so the panel is filled by `LookupRunner` exactly as it is for a
        // reader — not by a presentation this file made up.
        // **What the reader's ledger held before this.** The lookup below goes in by the door
        // hover uses — deliberately, so the card measured is the card the product draws — and
        // that door records. An instrument that leaves fabricated TextEdit reading behind
        // changes the drawer, the suggestion ranking and every later measurement on this Mac.
        let ledgerBefore = await Self.newestLookup(in: app)
        defer { Task { await Self.removeLookups(after: ledgerBefore, in: app) } }

        app.lookUpHovered(selection, at: UpPoint(NSEvent.mouseLocation))

        let appeared = await Instrument.settle(until: appearance) {
            Instrument.isOnScreen(app.panelController.window)
        }
        guard appeared, let window = app.panelController.window else {
            _ = Instrument.write([
                "appeared": false,
                "problem": "the lookup panel was never listed by the compositor",
            ])
            return .failure
        }

        // **Read after the panel behaviour has had a chance to land, not the moment the compositor
        // lists the window.** `WindowAccessor` configures on a `DispatchQueue.main.async` and again in
        // `updateNSView`, so a window can be drawn before its level and collection behaviour are set —
        // and reading then reported `level: 0` for a panel the compositor was already listing at
        // layer 3. Measured here on 2026-09-25, by this report, against itself.
        //
        // Settling on the level the app sets is not the same as assuming it: `panelBehaviourApplied`
        // is false where it never arrives, and the raw values are reported either way.
        let behaved = await Instrument.settle(until: delivery) { window.level == .floating }
        // **And after the panel has stopped changing size.** It is a container that fills in — shown
        // before the dictionaries are asked, then grown as the entry, the memory strip and the sense
        // arrive — so a height read the moment it is listed is the height of "Looking up…". Measured
        // here at 73 pt against a card that ends up several times that.
        let (settled, movement) = await restingHeight(of: window, in: app)

        let identity = Self.identity(of: window, in: app, behaved: behaved,
                                     settled: settled, movement: movement)
        let beforeClick = Self.beforeClick(frontBefore: frontBefore, activeBefore: activeBefore,
                                           wasAlreadyActive: wasAlreadyActive)
        let afterClick = await Self.afterClick(on: window, in: app, frontBefore: frontBefore)
        let menu = await trackMenu(outside: window,
                                   panelStillUp: { Instrument.isOnScreen(app.panelController.window) })

        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "appeared": true,
            "term": term,
            "window": identity,
            "beforeClick": beforeClick,
            "afterClick": afterClick,
            "menu": menu,
        ]
        guard Instrument.write(report) else { return .failure }
        // Whether the *panel* behaved is the harness's assertion to make, not this process's exit
        // status — the same division `--history-report` makes for the backdrop. A non-zero exit here
        // means the measurement failed, never that the app did.
        return .success
    }

    /// **What this window is.** The whole first question, and it is one read.
    private static func identity(of window: NSWindow, in app: XiaolaiDictApp, behaved: Bool,
                                 settled: Bool, movement: String) -> [String: Any] {
        [
            "panelBehaviourApplied": behaved,
            "class": window.className,
            "isPanel": window is NSPanel,
            // The line in `xiaolaiDictPanelBehaviour` that only runs for an `NSPanel`. Reported as a
            // string so "not a panel, so never asked" cannot read as a measured `false`.
            "becomesKeyOnlyIfNeeded": (window as? NSPanel).map { "\($0.becomesKeyOnlyIfNeeded)" } ?? "notAPanel",
            "styleMask": window.styleMask.rawValue,
            "isNonactivatingPanel": window.styleMask.contains(.nonactivatingPanel),
            "level": window.level.rawValue,
            "collectionBehavior": window.collectionBehavior.rawValue,
            // Whether selection is even possible on this surface. A window that cannot become key
            // cannot hold a text selection, which settles the question without a drag.
            "canBecomeKey": window.canBecomeKey,
            "isKeyBeforeClick": window.isKeyWindow,
            // **Whether the reader can resize it by hand.** The controller kept a size per kind of
            // panel, remembered from `didEndLiveResizeNotification` — a notification only a reader's
            // drag posts. A borderless window has no edge to drag, so that memory could never be
            // written; this is the reading that says so rather than a deduction from the style mask.
            "resizableByHand": window.isResizable,
            // **The height, against the two numbers that give it meaning.** The window used to be the
            // opening default for every card — 240, with the whole footer below a fold the panel gave
            // no sign of having — because its frame is written by hand on open and on reuse. It is
            // sized from its content now, and these say whether that held: settled at a height that
            // is not the default and never past what the cap allows.
            //
            // **`fittingSize` is deliberately not among them.** Asked of the live hosting view it
            // answers 0 even after `layoutSubtreeIfNeeded` — a view that wants nothing and a view
            // nobody asked correctly look identical through it, and a 0 reported beside a real height
            // reads as a measurement. `PanelHeightTests` measures that number where it does work, on
            // a view built for the purpose.
            "windowHeight": window.frame.height,
            "windowSettled": settled,
            // Empty when it settled. What it did otherwise, so the failure can be read from here.
            "windowMovement": movement,
            "openingHeight": PanelWindow.openingHeight,
            // What the fit was computed from. A window of the wrong height and a window asked for the
            // wrong height look identical from outside, and they have different causes.
            "fitWanted": app.panelController.lastFit?.wanted ?? -1,
            "fitGiven": app.panelController.lastFit?.given ?? -1,
            "heightCeiling": PanelWindow.tallest,
        ]
    }

    /// **Before the click**, which is the state the reader is in while they read the answer.
    private static func beforeClick(frontBefore: String, activeBefore: Bool,
                                    wasAlreadyActive: Bool) -> [String: Any] {
        [
            "appWasActive": activeBefore,
            "appIsActive": NSApp.isActive,
            // **Whether this run could observe a change at all.** With the app already active
            // the after-click reading is not evidence either way, and saying so is the
            // difference between a measurement and a number.
            "couldObserveActivation": !wasAlreadyActive,
            "frontmostBefore": frontBefore,
            "frontmostNow": frontmost(),
            // The passing shape: showing the panel changed neither.
            "showingTookTheFront": frontmost() != frontBefore || (NSApp.isActive && !activeBefore),
        ]
    }

    /// **A click inside the panel**, at its centre, over the card's own text — and what it did.
    private static func afterClick(on window: NSWindow, in app: XiaolaiDictApp,
                                   frontBefore: String) async -> [String: Any] {
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let clicked = post(at: inside)
        _ = await Instrument.settle(until: delivery) { NSApp.isActive || window.isKeyWindow }
        return [
            "clickPosted": clicked,
            "appIsActive": NSApp.isActive,
            "isKeyWindow": window.isKeyWindow,
            "frontmost": frontmost(),
            // False is the passing value for both: a click on the card must not take the front, and
            // a click inside the panel must not dismiss it.
            "tookTheFront": frontmost() != frontBefore,
            "survivedTheClick": Instrument.isOnScreen(app.panelController.window),
        ]
    }

    /// Pops up a menu of this instrument's own, outside the panel's frame, and posts a click at its
    /// first item.
    ///
    /// **Why the click is posted from another thread.** `NSMenu.popUp` does not return until the menu
    /// closes: it runs a nested tracking runloop, and main-queue work is not reliably serviced inside
    /// it — which is the same reason the monitors' behaviour during tracking is the open question.
    /// Scheduling the click on the main queue would therefore deadlock the measurement it is part of.
    /// A placement, or why there is none. **Not `Result`**, whose failure has to be an `Error`
    /// and this one is a sentence for a report.
    private enum Either<Found> {
        case success(Found)
        case failure(String)
    }

    /// Where a menu can be put that the panel does not cover, and where to click it.
    private struct Placement {
        let anchor: NSPoint
        /// The point the click is actually posted at, in screen coordinates.
        let onItem: NSPoint
        /// The same point, flipped for CoreGraphics.
        let target: CGPoint
    }

    /// **Outside the panel's frame, and on screen.** The click-away predicate hit-tests that
    /// frame, so a menu inside it would measure nothing.
    private static func placement(outside window: NSWindow) -> Either<Placement> {
        guard let screen = window.screen ?? NSScreen.main else {
            return .failure("no screen to place a menu on")
        }
        // The screen's own top-left work area, which no panel placement can reach —
        // `PanelPlacement` offsets below and right of a pointer.
        let anchor = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 40)
        guard !window.frame.contains(anchor) else {
            return .failure("the panel covers the only anchor available")
        }
        // One item, so the first row sits just below the anchor. A few points in, to clear the
        // menu's own rounded corner.
        let onItem = NSPoint(x: anchor.x + 30, y: anchor.y - 14)
        // **The click, not only the anchor.** The anchor was checked against the panel and the
        // click is offset from it, so on a narrow screen the point actually clicked could land
        // inside the panel — which is the one place a click-away test must not click.
        guard !window.frame.contains(onItem) else {
            return .failure("the panel covers the point the menu would be clicked at")
        }
        // **Converted here, on the main actor, and handed over as a plain point.** The thread
        // that posts touches nothing but CoreGraphics: reading `NSScreen` from it would be
        // exactly the main-actor-isolated access Swift 6 refuses, and the conversion is the only
        // part that needs AppKit.
        guard let target = flipped(onItem) else {
            return .failure("no primary display to convert a click through")
        }
        return .success(Placement(anchor: anchor, onItem: onItem, target: target))
    }

    private static func trackMenu(
        outside window: NSWindow, panelStillUp: @escaping @MainActor () -> Bool
    ) async -> [String: Any] {
        let placed: Placement
        switch Self.placement(outside: window) {
        case .success(let found): placed = found
        case .failure(let why): return ["measured": false, "problem": why]
        }
        let (anchor, onItem, target) = (placed.anchor, placed.onItem, placed.target)

        let menu = NSMenu()
        let sentinel = MenuSentinel()
        let item = NSMenuItem(title: "panel-report", action: #selector(MenuSentinel.chosen), keyEquivalent: "")
        item.target = sentinel
        menu.addItem(item)

        let posted = OSAllocatedUnfairLock(initialState: false)
        // **Disarmed when tracking ends.** The thread slept and then clicked regardless, so a menu
        // that closed early — cancelled, or dismissed by something else — left a click landing on
        // whatever was underneath it, in whichever app that was.
        let tracking = OSAllocatedUnfairLock(initialState: true)
        defer { tracking.withLock { $0 = false } }
        let wait = menuSettling.milliseconds / 1000
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: wait)
            guard tracking.withLock({ $0 }) else { return }
            posted.withLock { $0 = Self.postClick(atFlipped: target) }
            // See `postClick`: what this records is that the events were created and posted, not
            // that anything received them.
        }
        // **The one deadline in this file that cannot be a deadline.** `popUp` blocks the main
        // thread for the whole of tracking, so the report's own `withDeadline` — which needs the
        // main actor to run — can never fire while a menu is up. Measured on a Mac with no
        // Accessibility grant: the dismissing click was refused, tracking never ended, and the
        // instrument sat there for as long as it was left, writing nothing. No report, no failure,
        // no exit: the worst of the three.
        //
        // A timer instead, in `.common` modes, which is what menu tracking pumps. It runs *during*
        // tracking and ends it whatever happened to the click.
        //
        // A delayed `perform` rather than a `Timer` with a closure: an `NSMenu` cannot be sent into
        // a `@Sendable` block, and the selector form needs no capture at all.
        let bail = MenuBail(menu: menu)
        bail.perform(#selector(MenuBail.cancel), with: nil,
                     afterDelay: menuTrackingBound.milliseconds / 1000, inModes: [.common])
        // The return value is kept: `popUp` answers whether it tracked at all, and a menu that
        // never came up would otherwise put the posted click onto whatever is at that corner of the
        // screen — a stray click reported as a measurement.
        let tracked = menu.popUp(positioning: nil, at: anchor, in: nil)
        MenuBail.cancelPreviousPerformRequests(withTarget: bail,
                                               selector: #selector(MenuBail.cancel), object: nil)

        // After tracking ends — **and after the runloop has had a turn**. A dismissal travels
        // through a monitor, SwiftUI and the compositor, none of which has run at the instant
        // `popUp` returns, so reading here reported "survived" for a panel that was closing.
        try? await Task.sleep(for: dismissalSettling)
        let survived = panelStillUp()
        // **A menu this cancelled measured nothing.** The click never landed, so whether the panel
        // is still up says nothing about the click-away monitors — and reporting it as a finding
        // would be reporting the absence of a permission as a fact about the surface.
        guard !bail.didFire else {
            return [
                "measured": false,
                // **What was observed, not a cause.** The first draft of this said the click
                // "needs Accessibility" — and the report's own `clickPosted` beside it said the
                // click was posted. An instrument that names a cause its own data contradicts is
                // worse than one that names none.
                "problem": "the menu was still up after \(menuTrackingBound) and tracking had to "
                    + "be cancelled; see clickPosted for whether the dismissing click was posted",
                "clickPosted": posted.withLock { $0 },
                // **`popUp` answers whether an item was chosen**, not whether tracking happened —
                // a menu that came up and was dismissed returns false. Named for what it is, and
                // **named the same on both branches**: this one said `menuItemChosen` while the
                // measured branch below said `menuTracked`, so the harness — reading the first
                // name — saw `None` on every successful measurement and failed the stage for a
                // menu that had tracked perfectly well.
                "menuTracked": tracked,
            ]
        }
        return [
            "measured": true,
            // Which kind of menu this was. A SwiftUI `Menu` is presented by an `NSMenu`, but it is
            // not this `NSMenu`, and the report must not be read as having measured one.
            "menuKind": "NSMenu.popUp",
            "menuTracked": tracked,
            "anchor": NSStringFromPoint(anchor),
            // **Where the click went, against where the menu ended up.** "itemChosen=false" with
            // a posted click is two different findings — a menu that did not open where it was
            // asked to, and a click that missed an item that was there — and they read
            // identically without both frames.
            "clickedAt": NSStringFromPoint(onItem),
            "menuFrame": menu.size == .zero ? "unsized" : NSStringFromSize(menu.size),
            "firstItemIsEnabled": menu.items.first?.isEnabled ?? false,
            "clickPosted": posted.withLock { $0 },
            "itemWasChosen": sentinel.wasChosen,
            // **The finding, either way.** True means a menu is usable in the panel's footer; false
            // means the click-away monitor dismissed the panel out from under the reader's own menu.
            "panelSurvivedTheMenuClick": survived,
        ]
    }

    /// Waits for the window to stop resizing, and reports whether it did.
    ///
    /// **False is a real answer**: a panel still growing when the deadline passes has not settled, and
    /// the height beside it is a snapshot of a moving thing rather than what the reader ends up with.
    private static func restingHeight(of window: NSWindow, in app: XiaolaiDictApp)
        async -> (settled: Bool, movement: String) {
        // **The answer first, then the stillness.** Waiting for the frame to hold still alone settles
        // on the waiting state, which is stable and short — 73 points of "Looking up…", measured.
        // `hasAnswered` is the *dictionary's* outcome; the memory strip and the sense mark arrive
        // after it and resize the card again. Waiting on it alone declared a panel settled that
        // had two more growths to come — which is why the stillness run below is what decides,
        // and this is only the point from which it is worth watching.
        guard await Instrument.settle(until: contentSettling, {
            app.panelModel.content?.hasAnswered == true
        }) else { return (false, "the card never answered") }
        var last = window.frame.height
        var still = 0
        /// Where the run of stillness began, so drift is measured against it rather than against
        /// the previous sample.
        var restingAt: CGFloat?
        // **What it did, not just that it would not stop.** "Still resizing after 271 pt" cannot be
        // diagnosed from another machine: a window creeping by two points and one oscillating
        // between two sizes are different defects and read identically. The distinct heights it
        // took, in order, are what tells them apart.
        var seen: [CGFloat] = [last]
        // **And what the fit was asking for while it moved.** A window chasing a target that keeps
        // changing and a window failing to reach a fixed target are different defects, and the
        // heights alone cannot tell them apart: one is the content, the other is the arithmetic.
        var fits: [String] = []
        let steps = Int(contentSettling.milliseconds / 50)
        for _ in 0..<steps {
            // **Cancellation ends the measurement.** `try?` swallowed it, so a cancelled report
            // counted its immediate returns as stillness — six of them in no time at all — and
            // declared a moving window settled, then went on posting synthetic clicks past its
            // own deadline.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return (false, "cancelled") }
            let now = window.frame.height
            if abs(now - last) >= 1 {
                seen.append(now)
                if let fit = app.panelController.lastFit {
                    let pair = "\(Int(fit.wanted))/\(Int(fit.given))"
                    if fits.last != pair { fits.append(pair) }
                }
            }
            // **Against the height it settled at, not the one before it.** Comparing only
            // consecutive samples accepted six 0.5-point steps as stillness while the window
            // moved three points — a drift no single comparison could see.
            if abs(now - last) < 1 {
                still += 1
                if let anchor = restingAt, abs(now - anchor) >= 1 { still = 1; restingAt = now }
                if restingAt == nil { restingAt = now }
            } else {
                still = 0
                restingAt = nil
            }
            last = now
            if still >= 6 { return (true, "") }
        }
        let shown = bounded(seen.map { "\(Int($0))" }, head: 6, tail: 4, separator: "→")
        let wantedGiven = bounded(fits, head: 4, tail: 4, separator: " ")
        return (false, "\(seen.count) distinct heights in \(contentSettling): \(shown); "
                + "wanted/given: \(wantedGiven)")
    }

    /// **Bounded: a run that changed three hundred times needs the shape, not the log.** One
    /// spelling, because two copies of head-ellipsis-tail with different limits are two places
    /// for the ellipsis to stop meaning "and more".
    private static func bounded(_ parts: [String], head: Int, tail: Int,
                                separator: String) -> String {
        guard parts.count > head + tail else { return parts.joined(separator: separator) }
        return parts.prefix(head).joined(separator: separator)
            + " … " + parts.suffix(tail).joined(separator: separator)
    }

    /// The newest lookup id, or nil where the ledger cannot be reached.
    private static func newestLookup(in app: XiaolaiDictApp) async -> Int? {
        guard let opening = app.recorder.store else { return nil }
        return try? await opening.value.newestLookupID()
    }

    /// Removes whatever this measurement added, and only that. **Not a general clean-up**: it
    /// deletes by id above a baseline this instrument took itself, so a lookup the reader made
    /// while it ran is out of range by construction.
    private static func removeLookups(after baseline: Int?, in app: XiaolaiDictApp) async {
        guard let baseline, let opening = app.recorder.store,
              let store = try? await opening.value else { return }
        try? await store.deleteLookups(after: baseline)
    }

    /// The frontmost application's bundle identifier, or its name where it has none.
    private static func frontmost() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier ?? app?.localizedName ?? "none"
    }

    /// A press and a release at one screen point, in Cocoa's coordinates.
    ///
    /// **`false` is a real answer and is reported as one.** Posting needs the Accessibility grant, and
    /// a run that could not post has measured nothing about clicking — which must not read as a click
    /// that changed nothing.
    /// **No button parameter**: the helper below posts a left click and nothing reads which kind
    /// was asked for, so accepting one was a promise this could not keep.
    private static func post(at point: NSPoint) -> Bool {
        guard let target = flipped(point) else { return false }
        return postClick(atFlipped: target)
    }

    /// Cocoa's coordinates to CoreGraphics'. **Through the *primary* screen's frame**, never
    /// `window.screen`'s: the global event space is anchored to the primary display, so a window on a
    /// second screen still converts through the first.
    private static func flipped(_ point: NSPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    /// The press and the release, and nothing else — no AppKit, so it can be called from the thread
    /// that has to click while the main one is inside menu tracking.
    nonisolated private static func postClick(atFlipped point: CGPoint) -> Bool {
        let button = CGMouseButton.ClickKind.leftMouse
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: source, mouseType: button.down,
                mouseCursorPosition: point, mouseButton: button.button),
              let up = CGEvent(
                mouseEventSource: source, mouseType: button.up,
                mouseCursorPosition: point, mouseButton: button.button)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Whether the menu item was actually chosen. Without it, a click that missed the item and a click
/// the monitors swallowed look the same — and they are opposite findings.
@MainActor
private final class MenuSentinel: NSObject {
    private(set) var wasChosen = false
    @objc func chosen() { wasChosen = true }
}

/// **Ends menu tracking when nothing else can.** `NSMenu.popUp` holds the main thread, so no
/// deadline the instrument sets for itself can fire while a menu is up; a delayed `perform` in
/// `.common` modes runs inside the tracking loop and is the one thing that reaches it.
///
/// `didFire` is what stops a cancelled menu being read as a measurement.
@MainActor
private final class MenuBail: NSObject {
    private let menu: NSMenu
    private(set) var didFire = false

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
    }

    @objc func cancel() {
        didFire = true
        menu.cancelTracking()
    }
}

extension CGMouseButton {
    /// The three events one click is made of, named together so a caller cannot pair a left-button
    /// down with a right-button up.
    enum ClickKind {
        case leftMouse

        var down: CGEventType { .leftMouseDown }
        var up: CGEventType { .leftMouseUp }
        var button: CGMouseButton { .left }
    }
}
