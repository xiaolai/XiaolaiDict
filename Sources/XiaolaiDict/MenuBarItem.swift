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
/// **The macOS 27 expanded-interface session is not adopted, and was tried** (2026-10-02).
/// `NSStatusItemExpandedInterfaceDelegate` lets AppKit run a session for a status item's window.
/// Measured on a real Mac (macOS 27.0, real mouse events) with the delegate set: a right click
/// *begins a session*; cancelling it and opening the menu a turn later shows the menu with its
/// items, and **choosing an item does nothing — the action never arrives** (three of three; the
/// first right click after launch also drew an empty menu for about six seconds). A menu whose
/// items are dead is the app's front door not opening, so the delegate is not set. Do not adopt it
/// again without a real pointer on a real Mac: a programmatic or Accessibility press begins no
/// session at all, so nothing that can be run from a test or a locked screen shows the failure.
/// `MenuBarItemTests` holds the line.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
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

    // MARK: - Clicks

    /// The routing of ab9cb7e, which is the one measured to work: a secondary click attaches the
    /// menu for the length of that click, and anything else shows the history.
    @objc private func clicked() {
        guard StatusItemClick.isSecondary(NSApp.currentEvent) else {
            // Said, because a click that did nothing and a click that never arrived look the same
            // from outside — and did, on the E2E Mac, 2026-10-02.
            log.notice("menu bar: a click asked for the reading history")
            // **Shows, never toggles** — the owner's decision in ab9cb7e: a repeated click on the
            // icon keeps the history open. `showHistory` is idempotent, so the second is a no-op.
            app.showHistory()
            return
        }
        showMenu()
    }

    /// Attached for this one showing only, so the next left click is ours again.
    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The drawer opened or closed, by whatever route — a click, Escape, a click elsewhere, Show in
    /// Library, an instrument. An icon that looks the same open and shut was the audit's M5; the
    /// highlight is the half of that finding that was kept.
    func historyBecame(visible: Bool) {
        statusItem?.button?.highlight(visible)
    }

    /// **Both surfaces, by name, for a reader who has no right click.** VoiceOver's default press
    /// arrives as the button's action with no mouse event, so it could only ever show the
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

/// Which click asks for the menu, decided apart from AppKit so it can be tested.
enum StatusItemClick {
    /// A right click — and a control-click, **which is the system's rule and not a courtesy**: a
    /// reader on a trackpad with secondary click switched off has no other way to the menu.
    static func isSecondary(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return true
        default: return event.modifierFlags.contains(.control)
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
