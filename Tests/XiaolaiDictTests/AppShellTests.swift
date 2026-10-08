import AppKit
import Carbon.HIToolbox
import Foundation
import MacCapture
import Testing
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

@testable import XiaolaiDict

/// **Whether the app is in the Dock, decided from its windows** — `ShellActivation` (audit M13,
/// 2026-10-02). The decision is a function so that it can be tested here rather than watched.
struct ShellActivationTests {
    private func window(_ kind: ShellActivation.Kind, visible: Bool = true, closing: Bool = false)
        -> ShellActivation.Window
    {
        ShellActivation.Window(kind: kind, isVisible: visible, isClosing: closing)
    }

    @Test func aMenuBarAppWithNoChosenWindowStaysOutOfTheDock() {
        #expect(ShellActivation.policy(for: []) == .accessory)
        #expect(ShellActivation.policy(for: [window(.other)]) == .accessory)
    }

    @Test func theLibraryOrSettingsOpenPutsItInTheDock() {
        #expect(ShellActivation.policy(for: [window(.library)]) == .regular)
        #expect(ShellActivation.policy(for: [window(.settings)]) == .regular)
        #expect(ShellActivation.policy(for: [window(.other), window(.settings), window(.floating)]) == .regular)
    }

    /// **The rule that matters most.** The panel, the drawer and a pinned note appear while the
    /// reader is mid-sentence in another app; none of them may bring a Dock icon with it.
    @Test func thePanelTheDrawerAndNotesNeverCount() {
        #expect(ShellActivation.policy(for: [window(.floating), window(.floating)]) == .accessory)
        #expect(ShellActivation.policy(for: [], opening: .floating) == .accessory)
        #expect(!ShellActivation.Kind.floating.isChosen && !ShellActivation.Kind.other.isChosen)
    }

    /// SwiftUI keeps a closed scene's window, hidden. A window that exists is not a window that is
    /// open, and counting it would leave the Dock icon up for good after the first Library.
    @Test func aHiddenWindowDoesNotCount() {
        #expect(ShellActivation.policy(for: [window(.library, visible: false)]) == .accessory)
    }

    /// `willClose` arrives while the window is still visible; it is the one being closed, so it
    /// must not hold the policy up — but another chosen window still does.
    @Test func theLastChosenWindowClosingGoesBackToAccessory() {
        #expect(ShellActivation.policy(for: [window(.library, closing: true)]) == .accessory)
        #expect(ShellActivation.policy(for: [window(.library, closing: true), window(.settings)]) == .regular)
    }

    /// The policy changes before the window exists, so that it comes forward as a regular app's.
    @Test func aChosenWindowBeingOpenedCountsBeforeItExists() {
        #expect(ShellActivation.policy(for: [], opening: .library) == .regular)
        #expect(ShellActivation.policy(for: [], opening: .settings) == .regular)
    }

    /// By scene identifier, never by title. The settings window carries no scene id of this app's,
    /// so it is recognised by the reference the app holds.
    @Test func windowsAreClassifiedByIdentifier() {
        #expect(ShellActivation.kind(ofIdentifier: "library-AppWindow-1", isSettings: false) == .library)
        #expect(ShellActivation.kind(ofIdentifier: "lookup-AppWindow-1", isSettings: false) == .floating)
        #expect(ShellActivation.kind(ofIdentifier: "reading-history-AppWindow-1", isSettings: false) == .floating)
        #expect(ShellActivation.kind(ofIdentifier: "com_apple_SwiftUI_Settings_window", isSettings: true) == .settings)
        #expect(ShellActivation.kind(ofIdentifier: nil, isSettings: false) == .other)
        #expect(ShellActivation.kind(ofIdentifier: "NSStatusBarWindow", isSettings: false) == .other)
    }
}

/// The wire: the delegate actually asks for the policy, and only for the windows the reader chose.
@MainActor
struct ShellActivationWiringTests {
    @MainActor private final class Policies {
        var set: [NSApplication.ActivationPolicy] = []
        var activations = 0
    }

    private func app(_ policies: Policies) -> XiaolaiDictApp {
        let suite = TemporaryDefaults.suite()
        return XiaolaiDictApp(
            defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
            models: .temporary(defaults: suite),
            shell: ShellActivationController.System(
                setPolicy: { policies.set.append($0) }, activate: { policies.activations += 1 }))
    }

    /// **Into the Dock and forward, in that order — and back out when the window never came.**
    /// No test can wire `WindowActions`, so here the window is asked for and cannot open: the first
    /// policy is the one a real open gets, and the second is the app refusing to leave a Dock icon
    /// standing for a window that does not exist.
    @Test func openingTheLibraryMovesTheAppIntoTheDockAndForward() {
        let policies = Policies()
        let app = app(policies)
        app.showLibrary()
        #expect(policies.set.first == .regular, "the Library was asked for and the app stayed out of the Dock")
        #expect(policies.activations == 1, "a window the reader chose did not come forward")
        #expect(policies.set == [.regular, .accessory], "a Library that never opened left the app in the Dock")
    }

    @Test func openingSettingsMovesTheAppIntoTheDockAndForward() {
        let policies = Policies()
        let app = app(policies)
        app.showSettings(on: .lookup)
        #expect(policies.set.first == .regular)
        #expect(policies.activations == 1)
        #expect(policies.set == [.regular, .accessory])
    }

    /// A view reporting its window raises the policy and never lowers it: the report arrives before
    /// the window is on screen, and lowering there would undo the open that caused it.
    @Test func aWindowBeingAttachedNeverLowersThePolicy() {
        let policies = Policies()
        let controller = ShellActivationController(
            system: .init(setPolicy: { policies.set.append($0) }, activate: { policies.activations += 1 }),
            settingsWindow: { nil })
        controller.bringForward(for: .library)
        controller.windowAttached()
        #expect(policies.set == [.regular], "attaching a window sent the app back out of the Dock")
        controller.reconsider()
        #expect(policies.set == [.regular, .accessory], "nothing ever goes back to accessory")
    }

    /// **The drawer and a lookup never touch the policy.** Shown as the menu bar shows it, and put away
    /// by `toggleHistory` — a path the app has; the `hideHistory` wrapper this used had no other caller
    /// and went (audit-fix round 3, #6).
    @Test func theDrawerDoesNotMoveTheAppIntoTheDock() {
        let policies = Policies()
        let app = app(policies)
        app.showHistory()
        app.toggleHistory()
        #expect(policies.set.isEmpty, "showing the drawer changed the activation policy: \(policies.set)")
        #expect(policies.activations == 0, "the drawer activated the app")
    }

    /// And a panel routed to the activating path by mistake is refused there, not obeyed.
    @Test func bringingForwardIsRefusedForAnythingTheReaderDidNotChoose() {
        let policies = Policies()
        let app = app(policies)
        app.activation.bringForward(for: .floating)
        app.activation.bringForward(for: .other)
        #expect(policies.set.isEmpty && policies.activations == 0)
    }

    /// **Opening the app again shows the Library** (audit M1): the way back for a reader whose menu
    /// bar icon is hidden. `false` tells AppKit the request was handled.
    @Test func reopeningTheAppShowsTheLibrary() {
        let policies = Policies()
        let app = app(policies)
        let handled = app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        #expect(!handled, "AppKit was asked to do its default as well")
        #expect(policies.set.first == .regular && policies.activations == 1,
                "reopening did not go through the Library's own route")
    }

    private func source(_ path: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The test double's default is inert, so production must name the real setter.** Read from
    /// the source because it is the one line no test can call without putting the test runner in
    /// the Dock.
    @Test func theRunningAppSetsAppKitsOwnPolicy() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let start = try #require(app.range(of: "override convenience init()"))
        #expect(app[start.lowerBound...].prefix(400).contains("shell: .appKit"),
                "init() does not hand over AppKit, so the policy is decided and never applied")
        let shell = try source("Sources/XiaolaiDict/ShellActivation.swift")
        #expect(shell.contains("NSApplication.shared.setActivationPolicy($0)")
                && shell.contains("NSApplication.shared.activate()"), ".appKit is not AppKit")
        #expect(app.contains("activation.watchForClosingWindows()"), "nothing follows the windows closing")
        // And the panels' controllers never reach for it.
        for file in ["LookupPanel.swift", "HistoryDrawer.swift", "PinnedNoteController.swift"] {
            let code = try source("Sources/XiaolaiDict/\(file)")
            #expect(!code.contains("setActivationPolicy") && !code.contains("bringForward")
                    && !code.contains(".activate()"),
                    "\(file) changes the activation policy; no panel may")
        }
    }
}

/// The pause group of the menu bar menu — `HoverPauseMenu` (audit M7, M8).
struct HoverPauseMenuTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")

    @Test func hoverRunningOffersThePauseSubmenu() {
        #expect(HoverPauseMenu.entries(hoverIsOn: true, pausedUntil: nil, now: now) == [.pause])
        // A lapsed pause is not a pause.
        #expect(HoverPauseMenu.entries(hoverIsOn: true, pausedUntil: now.addingTimeInterval(-1), now: now)
                == [.pause])
    }

    /// **The item that resumes is named for resuming**, and the time left is a line of its own. It
    /// was one item titled "Paused — resumes in 14 minutes": a state, on the control that ends it.
    @Test func aPausedHoverSaysWhenItResumesAndOffersToResume() {
        let entries = HoverPauseMenu.entries(
            hoverIsOn: true, pausedUntil: now.addingTimeInterval(14 * 60), now: now, locale: english)
        #expect(entries == [.resumesAt("in 14 minutes"), .resume])
        #expect(HoverPauseMenu.Entry.resume.title == "Resume Hover")
        #expect(entries.first?.title == "Hover resumes in 14 minutes")
    }

    /// **Hover switched off has nothing to pause** (M8) — said with its reason rather than offered,
    /// and rather than silently left out, even when a pause is still running.
    @Test func hoverSwitchedOffIsSaidWithItsReason() {
        for until in [nil, now.addingTimeInterval(600)] {
            let entries = HoverPauseMenu.entries(hoverIsOn: false, pausedUntil: until, now: now)
            #expect(entries == [.hoverIsOff])
        }
        #expect(HoverPauseMenu.Entry.hoverIsOff.reason?.isEmpty == false)
        #expect(HoverPauseMenu.Entry.pause.reason == nil)
    }

    /// No ellipsis on a submenu parent — it draws its own arrow (M7).
    @Test func noPauseTitleCarriesAnEllipsis() {
        for entry in [HoverPauseMenu.Entry.pause, .resume, .hoverIsOff, .resumesAt("in 1 hour")] {
            #expect(!entry.title.contains("…") && !entry.title.contains("..."), "\(entry.title)")
        }
        #expect(HoverPauseMenu.Entry.pause.title == "Pause Hover")
    }
}

/// The menu's problem rows — `MenuProblem` and `XiaolaiDictApp.problems` (audit M6).
@MainActor
struct MenuProblemTests {
    @Test func aMissingPermissionIsNamedInAFewWords() {
        #expect(XiaolaiDictApp.title(forMissing: [.accessibility]) == "Accessibility Is Off")
        #expect(XiaolaiDictApp.title(forMissing: [.screenRecording]) == "Screen Recording Is Off")
        #expect(XiaolaiDictApp.title(forMissing: [.accessibility, .screenRecording]) == "Permissions Are Off")
    }

    /// A refused shortcut is a row that leads to the Lookup pane, whose title is not the error.
    @Test func aRefusedShortcutIsARowThatLeadsToTheLookupPane() throws {
        let suite = TemporaryDefaults.suite()
        let backend = FakeBackend()
        backend.registerStatus = OSStatus(eventHotKeyExistsErr)
        let app = XiaolaiDictApp(
            defaults: suite, hotkeys: HotkeyCenter(backend: backend), models: .temporary(defaults: suite))
        #expect(app.problems.isEmpty)
        app.shortcuts.registerSaved()
        let row = try #require(app.problems.first)
        #expect(row.pane == .lookup)
        #expect(row.title == "Lookup Shortcut Unavailable")
        #expect(row.detail?.contains("Another app has claimed this shortcut.") == true, "\(row)")
        for text in [row.title, row.detail ?? ""] {
            #expect(!text.contains("RegistrationFailed") && !text.contains("OSStatus"),
                    "a raw error reached the reader: \(text)")
        }
    }

    /// Every refusal has words of its own for the reader, and none of them is the log's.
    @Test func everyRefusalHasReaderText() {
        let reasons: [Hotkey.RegistrationFailed.Reason] = [
            .heldByXiaolaiDict, .unreleasedByXiaolaiDict, .status(OSStatus(eventHotKeyExistsErr)), .status(-50),
        ]
        let said = reasons.map { Hotkey.RegistrationFailed(reason: $0).readerText }
        #expect(Set(said).count == reasons.count, "two refusals read the same: \(said)")
        for (reason, text) in zip(reasons, said) {
            #expect(text != Hotkey.RegistrationFailed(reason: reason).description)
            #expect(text.hasSuffix("."), "not a sentence: \(text)")
        }
    }

    /// **The wire to the menu**: the image is asked to show — macOS 27 hides menu item images
    /// unless told otherwise — the row is enabled, and it opens a pane.
    @Test func aProblemRowShowsItsWarningAndOpensAPane() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appending(path: "Sources/XiaolaiDict/MenuBarItem.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func item(for problem: MenuProblem)"))
        let body = source[start.lowerBound...].prefix(700)
        #expect(body.contains("preferredImageVisibility = .visible"), "the warning sign is left to be hidden")
        #expect(body.contains("#selector(showFix(_:))"), "a problem row leads nowhere")
        #expect(!body.contains("isEnabled = false"), "a problem row is disabled")
        #expect(body.contains("ActionSymbol.warning.symbol"), "the warning symbol is spelled as a string")
        #expect(source.contains("app.showSettings(on: pane)"))
    }
}

/// The scenes: what each window is called, and how a window is found (audit M9, M10, L19).
@MainActor
struct SceneShellTests {
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func code(_ path: String) throws -> String {
        try String(contentsOf: Self.repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theLookupWindowAndEachNoteAreTitledForWhatTheyAre() throws {
        let scene = try code("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        #expect(scene.contains("Window(\"Lookup\", id: Self.lookupID)"), "the lookup window is not titled Lookup")
        #expect(!scene.contains("lookupTitle"), "the app-name title is still defined")
        let notes = try #require(scene.range(of: "WindowGroup(for: UUID.self)"))
        #expect(scene[notes.lowerBound...].prefix(600).contains(".navigationTitle("),
                "a pinned note is still titled with the app's name")
    }

    /// **No window is found by its title, anywhere in the app.** A title is localised; three
    /// lookups compared one against an English literal. Searched two ways, because a scan is only
    /// as wide as the spelling it knows — and in every module the app links, because it is only as wide as its
    /// roots too: it walked `Sources/XiaolaiDict` alone until 2026-10-08, by when the ten capture readers, which
    /// speak AppKit and read other apps' windows, had left it for `MacCapture` (`AppModules`).
    @Test func noWindowIsFoundByItsTitle() throws {
        let scan = try AppModules.scan()
        #expect(scan.problems.isEmpty, "\(scan.problems)")
        // **Named, not counted**: the two files that look windows up, so a walk that shrank to other files
        // still fails (SourceScan.unread); each root's own witness is `AppModules.witnesses`.
        let unread = SourceScan.unread(["XiaolaiDictApp.swift", "XiaolaiDictScene.swift"], in: scan.read)
        #expect(unread.isEmpty, "the scan no longer reads \(unread)")
        var comparisons: [String] = [], mentions: [String] = []
        for (module, file, source) in scan.files {
            let place = "\(module)/\(file.lastPathComponent)"
            comparisons += Array(repeating: place, count: source.components(separatedBy: ".title ==").count - 1)
            mentions += Array(repeating: place, count: source.components(separatedBy: "$0.title").count - 1)
        }
        #expect(comparisons.isEmpty, "\(comparisons.count) window lookup(s) compare a localisable title: \(comparisons)")
        #expect(mentions.isEmpty, "\(mentions.count) closure(s) read a window's title to pick it: \(mentions)")
    }

    /// Positive control for the scan above: the helper it sends everyone to does match on the
    /// identifier, and answers nil — not a trap — where there is no such window.
    @Test func aSceneWindowIsFoundByIdentifierOrNotAtAll() throws {
        let scene = try code("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        #expect(scene.contains("$0.identifier?.rawValue.contains(sceneID) == true"))
        #expect(XiaolaiDictScene.window(of: "no-such-scene-\(UUID().uuidString)") == nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let id = "shell-test-\(UUID().uuidString)"
        window.identifier = NSUserInterfaceItemIdentifier("\(id)-AppWindow-1")
        #expect(XiaolaiDictScene.window(of: id) === window)
    }

    /// The Library keeps its frame and has a floor (L19). The frame is restored once per window —
    /// re-applying it on every SwiftUI update would snap the window back mid-drag.
    @Test func theLibraryWindowKeepsItsFrameAndHasAMinimumSize() throws {
        let scene = try code("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        let library = try #require(scene.range(of: "Window(\"Library\", id: Self.libraryID)"))
        let body = scene[library.lowerBound...].prefix(900)
        #expect(body.contains("LibraryWindowFrame.restore(on: $0)"), "nothing restores the Library's frame")
        #expect(body.contains(".windowResizability(.contentMinSize)"))
        #expect(body.contains("minWidth: Token.Library.minWidth, minHeight: Token.Library.minHeight"))
        #expect(Token.Library.minWidth < Token.Library.width && Token.Library.minHeight < Token.Library.height)
        #expect(Token.Library.minWidth > Token.Library.sidebarMinWidth, "the floor leaves no room for a card")

        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 500, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            window.setFrameAutosaveName("")
            NSWindow.removeFrame(usingName: XiaolaiDictScene.libraryFrameName)
            window.close()
        }
        LibraryWindowFrame.restore(on: window)
        #expect(window.frameAutosaveName == XiaolaiDictScene.libraryFrameName)
        // The second call is every later SwiftUI update: it must leave a moved window where it is.
        let moved = CGRect(x: 80, y: 90, width: 640, height: 480)
        window.setFrame(moved, display: false)
        LibraryWindowFrame.restore(on: window)
        #expect(window.frame == moved, "a later update put the window back: \(window.frame)")
    }

    /// The copyright names its holder (M16).
    @Test func theCopyrightNamesItsHolder() throws {
        let plist = try #require(NSDictionary(
            contentsOf: Self.repository.appending(path: "Resources/Info.plist")))
        let copyright = try #require(plist["NSHumanReadableCopyright"] as? String)
        #expect(copyright == "© 2026 xiaolai", "the copyright is \(copyright)")
    }
}
