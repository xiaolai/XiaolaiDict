import AppKit
import XiaolaiDictCore
import XiaolaiDictUI
import Observation
import os

/// The menu-bar app: a shortcut on a selection opens the lookup panel and records the lookup.
@Observable
@MainActor
final class XiaolaiDictApp: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")
    private let panel = LookupPanelController()
    private let client = DictionaryClient()
    /// **The suite the app was given, not `.standard`** — the same reason the shortcut store takes
    /// one. A test that chose a dictionary used to rewrite the reader's own choice, and switching
    /// the primary starts their study over.
    private let primaryDictionary: PrimaryDictionaryStore
    /// Whether the setup window has opened by itself before. **The app's own suite, not
    /// `.standard`** — a test that flipped it would change whether the reader's next launch opens
    /// a window at them.
    private let setupPresentation: SetupPresentationStore
    @ObservationIgnored private lazy var runner = makeRunner()
    @ObservationIgnored private lazy var drawer = makeDrawer()
    /// Milestone 2's trigger. Watches the pointer and reads the word under it when the reader
    /// rests with the modifier held; the reading itself is `HoverReader`, already tested.
    ///
    /// Lazy so it can be handed a closure onto `hoverPause` below — a stored property cannot read
    /// `self`, which is the mechanical reason the pause was never connected to anything.
    @ObservationIgnored private(set) lazy var hover = makeHover()

    /// **The pause the menu offers and the gate reads — one value, held here.** There was no such
    /// value: `HoverReader`'s default built a fresh `HoverPause` on every call, so the gate asked
    /// "is XiaolaiDict paused" of an object that had just been born and always answered no. Nothing in
    /// the app or the suite ever supplied one, and the menu item `HoverPause.label(at:)` was
    /// written for did not exist. The model was complete and unreachable.
    private(set) var hoverPause = HoverPause()

    /// The reader's hover policy, **held in memory and observed**, with the store behind it.
    ///
    /// Read rather than loaded on each use on purpose: `HoverWatcher` asks for the policy on every
    /// pointer change to get `settleMilliseconds`, so decoding it there would put a JSON decode on
    /// the mouse-move path. One decode at launch, one write when the reader changes something.
    @ObservationIgnored private let hoverPolicyStore: HoverPolicyStore
    private(set) var hoverPolicy: HoverPolicy

    /// **`init()` must exist, and must be written out.** `@NSApplicationDelegateAdaptor`
    /// instantiates the delegate through the Objective-C runtime, which looks for `init` and finds
    /// `NSObject`'s — not a Swift designated initializer that happens to have a default argument
    /// for every parameter. Declaring `init(defaults:)` alone therefore suppressed the inherited
    /// `init()` and every launch died with "Use of unimplemented initializer", while the unit
    /// suite stayed green because tests call the initializer Swift can see.
    override convenience init() {
        self.init(defaults: .standard)
    }

    /// `defaults` is a parameter so a test can be given a suite of its own. Without it, asserting
    /// anything about the reader's settings means writing to the real ones — a test suite that
    /// changes the machine it runs on, which is the same objection the project makes to driving
    /// the GUI on the building Mac.
    init(defaults: UserDefaults, hotkeys: HotkeyCenter = .shared) {
        // Loaded once, here, rather than lazily: `@Observable` makes stored properties computed,
        // so there is no `lazy` to be had — and a per-use load would be the mouse-move decode
        // this property exists to avoid.
        let store = HoverPolicyStore(defaults: defaults)
        hoverPolicyStore = store
        hoverPolicy = store.load()
        // **The suite the app was given, not `.standard`.** Built inline against the real
        // preferences while `init(defaults:)` existed for exactly this reason, so every test that
        // touched the shortcut rewrote the reader's own — the objection this project makes to
        // driving the GUI on the building Mac, in a unit test.
        shortcuts = ShortcutStore(defaults: defaults)
        setupPresentation = SetupPresentationStore(defaults: defaults)
        let primary = PrimaryDictionaryStore(defaults: defaults)
        primaryDictionary = primary
        chosenDictionary = primary.load().chosen
        self.hotkeys = hotkeys
        super.init()
    }

    /// Changing it saves it and takes effect immediately — the watcher reads this property, so
    /// there is nothing to restart and no second copy to keep in step.
    func setHoverPolicy(_ policy: HoverPolicy) {
        hoverPolicy = policy
        hoverPolicyStore.save(policy)
    }

    /// What the pause control says. Observed, so pausing redraws the menu without being told to.
    var hoverPauseLabel: String { hoverPause.label(at: .now) }
    var hoverIsPaused: Bool { hoverPause.isPaused(at: .now) }

    func pauseHover(for duration: Duration) { hoverPause.pause(for: duration, from: .now) }
    func resumeHover() { hoverPause.resume() }

    private func makeHover() -> HoverWatcher {
        // `self` is read at decision time, not captured by value — a copy taken here would be the
        // same never-changing pause this replaces.
        HoverWatcher(
            policy: { [weak self] in self?.hoverPolicy ?? .shipped },
            pause: { [weak self] in self?.hoverPause ?? HoverPause() })
    }
    /// The last permission probe. Cached because asking costs a ScreenCaptureKit round trip and
    /// `menuNeedsUpdate` cannot wait for one; the menu shows what was last known and asks again.
    private var permissions = PermissionsReport(states: [])

    /// The history drawer reads the ledger itself, bounded in both directions, and reports a
    /// failure rather than an empty drawer — the two must not look the same.
    private func makeDrawer() -> HistoryDrawerController {
        let drawer = HistoryDrawerController { [weak self] in
            guard let opening = self?.ledger else { return .unavailable("The ledger is not open yet.") }
            do {
                let since = Date.now.addingTimeInterval(-HistoryDrawerController.window)
                return .entries(try await opening.value.recentLookups(
                    since: since, limit: HistoryDrawerController.cardLimit))
            } catch {
                return .unavailable("\(error)")
            }
        }
        // Only reached once the reader's grace period has run out, so by the time this fires they
        // have had their chance to take it back.
        drawer.model.delete = { [weak self] entry in
            guard let self, let opening = self.ledger else { return }
            Task {
                do { try await opening.value.delete(lookup: entry.id) }
                // Logged, not surfaced: the card is already gone from a drawer the reader has
                // moved on from, and an alert about a history row is worse than the row.
                catch { self.log.error("could not remove lookup \(entry.id): \(error)") }
            }
        }
        return drawer
    }

    private func makeRunner() -> LookupRunner {
        let store = primaryDictionary
        // **The store is the truth for a lookup**, because a lookup can happen while no window is
        // open to have observed anything. The observable copy is what the windows draw, and
        // `askForDictionaries` re-reads it so the two cannot drift apart after a change made
        // outside this process.
        return LookupRunner(
            client: client, panel: panel, primary: { store.load() },
            priorEncounters: { [weak self] lemma, before in
                guard let opening = await MainActor.run(body: { self?.ledger }) else { return PriorEncounters() }
                // A ledger that cannot be read costs the memory strip, never the lookup.
                return (try? await opening.value.priorEncounters(of: lemma, before: before)) ?? PriorEncounters()
            })
    }
    /// The enabled dictionaries, as the service last reported them. Nil until it has been asked:
    /// the menu says it does not know rather than showing a list it made up.
    var dictionaries: [DictionaryCapability]?
    /// Whether the service has been asked and has finished answering — see `DictionaryChoice`.
    private(set) var dictionariesAsked = false
    @ObservationIgnored private let shortcuts: ShortcutStore
    /// Carbon's hot-key plumbing, injected so a test never registers a real global shortcut —
    /// which would take it from the reader for as long as the suite ran.
    @ObservationIgnored private let hotkeys: HotkeyCenter
    private var hotkey: Hotkey?
    /// Opened on a background task at launch: file and database work — a migration, on the first
    /// launch after an update — must not hold up the menu bar.
    private var ledger: Task<LedgerStore, any Error>?
    /// The lookup in flight. A new shortcut press cancels it: one lookup at a time.
    private var lookup: Task<Void, Never>?
    private var termination: (any DispatchSourceSignal)?

    /// Problems the reader should see, shown in the menu rather than swallowed.
    private var hotkeyProblem: String?
    /// The ledger's state as of the newest request to finish recording — not of whichever write
    /// happened to finish last.
    private var ledgerStatus: (request: Int, problem: String?) = (0, nil)

    /// The lookup a reader-chosen sense hangs off: the newest one recorded. A tap before anything
    /// was recorded has nothing to attach to, and writes nothing.
    private var lastLookup: Int?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside
        // the bundle behaves the same. Before *did* finish, so no window can flash as an ordinary
        // app's would.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onStudySense = { [weak self] encounter in self?.study(encounter) }
        let opening = Task { try await LedgerStore.openDefault() }
        ledger = opening
        Task {
            do {
                _ = try await opening.value
            } catch {
                // Reported only if no lookup has reported since: a later lookup's own failure says
                // more, and must not be overwritten by this older news.
                if ledgerStatus.request == 0 { ledgerStatus = (0, "Lookups are not being recorded: \(error)") }
                log.error("ledger unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        // Where the menu-bar item is, so a click on it is left for the menu rather than taken by
        // the drawer's click-away dismissal. `MenuBarExtra` exposes no frame, so it is found by its
        // window: a miss costs the guard, which is visible (the drawer reopens) and not silent.
        drawer.statusItemFrame = {
            NSApplication.shared.windows.first { $0.className.contains("StatusBar") }?.frame
        }
        Task { [weak self] in self?.permissions = await .probe() }
        hover.onWord = { [weak self] selection, at in self?.lookUpHovered(selection, at: at) }
        // Watching the pointer is something the reader must be able to stop, so it is a setting
        // and not a fact of running XiaolaiDict — on by default, because it is Milestone 2's whole point.
        // **Not in an instrument run.** `--history-report` captures the screen, and a hover that
        // fired meanwhile would capture too — two captures at once deadlock, measured six trials
        // of six. An instrument measures the app; it has no reader whose pointer needs watching.
        if hoverEnabled, !HistoryReport.isWanted, !SettingsReport.isWanted { hover.start() }
        registerShortcut(shortcuts.load())
        // **Not in an instrument run.** An instrument measures the app; a window opening at it
        // unasked is a window in front of whatever it was about to capture.
        if !HistoryReport.isWanted, !SettingsReport.isWanted { openSetupOnFirstLaunch() }
        quitOnTerminationSignal()
        if HistoryReport.isWanted { Task { exit(await HistoryReport.run(in: self).rawValue) } }
        if SettingsReport.isWanted { Task { exit(await SettingsReport.run(in: self).rawValue) } }
    }

    // MARK: - Looking up

    func lookUpSelection() {
        let pointer = UpPoint(NSEvent.mouseLocation)
        let requestedAt = Date.now
        let ticket = panel.newRequest()
        lookup?.cancel()
        // Asked, not assumed: without Accessibility there is no selection to read, and saying so
        // is better than an empty panel.
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            panel.show(.message(
                title: "XiaolaiDict needs Accessibility access",
                detail: "It reads your selection through Accessibility. Allow XiaolaiDict in \(PrivacySettings.accessibilityLocation), then press the shortcut again."),
                near: pointer, for: ticket)
            return
        }
        guard let app = FrontApp.frontmost() else {
            panel.show(.message(
                title: "Nothing to look up",
                detail: "The frontmost app could not be identified, so its selection cannot be read."),
                near: pointer, for: ticket)
            return
        }
        lookup = Task {
            switch await SelectionReader.read(from: app) {
            case .nothing(let reason):
                panel.show(.message(title: "Nothing to look up", detail: reason), near: pointer, for: ticket)
            case .selected(let selection):
                await lookUp(selection, near: pointer, requestedAt: requestedAt, ticket: ticket)
            }

        }
    }

    /// A word the reader rested on. The same path as the shortcut from here: one lookup at a
    /// time, and a newer one supersedes whatever was still arriving.
    private func lookUpHovered(_ selection: Selection, at pointer: UpPoint) {
        let requestedAt = Date.now
        let ticket = panel.newRequest()
        lookup?.cancel()
        lookup = Task { await lookUp(selection, near: pointer, requestedAt: requestedAt, ticket: ticket) }
    }

    // MARK: - Hover

    private static let hoverEnabledKey = "hoverLookupEnabled"

    /// Defaults to on for a reader who has never chosen, and remembers a reader who has.
    private var hoverEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.hoverEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.hoverEnabledKey) }
    }

    func toggleHover() {
        hoverEnabled.toggle()
        if hoverEnabled { hover.start() } else { hover.stop() }
    }

    /// Every answered lookup is recorded — a miss too, marked as one: it is usually a typo or a
    /// stray selection, which later triage can tell from a real gap. A lookup superseded before its
    /// answer arrived was never seen, and is not.
    private func lookUp(_ selection: Selection, near pointer: UpPoint, requestedAt: Date, ticket: PanelTicket) async {
        guard let row = await runner.run(selection, near: pointer, requestedAt: requestedAt, ticket: ticket) else { return }
        await record(row, request: ticket.number)
    }

    /// A sense the reader tapped. Recorded as theirs — `chosen_by: reader` — which the ledger
    /// keeps apart from the selector's guesses, because a hypothesis and a fact must never merge.
    private func study(_ encounter: SenseEncounter) {
        guard let ledger, let lookup = lastLookup else { return }
        Task {
            do {
                try await ledger.value.record(encounter, for: lookup)
            } catch {
                log.error("sense not recorded: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func record(_ record: LookupRecording, request: Int) async {
        guard let ledger else { return }
        var problem: String?
        do {
            lastLookup = try await ledger.value.record(record)
        } catch {
            problem = "The last lookup was not recorded: \(error)"
            log.error("ledger write failed: \(String(describing: error), privacy: .public)")
        }
        if request >= ledgerStatus.request { ledgerStatus = (request, problem) }
    }

    // MARK: - Shortcut

    /// Nil when the shortcut is registered; otherwise why it could not be.
    @discardableResult
    private func registerShortcut(_ shortcut: Shortcut) -> Hotkey.RegistrationFailed? {
        hotkey = nil  // released first: registration is exclusive, and would collide with itself
        do {
            hotkey = try hotkeys.register(shortcut) { [weak self] in self?.lookUpSelection() }
            hotkeyProblem = nil
            return nil
        } catch {
            hotkeyProblem = "\(shortcut.label()) is unavailable: \(error)"
            log.error("hotkey unavailable: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    /// Opens Settings **and brings XiaolaiDict forward with it.**
    ///
    /// `SettingsLink` opens the window and leaves the app where it was, which for an accessory app
    /// means behind whatever the reader is using: measured — after choosing Settings from the menu,
    /// the window was on screen at 900×450 and the frontmost app was still the terminal. The reader
    /// sees nothing happen, and the window then surfaces later when something else activates XiaolaiDict,
    /// which is how closing the shortcut recorder came to summon Settings "out of nowhere".
    ///
    /// Activating here does not contradict "no panel may activate XiaolaiDict": that is about the panels
    /// the reader did not ask for, mid-sentence in another app. This is a window they chose from a
    /// menu, and they are about to type into it — the shortcut field takes key presses.
    func showSettings(on pane: SettingsPane? = nil) {
        // Selected before the window opens, so the reader never sees the pane they did not ask for
        // and then a switch. `SettingsModel` owns the selection for exactly this reason.
        if let pane { settings.pane = pane }
        NSApplication.shared.activate()
        WindowActions.shared.settings?()
    }

    /// Opens the setup board, bringing XiaolaiDict forward with it.
    ///
    /// Activating is right here for the same reason it is right for Settings, and for the opposite
    /// reason to the panels: this is a window the reader asked for — by choosing it, or by
    /// installing the app — and one they are about to act in. "No panel may activate XiaolaiDict"
    /// governs the surfaces that appear while they are mid-sentence in another app.
    func showSetup() {
        NSApplication.shared.activate()
        WindowActions.shared.open?(id: XiaolaiDictScene.setupID)
    }

    /// Opens the board unasked, once in the life of an install.
    ///
    /// **Waits for the window actions before opening.** They are captured by `MenuBarLabel`'s
    /// `.task`, which has not run when the delegate finishes launching — and
    /// `WindowActions.shared.open` being nil at that moment opens nothing, silently, which is
    /// exactly how a drawer once reported success while never being drawn.
    ///
    /// The flag is written **after** the open, and it is the only thing this feature remembers. It
    /// decides whether the window appears by itself and never what the window shows, so a reader
    /// who opens it again later sees the same board with ticks against it.
    private func openSetupOnFirstLaunch() {
        guard !setupPresentation.hasOpenedBefore() else { return }
        Task { @MainActor [weak self] in
            guard await Instrument.settle(until: .seconds(5), { WindowActions.shared.open != nil })
            else { return }
            guard let self else { return }
            self.showSetup()
            self.setupPresentation.markOpened()
        }
    }

    /// The shortcut as it stands: the one registered, or — while the field in Settings is armed
    /// and nothing is registered — the one on disk.
    var currentShortcut: Shortcut { hotkey?.shortcut ?? shortcuts.load() }

    /// Whether XiaolaiDict is answering its shortcut. Read by the wiring tests, because "the field drew
    /// the right combination" and "the combination works" are different claims.
    var shortcutIsRegistered: Bool { hotkey != nil }

    /// Settings' shortcut control, as `XiaolaiDictUI` needs it.
    ///
    /// Handed over rather than reached for: registering a combination with the system is Carbon,
    /// which lives here, and `XiaolaiDictUI` draws rather than registers.
    var shortcutChoice: ShortcutChoice {
        ShortcutChoice(
            shortcut: currentShortcut,
            choose: { [weak self] shortcut in
                // An app that is gone registered nothing, and must not be reported as having done so.
                guard let self else { return String(localized: "The app is not running") }
                return chooseShortcut(shortcut)?.description
            },
            suspend: { [weak self] in self?.suspendShortcut($0) })
    }

    /// Stands the hot key down while the field is armed, and puts it back after.
    ///
    /// **Without this the one combination a reader most wants to change is the one they cannot.**
    /// A registered hot key is handled below the Cocoa event stream, so pressing the shortcut
    /// currently in use fires a lookup instead of reaching the field.
    ///
    /// Putting it back is conditional on nothing being registered, which makes it idempotent — the
    /// field disarms after a successful choice, and a `suspend(false)` that re-registered whatever
    /// was on disk would undo the choice a moment after the reader made it.
    func suspendShortcut(_ suspended: Bool) {
        if suspended {
            hotkey = nil
        } else if hotkey == nil {
            registerShortcut(shortcuts.load())
        }
    }

    /// Takes the reader's new shortcut: registers it, and saves it if it held. Nil means it held;
    /// otherwise the refusal says why — another app holds it, XiaolaiDict holds it for something else, or
    /// Carbon answered with a status — and the one that worked is left working.
    @discardableResult
    func chooseShortcut(_ chosen: Shortcut) -> Hotkey.RegistrationFailed? {
        let previous = currentShortcut
        guard chosen != previous || hotkey == nil else { return nil }
        if let refusal = registerShortcut(chosen) {
            // Keep the problem with the new one in view, and the old one working.
            let problem = hotkeyProblem
            registerShortcut(previous)
            hotkeyProblem = problem.map { "\($0) — still using \(previous.label())" }
            return refusal
        }
        do {
            try shortcuts.save(chosen)
        } catch {
            log.error("shortcut not saved: \(String(describing: error), privacy: .public)")
            hotkeyProblem = "\(chosen.label()) works now but was not saved: \(error)"
        }
        return nil
    }

    // MARK: - Menu

    // MARK: - What the scenes read

    var panelController: LookupPanelController { panel }
    var panelModel: LookupPanelModel { panel.model }
    var drawerModel: HistoryDrawerModel { drawer.model }

    /// What the settings window is showing — which pane, and the permission probe's last answer.
    /// Owned here rather than inside the window so `--settings-report` can select a pane from
    /// outside and measure what the window does about it.
    let settings = SettingsModel()
    /// The setup board's permission state, held here so `SetupView` keeps polling across opens and
    /// an instrument can read it back.
    let setup = SetupModel()

    /// The settings window, taken from the view inside it rather than searched for among
    /// `NSApp.windows`. A window found by matching its title is a window the report only *believes*
    /// it is measuring — and on a bad day it measures the menu bar's.
    @ObservationIgnored weak var settingsWindow: NSWindow?

    /// The reader's text size, and the scale every surface is drawn from. Owned here because it
    /// outlives any one window: the drawer, the panel and a pinned note all read the same one, and
    /// changing it has to move all of them at once.
    let appearance = Appearance()
    var drawerPlacement: CGRect? { drawer.placement }
    var drawerIsDrawn: Bool { drawer.isDrawnOnScreen }
    var drawerWindowFrame: CGRect { drawer.windowFrame }
    var drawerWindowLevel: Int { drawer.windowLevel }
    var drawerReload: Task<Void, Never>? { drawer.reload }
    var drawerHoldsEscape: Bool { drawer.isEscapeClaimed }

    // MARK: - What the menu reads

    /// The shortcut as the reader set it, or nil while there is none.
    var shortcutLabel: String? { hotkey?.shortcut.label() }
    var hoverIsWatching: Bool { hover.isWatching }
    var drawerIsVisible: Bool { drawer.isVisible }
    /// The primary dictionary's key, held as **stored** state rather than read from
    /// `UserDefaults` on each access.
    ///
    /// `@Observable` tracks stored properties; a computed one that reaches into the defaults
    /// registers no dependency, so a view reading it is never invalidated when it changes. The
    /// setup board is what exposed this: pressing "Use 牛津英汉汉英词典" saved the choice and the row
    /// went on saying the seat was empty, because nothing told the view to look again.
    private(set) var chosenDictionary: String?

    /// Everything the reader should be told, in the place they already look.
    var problems: [String] {
        [permissions.menuWarning, hotkeyProblem, ledgerStatus.problem].compactMap { $0 }
    }

    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when the
    /// menu is opened rather than at launch, and only once.
    func askForDictionaries(refreshing: Bool = false) async {
        permissions = await .probe()
        // Re-read from the store, not just written to on choosing. A lookup takes the primary
        // from disk, so a change made outside this process — a second copy, a `defaults write` —
        // would otherwise leave every window naming a dictionary that is no longer the one marks
        // are recorded against.
        let onDisk = primaryDictionary.load().chosen
        if onDisk != chosenDictionary { chosenDictionary = onDisk }
        guard refreshing || dictionaries == nil else { return }
        dictionaries = await client.dictionaries(reprobing: refreshing)
        // Set whatever the answer was, including none. "Asked and got nothing" is a state that
        // does not resolve, and a surface that cannot tell it from "still asking" waits forever.
        dictionariesAsked = true
    }

    /// Asks again, discarding the last answer first.
    ///
    /// The setup board tells a reader with no suitable dictionary to enable one in Dictionary.app,
    /// and then has to **notice when they come back** — which the once-only ask above could never
    /// do. Clearing first so the row says "asking" rather than showing yesterday's list while the
    /// question is in flight.
    ///
    /// **It reaches the service's cache too.** The probe runs once per service process, which is
    /// right for a menu opening and wrong here: this is the path that has to see a dictionary the
    /// reader has just enabled, so the request carries `reprobing` and the service discards its
    /// answer before re-probing.
    func refreshDictionaries() async {
        dictionaries = nil
        dictionariesAsked = false
        await askForDictionaries(refreshing: true)
    }

    func toggleHistory() {
        drawer.toggle()
    }

    func choosePrimaryDictionary(_ key: String?) {
        primaryDictionary.save(key)
        // Written to the observable copy too, or every view reading it goes on showing the old
        // choice until something else happens to invalidate it.
        chosenDictionary = key
    }

    /// The designer's 22 pt template, marked as a template so the system draws it in the menu bar's
    /// own colour; only its alpha is read. Outside the bundle (`swift run`) there is no resource,
    /// and a symbol beats an empty slot.
    static func menuBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "XiaolaiDict") }
        image.isTemplate = true
        image.size = NSSize(width: 22, height: 22)
        return image
    }

    // MARK: - Quitting

    /// SIGTERM — how `make run` asks a running copy to quit — goes through NSApplication's normal
    /// termination instead of ending the process mid-write.
    private func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        termination = source
    }
}
