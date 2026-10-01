import AppKit
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
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
/// So the item is this app's own, which is what `ambages/MacLibrary/StatusBarController.swift` does
/// and the shape this is modelled on: keep `statusItem.menu` **nil** so a click reaches an action
/// at all, and attach the menu for the length of one right click.
///
/// **`MenuBarExtra` stays in the scene, uninserted.** `MenuBarLabel`'s `.task` is where
/// `WindowActions.shared` is captured — the panel, the drawer and Settings all open through it —
/// and it is the only view in this app that lives as long as the process. Measured: with
/// `isInserted: false` the label still mounts and the capture still happens, so the scene can keep
/// doing that one job while showing nothing.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "menubar")
    private let app: XiaolaiDictApp
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

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
        describeTheIcon()
        log.notice("menu bar: left click opens the reading history, right click opens the menu")
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
    static func description(ofShortcut label: String?) -> String {
        guard let label else {
            return String(localized: "XiaolaiDict — no lookup shortcut is registered",
                          comment: "The menu bar icon's tooltip when no lookup shortcut is registered")
        }
        return String(localized: "XiaolaiDict — press \(label) to look up the selection",
                      comment: "The menu bar icon's tooltip, naming the registered lookup shortcut")
    }

    @objc private func clicked() {
        // **Control-click is a right click**, which is the system's rule and not a courtesy: a
        // reader on a trackpad with secondary click switched off has no other way to the menu.
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let statusItem else {
            app.showHistory()
            return
        }
        // Attached for this click only, so the next left click is ours again.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - The menu

    /// **Rebuilt every time it opens**, which is why nothing here observes anything. The hover
    /// switch, the pause label, the dictionary list and the problems are all read at the moment the
    /// reader asks to see them, so none of them can be stale and none needs a subscription.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // **For the problems below, not for a dictionary list.** This menu stopped showing the
        // dictionaries when Study From moved to Settings, and the call looks redundant now —
        // `askForDictionaries` also probes TCC, and `permissions.menuWarning` is one of the three
        // things `problems` is made of. Refreshing the models was dropped with the rows that read
        // them; the Settings scene does that when it opens, which is where they are shown.
        Task { await app.askForDictionaries() }

        menu.removeAllItems()
        // **Pausing, which is the one thing here a reader does often.** It is momentary — put
        // hover down for a quarter of an hour and let it come back — where switching hover off is
        // a setting, and settings are a tab away rather than a click away.
        menu.addItem(pauseItem())

        menu.addItem(.separator())
        // The two windows. **Reading history is not here**: a left click on the icon opens it, and
        // an item that repeats the click that opened the menu is a line the reader reads past.
        menu.addItem(item(String(localized: "Review…", comment: "Menu bar item"),
                          action: #selector(showReview)))
        menu.addItem(item(String(localized: "Library…", comment: "Menu bar item"),
                          action: #selector(showLibrary)))

        menu.addItem(.separator())
        // **One door to the settings, and everything that is a setting is behind it.** Look Up
        // Selection has a shortcut and is reached with it; the hover switch and the study
        // dictionary are chosen once and then left — the dictionary was already in Settings
        // identically, so it was two controls for one choice. A menu bar menu is for what a reader
        // reaches for, not an index of everything the app can do.
        menu.addItem(item(String(localized: "Settings…", comment: "Menu bar item"),
                          action: #selector(showSettings)))

        // Problems the reader should see, in the place they already look. Set apart: a warning
        // listed flush against the settings above it reads as one of them.
        if !app.problems.isEmpty {
            menu.addItem(.separator())
            for problem in app.problems {
                let entry = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
                entry.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                entry.isEnabled = false
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit XiaolaiDict", comment: "Menu bar item"),
                          action: #selector(quit)))
    }

    /// The pause switch. Resuming is one click; pausing picks a length, which is what having three
    /// of them is for.
    private func pauseItem() -> NSMenuItem {
        guard !app.hover.isPaused else {
            return item(app.hover.pauseLabel, action: #selector(resumeHover))
        }
        let entry = NSMenuItem(title: app.hover.pauseLabel, action: nil, keyEquivalent: "")
        let lengths = NSMenu()
        for duration in HoverPause.durations {
            let length = NSMenuItem(
                title: HoverPause.name(of: duration), action: #selector(pauseHover(_:)),
                keyEquivalent: "")
            length.target = self
            length.representedObject = duration
            lengths.addItem(length)
        }
        entry.submenu = lengths
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

    @objc private func showReview() { app.showReview() }
    @objc private func showLibrary() { app.showLibrary() }
    @objc private func showSettings() { app.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func resumeHover() { app.hover.resume() }

    @objc private func pauseHover(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Duration else { return }
        app.hover.pause(for: duration)
    }

}
