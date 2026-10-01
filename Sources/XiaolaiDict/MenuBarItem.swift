import AppKit
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// **The menu bar icon: left click opens the reading history, right click opens the menu.**
///
/// The history is the surface a reader comes back to, and it sat two clicks away behind a menu
/// whose other items are things they set once.
///
/// **`MenuBarExtra` cannot do this, and the reason is not a missing API to find.** Measured
/// 2026-10-01 against the button SwiftUI makes: `menu`, `target`, `action` and `cell.menu` are all
/// nil, and its responder chain ends at `NSStatusBarWindow` — SwiftUI drives the item privately, so
/// there is nothing public to take over. Two attempts went that way first: one saved the button's
/// action to forward a right click to, and found none; one swallowed left clicks with a local event
/// monitor, which a status item's menu opens before rather than after.
///
/// So the item is this app's own, which is what `other-app/MacLibrary/StatusBarController.swift` does
/// and the shape this is modelled on: keep `statusItem.menu` **nil** so a click reaches an action
/// at all, and attach the menu for the length of one right click.
///
/// **`MenuBarExtra` stays in the scene, uninserted.** `MenuBarLabel`'s `.task` is where
/// `WindowActions.shared` is captured — the panel, the drawer and Settings all open through it —
/// and it is the only view in this app that lives as long as the process. Measured: with
/// `isInserted: false` the label still mounts and the capture still happens, so the scene can keep
/// doing that one job while showing nothing.
///
/// **The drawer is this item's expanded interface, and AppKit is told so** (macOS 27,
/// `NSStatusItemExpandedInterfaceDelegate`). The contract in `NSStatusItem.h`: AppKit begins a
/// session and the delegate shows its window; AppKit ends it and the delegate closes the window;
/// when the app closes the window for a reason of its own, it calls `cancel()` on the session. There
/// is **no call that begins a session** — only AppKit starts one — so the drawer can also be open
/// with none, and then this type highlights the button itself.
///
/// What a throwaway status item measured on 2026-10-02 (macOS 27.0.1, screen locked, so no real
/// pointer): with the delegate set, `performClick` and an Accessibility press still send the
/// button's action and begin **no** session. So the action stays, and it is the route VoiceOver's
/// default press takes. What a real click or a keyboard walk along the menu bar does was not
/// measurable there; `StatusItemClick` is written to be right whichever of the two AppKit does.
@MainActor
// `@preconcurrency`: the header does not mark the delegate protocol main-actor, and AppKit calls it
// from the main thread's event handling like every other status item callout — the annotation turns
// that assumption into a check at the call rather than a silence.
final class MenuBarItem: NSObject, NSMenuDelegate, @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    /// Where AppKit keeps this item's position and visibility. Named, because the name AppKit
    /// chooses for itself is positional (`Item-0`) and would be inherited by whatever item a later
    /// version created first.
    static let autosaveName = "XiaolaiDictMenuBarItem"
    /// The reader's "Show in menu bar" setting, in the app's own suite — `MenuBarIconSetting`,
    /// which Settings writes. Absent means shown.
    static let visibilityKey = MenuBarIconSetting.key

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "menubar")
    private let app: XiaolaiDictApp
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    /// The click during which a session began or ended, so the button's action for the *same*
    /// click does not undo it. See `StatusItemClick`.
    private var clickTheSessionHandled: Int?
    private var visibilityObservation: NSKeyValueObservation?
    private var defaultsObserver: (any NSObjectProtocol)?

    init(app: XiaolaiDictApp) {
        self.app = app
        super.init()
        menu.delegate = self
    }

    /// The owned button's current bounds in AppKit screen points.
    var screenFrame: CGRect? { Self.screenFrame(of: statusItem?.button) }

    static func screenFrame(of button: NSView?) -> CGRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = Self.autosaveName
        // **The reader may take the icon out**, by dragging it off the menu bar. `NSStatusItem.h`
        // makes that the app's responsibility to undo, and there are two ways back: the Show in
        // Menu Bar setting, and opening the app again, which shows the Library
        // (`applicationShouldHandleReopen`) — from where Settings is ⌘, away.
        item.behavior = .removalAllowed
        if let image = XiaolaiDictApp.menuBarImage() {
            item.button?.image = image
        } else {
            // No image at all is still no reason to show nothing.
            item.button?.title = "XiaolaiDict"
        }
        item.button?.setAccessibilityTitle(
            String(localized: "XiaolaiDict", comment: "The menu bar icon, for VoiceOver"))
        // **No menu on the item**, which is what makes the action below run at all: AppKit pops a
        // status item's menu itself on mouse-down and never calls the button's action.
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(clicked)
        // **Up, not down**: `performClick` runs a menu tracking loop, and starting one from inside
        // a mouse-down leaves the button waiting for an up the loop has already taken.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.expandedInterfaceDelegate = self
        offerBothSurfacesToAssistiveTechnology(on: item.button)
        describeTheIcon()
        followTheVisibilitySetting(of: item)
        log.notice("menu bar: left click opens the reading history, right click opens the menu")
    }

    // MARK: - Whether it is shown

    /// Whether the reader wants the icon. **Absent is yes** — a reader who has never seen the
    /// setting has an icon.
    static func showsIcon(in defaults: UserDefaults) -> Bool {
        MenuBarIconSetting(defaults: defaults).load()
    }

    /// **Both directions, and each only when it differs** — so the two observers cannot chase each
    /// other. The setting moves the item; the reader dragging the item out of the menu bar moves
    /// the setting, so the toggle in Settings never says "shown" over an icon that is gone.
    private func followTheVisibilitySetting(of item: NSStatusItem) {
        let defaults = app.preferences
        let wanted = Self.showsIcon(in: defaults)
        if item.isVisible != wanted { item.isVisible = wanted }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheVisibilitySetting() }
        }
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.recordTheVisibility() }
        }
    }

    private func applyTheVisibilitySetting() {
        guard let statusItem else { return }
        let wanted = Self.showsIcon(in: app.preferences)
        guard statusItem.isVisible != wanted else { return }
        statusItem.isVisible = wanted
        log.notice("menu bar: the icon is now \(wanted ? "shown" : "hidden", privacy: .public) by the setting")
    }

    private func recordTheVisibility() {
        guard let statusItem else { return }
        let shown = statusItem.isVisible
        guard Self.showsIcon(in: app.preferences) != shown else { return }
        // Through the settings model, which writes the key: the toggle in an open Settings window
        // is drawn from the model, and a write that went round it would leave the toggle saying
        // "shown" over an icon the reader had just dragged away.
        app.settings.showsMenuBarIcon = shown
        log.notice("menu bar: the reader \(shown ? "restored" : "removed", privacy: .public) the icon; the setting follows")
    }

    // MARK: - What the icon says about itself

    /// **The tooltip, which is now the only place outside Settings that names the lookup shortcut.**
    ///
    /// `Look Up Selection    ⌃⌥D` was this menu's first item, and it did two jobs: it offered a
    /// click almost nobody used — the shortcut is the way a reader looks a selection up — and it
    /// *named the combination that is registered*. Only the second job was load-bearing, so it
    /// moved here, where a reader finds it by resting the pointer on the icon rather than by
    /// opening a menu, and where the end-to-end harness can still read it (`menu-click --describe`).
    ///
    /// **Observed, not written once at launch.** Standing the hot key down for the settings field
    /// and putting it back afterwards is exactly what this witness exists to catch, and a tooltip
    /// assigned in `install()` would go on naming a shortcut that stopped working. The `onChange`
    /// handler runs *before* the change lands, so the re-read is a hop later, and re-arming the
    /// tracking is this method calling itself.
    private func describeTheIcon() {
        withObservationTracking {
            statusItem?.button?.toolTip = Self.description(ofShortcut: app.shortcuts.label)
        } onChange: { [weak self] in
            Task { @MainActor in self?.describeTheIcon() }
        }
    }

    /// Given the label rather than reading it, so both branches are a test rather than a running
    /// status bar. Nil is the registrar's answer for "nothing is registered" — including while the
    /// reader has the settings field armed, which is true and not a failure.
    ///
    /// **It names both clicks as well as the shortcut** (audit M3, 2026-10-02). The menu holds
    /// Settings and Quit and sits behind a right click nothing on screen announced; the first click
    /// shows a history with no route to either. The shortcut keeps the words either side of it —
    /// `press … to look up` — because the end-to-end `shortcut` stage reads the combination back
    /// out from between them, and `MenuBarItemTests` holds that pattern against this sentence.
    static func description(ofShortcut label: String?) -> String {
        guard let label else {
            return String(localized: """
                XiaolaiDict — click for Reading History, right-click for the menu. \
                No lookup shortcut is registered.
                """, comment: "The menu bar icon's tooltip when no lookup shortcut is registered")
        }
        return String(localized: """
            XiaolaiDict — click for Reading History, right-click for the menu, \
            press \(label) to look up the selection
            """, comment: "The menu bar icon's tooltip, naming both clicks and the registered lookup shortcut")
    }

    // MARK: - Clicks, and the session AppKit runs for the drawer

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let handled = clickTheSessionHandled != nil
            && clickTheSessionHandled == StatusItemClick.number(of: event)
        switch StatusItemClick.route(
            isSecondary: StatusItemClick.isSecondary(event), handledBySession: handled
        ) {
        case .nothing: break
        case .menu: showMenu()
        // **Shows, never toggles** — the owner's decision in ab9cb7e: a repeated click on the icon
        // keeps the history open. `showHistory` is idempotent, so the second click is a no-op.
        case .showHistory: app.showHistory()
        }
    }

    /// Attached for this one showing only, so the next left click is ours again.
    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// AppKit began showing this item's interface: a click, or the keyboard walking the menu bar.
    ///
    /// **A right click and a keyboard arrival get the menu, not the drawer.** The right click is
    /// the item's own rule. The keyboard is a judgement: the drawer is a `.plain` window, which
    /// cannot become key (`canBecomeKey` false, measured 2026-09-25) and must not activate the
    /// app, so a reader who arrived by keyboard would be shown cards no key can reach. The menu
    /// takes arrow keys and Return, and its Library item opens the same history in a window that
    /// does take the keyboard. Either way the session is cancelled, which the contract allows for
    /// "other user action", and on the next turn rather than inside AppKit's own callout.
    func statusItem(
        _ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
        let event = NSApp.currentEvent
        clickTheSessionHandled = StatusItemClick.number(of: event)
        guard StatusItemClick.sessionShowsHistory(
            isSecondary: StatusItemClick.isSecondary(event), isKeyboard: StatusItemClick.isKeyboard(event))
        else {
            log.notice("menu bar: a session began by right click or keyboard; showing the menu instead")
            DispatchQueue.main.async { [weak self] in
                expandedInterfaceSession.cancel()
                self?.showMenu()
            }
            return
        }
        app.showHistory()
    }

    /// AppKit ended the session. **The drawer closes with it — unless what ended it was a plain
    /// click on the icon itself.** A menu bar extra's second click closes its interface, and AppKit
    /// ends the session for it; this app's rule is that a repeated click keeps the history open
    /// (ab9cb7e). So for that one cause the drawer stays, without a session, and the highlight AppKit
    /// has just taken off is put back — now and a turn later, after AppKit has finished with the
    /// button. Every other cause (a click elsewhere, Escape in the menu bar, another extra opening)
    /// closes it, as the header's contract asks.
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        let event = NSApp.currentEvent
        clickTheSessionHandled = StatusItemClick.number(of: event)
        let onTheIcon = StatusItemClick.number(of: event) != nil && !StatusItemClick.isSecondary(event)
            && screenFrame?.contains(NSEvent.mouseLocation) == true
        guard StatusItemClick.sessionEndHidesHistory(endedByPlainClickOnTheIcon: onTheIcon) else {
            log.notice("menu bar: the session ended on a repeated click; the history stays open")
            keepTheHighlightWhileTheHistoryIsOpen()
            DispatchQueue.main.async { [weak self] in self?.keepTheHighlightWhileTheHistoryIsOpen() }
            return
        }
        app.hideHistory()
    }

    private func keepTheHighlightWhileTheHistoryIsOpen() {
        statusItem?.button?.highlight(app.historyIsShowing)
    }

    /// The drawer opened or closed, by whatever route — a click, Escape, a click elsewhere, Show in
    /// Library, an instrument.
    ///
    /// **Closing cancels the session**, which is the contract's rule for a window the app closed
    /// itself; AppKit then calls `statusItemDidEndExpandedInterfaceSession`, which hides a drawer
    /// that is already hidden, and that is a no-op. **The highlight is set here as well as left to
    /// the session**, because the drawer can be open without one (see the type's comment), and an
    /// icon that looks the same open and shut was the audit's M5.
    func historyBecame(visible: Bool) {
        statusItem?.button?.highlight(visible)
        if !visible { statusItem?.expandedInterfaceSession?.cancel() }
    }

    /// **Both surfaces, by name, for a reader who has no right click.** VoiceOver's default press
    /// arrives as the button's action with no mouse event, so it could only ever toggle the
    /// history; the menu — Library, Settings, Quit — had no route at all (audit M2). The menu is
    /// opened a turn later: an action handler that runs a menu's tracking loop does not return to
    /// the client that asked until the menu closes.
    private func offerBothSurfacesToAssistiveTechnology(on button: NSStatusBarButton?) {
        button?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: String(localized: "Show Menu", comment: "VoiceOver action on the menu bar icon")
            ) { [weak self] in
                DispatchQueue.main.async { self?.showMenu() }
                return true
            },
            NSAccessibilityCustomAction(
                name: String(localized: "Show Reading History", comment: "VoiceOver action on the menu bar icon")
            ) { [weak self] in
                MainActor.assumeIsolated { self?.app.showHistory() }
                return true
            },
        ])
    }

    // MARK: - The menu

    /// **Rebuilt every time it opens**, which is why nothing here observes anything. The pause
    /// state and the problems are read at the moment the reader asks to see them, so none of them
    /// can be stale and none needs a subscription.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // **For the problems below, not for a dictionary list.** This menu stopped showing the
        // dictionaries when Study From moved to Settings, and the call looks redundant now —
        // `askForDictionaries` also probes TCC, and the missing permissions are one of the three
        // things `problems` is made of. Refreshing the models was dropped with the rows that read
        // them; the Settings scene does that when it opens, which is where they are shown.
        Task { await app.askForDictionaries() }

        menu.removeAllItems()
        // **Pausing, which is the one thing here a reader does often.** It is momentary — put
        // hover down for a quarter of an hour and let it come back — where switching hover off is
        // a setting, and settings are a tab away rather than a click away.
        let pause = HoverPauseMenu.entries(
            hoverIsOn: app.hover.isWatching, pausedUntil: app.hover.pauseSwitch.until, now: .now)
        for entry in pause { menu.addItem(item(for: entry)) }

        menu.addItem(.separator())
        // The one window. **Reading history is not here**: a left click on the icon opens it, and
        // an item that repeats the click that opened the menu is a line the reader reads past.
        // **Nor is Review**: it is a pane of the Library, which reopens on the pane last used, so a
        // second item was a second door into the same room. **No ellipsis**: it opens a window and
        // asks for nothing more (audit M7).
        menu.addItem(item(String(localized: "Library", comment: "Menu bar item"),
                          action: #selector(showLibrary)))

        menu.addItem(.separator())
        // **One door to the settings, and everything that is a setting is behind it.** Look Up
        // Selection has a shortcut and is reached with it; the hover switch and the study
        // dictionary are chosen once and then left — the dictionary was already in Settings
        // identically, so it was two controls for one choice. A menu bar menu is for what a reader
        // reaches for, not an index of everything the app can do.
        let settings = item(String(localized: "Settings…", comment: "Menu bar item"),
                            action: #selector(showSettings))
        // The platform's own shortcut for it, shown so the reader learns it; it works here while
        // the menu is open and in the Library and Settings windows always.
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)

        // Problems the reader should see, in the place they already look. Set apart: a warning
        // listed flush against the settings above it reads as one of them.
        if !app.problems.isEmpty {
            menu.addItem(.separator())
            for problem in app.problems { menu.addItem(item(for: problem)) }
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit XiaolaiDict", comment: "Menu bar item"),
                          action: #selector(quit)))
    }

    /// One line of the pause group: a switch, a status, or the reason there is no switch.
    private func item(for entry: HoverPauseMenu.Entry) -> NSMenuItem {
        switch entry {
        case .pause:
            let parent = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            let lengths = NSMenu()
            for duration in HoverPause.durations {
                let length = NSMenuItem(
                    title: HoverPause.name(of: duration), action: #selector(pauseHover(_:)),
                    keyEquivalent: "")
                length.target = self
                length.representedObject = duration
                lengths.addItem(length)
            }
            parent.submenu = lengths
            return parent
        case .resume:
            return item(entry.title, action: #selector(resumeHover))
        case .resumesAt, .hoverIsOff:
            let line = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            line.isEnabled = false
            if let reason = entry.reason { line.subtitle = reason }
            return line
        }
    }

    /// **A problem is a way to the pane that fixes it, with its warning sign showing.** They were
    /// disabled lines carrying an image macOS 27 no longer draws by default — `NSMenuItem.h`:
    /// "AppKit … will typically hide images" — so each was one dim sentence that could be a very
    /// long one and led nowhere (audit M6).
    private func item(for problem: MenuProblem) -> NSMenuItem {
        let entry = item(problem.title, action: #selector(showFix(_:)))
        entry.image = NSImage(
            systemSymbolName: ActionSymbol.warning.symbol, accessibilityDescription: nil)
        entry.preferredImageVisibility = .visible
        entry.representedObject = problem.pane.rawValue
        entry.toolTip = problem.detail
        return entry
    }

    /// An enabled item targeted at this object. `NSMenuItem`'s default target is nil, which walks
    /// the responder chain and finds nothing in a status menu.
    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - What the items do

    @objc private func showLibrary() { app.showLibrary() }
    @objc private func showSettings() { app.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func resumeHover() { app.hover.resume() }

    @objc private func pauseHover(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Duration else { return }
        app.hover.pause(for: duration)
    }

    @objc private func showFix(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let pane = SettingsPane(rawValue: name) else {
            log.fault("menu bar: a problem row named no settings pane")
            app.showSettings()
            return
        }
        app.showSettings(on: pane)
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        visibilityObservation?.invalidate()
    }
}

/// **What one click on the icon does, decided apart from AppKit so it can be tested.**
///
/// Two things can answer a click: the session AppKit runs for the drawer (macOS 27), and the
/// button's own action. What a throwaway status item measured is that the action alone answers a
/// programmatic or Accessibility press; whether a real click begins a session, sends the action, or
/// both was not measurable on a locked screen. So the action defers to the session wherever the
/// session has spoken: one that began or ended **during this same click** has already done the
/// click's work, and the action adds nothing to it.
///
/// **A plain click shows the history and never closes it** (ab9cb7e, the owner's decision): there
/// is no toggle case here to route to.
enum StatusItemClick: Equatable {
    case menu
    case showHistory
    case nothing

    static func route(isSecondary: Bool, handledBySession: Bool) -> StatusItemClick {
        if handledBySession { return .nothing }
        // **The menu even while the drawer is open**: a right click asks for the menu whatever
        // else is showing.
        return isSecondary ? .menu : .showHistory
    }

    /// Whether the drawer closes when AppKit ends its session. It does, except when the session
    /// ended because the reader clicked the icon again — which must leave the history open.
    static func sessionEndHidesHistory(endedByPlainClickOnTheIcon: Bool) -> Bool {
        !endedByPlainClickOnTheIcon
    }

    /// What a session beginning shows. The drawer for a plain click; the menu otherwise — see
    /// `MenuBarItem.statusItem(_:didBegin:)` for why the keyboard is sent to the menu.
    static func sessionShowsHistory(isSecondary: Bool, isKeyboard: Bool) -> Bool {
        !isSecondary && !isKeyboard
    }

    /// **Control-click is a right click**, which is the system's rule and not a courtesy: a reader
    /// on a trackpad with secondary click switched off has no other way to the menu.
    static func isSecondary(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return true
        case .leftMouseDown, .leftMouseUp: return event.modifierFlags.contains(.control)
        default: return false
        }
    }

    static func isKeyboard(_ event: NSEvent?) -> Bool {
        event?.type == .keyDown || event?.type == .keyUp
    }

    /// The number a mouse-down shares with its mouse-up, or nil for anything that is not a click.
    /// **Asked only of mouse events**: `eventNumber` raises for any other type.
    static func number(of event: NSEvent?) -> Int? {
        guard let event else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: return event.eventNumber
        default: return nil
        }
    }
}

/// Something the reader should be told, in the menu, and the settings pane where it is put right.
struct MenuProblem: Equatable {
    /// A menu item's worth: a few words, title-style.
    let title: String
    /// The whole sentence, for the pointer resting on the row. Nil when the title says it all.
    let detail: String?
    let pane: SettingsPane
}

/// **The pause group's lines, as values** — what the menu says about hover, decided from three
/// facts and nothing else.
///
/// These labels were plain literals in `XiaolaiDictCore` (`HoverPause.label(at:)`), which may hold
/// no display text: they were in no string catalog, and one of them — "Paused — resumes in 14
/// minutes" — was the title of the item that *resumes*, so it named a state where a menu item names
/// what choosing it does (audit M7). And the group was offered with hover switched off, pausing
/// something that was not running (M8).
enum HoverPauseMenu {
    enum Entry: Equatable {
        /// The parent of the lengths. No ellipsis: a submenu draws its own arrow.
        case pause
        /// A line that does nothing: when hover comes back by itself.
        case resumesAt(String)
        case resume
        /// Hover is switched off, so there is nothing to pause — said, rather than left out.
        case hoverIsOff

        var title: String {
            switch self {
            case .pause, .hoverIsOff: String(localized: "Pause Hover", comment: "Menu bar item, parent of the pause lengths")
            case .resumesAt(let when):
                String(localized: "Hover resumes \(when)",
                       comment: "Menu bar status line; the placeholder is a relative time such as 'in 14 minutes'")
            case .resume: String(localized: "Resume Hover", comment: "Menu bar item")
            }
        }

        /// Why the line cannot be chosen, where that needs saying.
        var reason: String? {
            guard self == .hoverIsOff else { return nil }
            return String(localized: "Hover is turned off in Settings",
                          comment: "Why Pause Hover is unavailable in the menu bar menu")
        }
    }

    static func entries(
        hoverIsOn: Bool, pausedUntil: Date?, now: Date, locale: Locale = .current
    ) -> [Entry] {
        guard hoverIsOn else { return [.hoverIsOff] }
        guard let pausedUntil, now < pausedUntil else { return [.pause] }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return [.resumesAt(formatter.localizedString(for: pausedUntil, relativeTo: now)), .resume]
    }
}
