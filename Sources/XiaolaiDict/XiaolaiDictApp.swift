import AppKit
import DictionaryModel
import XiaolaiDictBase
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
    /// The local model: its store, its download, the service that runs it, and the lifecycle
    /// between them. Owned by `LocalModelCoordinator`, not by this delegate.
    let models: LocalModelCoordinator
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
    /// The suite this app was built with — the reader's own, or a test's temporary one.
    /// **Kept, not just passed through.** Every store below was handed it at init while
    /// `hoverEnabled` went on reading `UserDefaults.standard`, which is how a unit test came
    /// to be able to switch the reader's hover off.
    @ObservationIgnored private let defaults: UserDefaults

    /// Everything the reader can do to hover, and one value per thing — see `HoverControl`, where
    /// every member has already been a defect about there being two copies or a fresh one per call.
    let hover: HoverControl

    /// **`init()` must exist, and must be written out.** `@NSApplicationDelegateAdaptor`
    /// instantiates the delegate through the Objective-C runtime, which looks for `init` and finds
    /// `NSObject`'s — not a Swift designated initializer that happens to have a default argument
    /// for every parameter. Declaring `init(defaults:)` alone therefore suppressed the inherited
    /// `init()` and every launch died with "Use of unimplemented initializer", while the unit
    /// suite stayed green because tests call the initializer Swift can see.
    override convenience init() {
        // The one place the real model directory and the real XPC service are reached for.
        self.init(defaults: .standard, models: LocalModelCoordinator(defaults: .standard))
    }

    /// `defaults` is a parameter so a test can be given a suite of its own. Without it, asserting
    /// anything about the reader's settings means writing to the real ones — a test suite that
    /// changes the machine it runs on, which is the same objection the project makes to driving
    /// the GUI on the building Mac.
    /// `models` is a parameter for the same reason `defaults` is: without it a test would read — and
    /// a download would write — the reader's own model directory, and would open a real XPC session
    /// to the service. **It has no default**, because a default is what made that happen anyway: the
    /// comment said what the parameter was for while `nil` quietly built the production coordinator
    /// for every test that omitted it. `init()` supplies the real one.
    init(
        defaults: UserDefaults, hotkeys: HotkeyCenter = .shared,
        models: LocalModelCoordinator
    ) {
        // Loaded once, here, rather than lazily: `@Observable` makes stored properties computed,
        // so there is no `lazy` to be had — and a per-use load would be the mouse-move decode
        // this property exists to avoid.
        self.defaults = defaults
        hover = HoverControl(defaults: defaults)
        // **The suite the app was given, not `.standard`.** Built inline against the real
        // preferences while `init(defaults:)` existed for exactly this reason, so every test that
        // touched the shortcut rewrote the reader's own — the objection this project makes to
        // driving the GUI on the building Mac, in a unit test.

        setupPresentation = SetupPresentationStore(defaults: defaults)
        let primary = PrimaryDictionaryStore(defaults: defaults)
        primaryDictionary = primary
        chosenDictionary = primary.load().chosen
        self.models = models
        super.init()
        // After `super.init()`: the registrar's press handler captures `self`, which an
        // initialiser may not hand out before the object exists.
        shortcuts = ShortcutRegistrar(defaults: defaults, hotkeys: hotkeys) { [weak self] in
            self?.lookUpSelection()
        }
    }

    /// The last permission probe. Cached because asking costs a ScreenCaptureKit round trip and
    /// `menuNeedsUpdate` cannot wait for one; the menu shows what was last known and asks again.
    private var permissions = PermissionsReport(states: [])

    /// Whether a selection may be read, and asking for it where the reader never has been.
    /// Injected so a test can drive the refusal branch without touching this Mac's grant.
    @ObservationIgnored var accessibility = AccessibilityAccess.system

    /// The history drawer reads the ledger itself, bounded in both directions, and reports a
    /// failure rather than an empty drawer — the two must not look the same.
    private func makeDrawer() -> HistoryDrawerController {
        let drawer = HistoryDrawerController { [weak self] in
            guard let opening = self?.ledger else { return .unavailable("The ledger is not open yet.") }
            // **The same setting the hover gate asks, read at open time.** A reader who widens the
            // scripts they study sees the words already in the ledger the next time they open the
            // drawer — the filter is on the reading, not on the recording, so nothing was thrown
            // away while the setting was narrow.
            let studying = self?.hover.policy.scripts ?? HoverPolicy.defaultScripts
            do {
                let since = Date.now.addingTimeInterval(-HistoryDrawerController.window)
                return .entries(try await opening.value.recentLookups(
                    since: since, limit: HistoryDrawerController.cardLimit, studying: studying))
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
        let models = models
        return LookupRunner(
            client: client, panel: panel, primary: { store.load() },
            // The local model first, wherever it is downloaded; Apple's on-device model while it is
            // not — pending, declined, or too big for what is free now; `NLEmbedding` beneath both.
            selector: models.senseLadder,
            priorEncounters: { [weak self] lemma, before, language in
                guard let opening = await MainActor.run(body: { self?.ledger }) else { return PriorEncounters() }
                // A ledger that cannot be read costs the memory strip, never the lookup.
                return (try? await opening.value.priorEncounters(
                    of: lemma, before: before, language: language)) ?? PriorEncounters()
            },
            prewarm: { await models.prewarm() })
    }
    /// The enabled dictionaries, as the service last reported them. Nil until it has been asked:
    /// the menu says it does not know rather than showing a list it made up.
    var dictionaries: [DictionaryCapability]?
    /// Whether the service has been asked and has finished answering — see `DictionaryChoice`.
    private(set) var dictionariesAsked = false
    /// The lookup shortcut and everything about registering it — see `ShortcutRegistrar`, which
    /// holds the three-state machine this delegate used to carry as four adjacent properties.
    @ObservationIgnored private(set) var shortcuts: ShortcutRegistrar!
    /// Carbon's hot-key plumbing, injected so a test never registers a real global shortcut —
    /// which would take it from the reader for as long as the suite ran.
    /// Opened on a background task at launch: file and database work — a migration, on the first
    /// launch after an update — must not hold up the menu bar.
    private var ledger: Task<LedgerStore, any Error>?
    /// The lookup in flight. A new shortcut press cancels it: one lookup at a time.
    private var lookup: Task<Void, Never>?
    private var termination: (any DispatchSourceSignal)?

    /// The ledger's state as of the newest request to finish recording — not of whichever write
    /// happened to finish last.
    private var ledgerStatus: (request: Int, problem: String?) = (0, nil)

    /// Which lookup a reader's tap belongs to — see `SenseTapQueue`.
    private var taps = SenseTapQueue()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside
        // the bundle behaves the same. Before *did* finish, so no window can flash as an ordinary
        // app's would.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onStudySense = { [weak self] encounter, request in self?.study(encounter, request: request) }
        panel.onOpenDictionarySettings = { [weak self] in self?.showSettings(on: .dictionary) }
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
        hover.watcher.onWord = { [weak self] selection, at in self?.lookUpHovered(selection, at: at) }
        // Watching the pointer is something the reader must be able to stop, so it is a setting
        // and not a fact of running XiaolaiDict — on by default, because it is Milestone 2's whole point.
        // **Not in an instrument run.** `--history-report` captures the screen, and a hover that
        // fired meanwhile would capture too — two captures at once deadlock, measured six trials
        // of six. An instrument measures the app; it has no reader whose pointer needs watching.
        armTriggersWhenThereIsAWindowToDrawInto()
        // **Not in an instrument run.** An instrument measures the app; a window opening at it
        // unasked is a window in front of whatever it was about to capture.
        if !Self.isInstrumented { openSetupOnFirstLaunch() }
        quitOnTerminationSignal()
        // One switch, so a fourth windowed instrument is a case the compiler demands rather than a
        // line somebody has to remember to add here as well as in three other places.
        if let instrument = Instruments.wanted {
            Task { [weak self] in
                guard let self else { return }
                let status: CommandStatus = switch instrument {
                case .history: await HistoryReport.run(in: self)
                case .settings: await SettingsReport.run(in: self)
                case .panel: await PanelReport.run(in: self)
                }
                exit(status.rawValue)
            }
        }
    }

    /// Whether the triggers have been armed, so a second capture does not arm them twice.
    private var triggersArmed = false

    /// **The hot key and hover are armed once there is a window to draw into, never at launch.**
    ///
    /// `WindowActions` is captured by `MenuBarLabel`'s `.task`, which runs *after*
    /// `applicationDidFinishLaunching` — the app already knew this, since `openSetupOnFirstLaunch`
    /// waits five seconds for it. Registering the hot key before it meant a shortcut pressed in that
    /// window opened no panel, and the lookup ran to completion and wrote a ledger row anyway.
    ///
    /// Four orderings have to be harmless, because `.task` is tied to a view's lifetime and not to
    /// any documented contract with the app delegate:
    ///
    /// - **Capture before this runs.** `areWired` is checked here, so it arms immediately.
    /// - **Capture after.** `onCapture` arms it.
    /// - **Capture twice.** `triggersArmed` makes the second a no-op.
    /// - **Capture never.** The fallback arms after five seconds, with a fault logged. The shortcut
    ///   then registers against a panel that cannot draw — but `LookupPanelController.show` refuses
    ///   and `LookupRunner` stops, so the cost is a fault in the log rather than a phantom lookup.
    ///   A shortcut a reader has set and that silently does not exist is worse than one that fails
    ///   loudly.
    private func armTriggersWhenThereIsAWindowToDrawInto() {
        WindowActions.shared.onCapture = { [weak self] in self?.armTriggers(because: "the window actions arrived") }
        if WindowActions.shared.areWired { armTriggers(because: "the window actions were already there") }
        Task { @MainActor [weak self] in
            guard await WindowActions.shared.ready() else {
                self?.log.fault("windows: no actions after 5 s; arming the shortcut anyway")
                self?.armTriggers(because: "the fallback deadline passed")
                return
            }
        }
    }

    /// **Not private: `WindowActionsWiringTests` drives it.** What this method does is the wire,
    /// and the lesson recorded twice in `AGENTS.md` is that only a test of the wire catches a
    /// dependency nothing reads.
    func armTriggers(because reason: String) {
        guard !triggersArmed else { return }
        triggersArmed = true
        log.notice("triggers: arming because \(reason, privacy: .public)")
        // Watching the pointer is something the reader must be able to stop, so it is a setting
        // and not a fact of running XiaolaiDict — on by default, because it is Milestone 2's whole point.
        // **Not in an instrument run.** `--history-report` captures the screen, and a hover that
        // fired meanwhile would capture too — two captures at once deadlock, measured six trials
        // of six. An instrument measures the app; it has no reader whose pointer needs watching.
        if !Self.isInstrumented { hover.startIfEnabled() }
        // **Only if nothing is registered and nothing is suspended.** A capture landing while the
        // reader has the shortcut recorder armed would otherwise take the combination back from the
        // field they are typing into — `suspend(true)` releases the hot key precisely so the key
        // reaches the field, and registering puts it back unconditionally.
        if !shortcuts.isRegistered, !shortcuts.isSuspended { shortcuts.registerSaved() }
    }

    /// Whether this process is an instrument rather than the reader's app — see `Instruments`.
    static var isInstrumented: Bool { Instruments.isInstrumented }

    // MARK: - Looking up

    func lookUpSelection() {
        let pointer = UpPoint(NSEvent.mouseLocation)
        let requestedAt = Date.now
        let ticket = panel.newRequest()
        lookup?.cancel()
        // Asked, not assumed: without Accessibility there is no selection to read, and saying so
        // is better than an empty panel. **Through the one owner** — this line used to call
        // `AXIsProcessTrustedWithOptions` with its own copy of the option key literal, which was
        // the third implementation of one question and the second instance of the class
        // `ScreenRecordingAccess` exists to close.
        guard accessibility.ensure() == .granted else {
            panel.show(.accessibilityIsOff, near: pointer, for: ticket)
            return
        }
        guard let app = FrontApp.frontmost() else {
            panel.show(.frontmostAppUnknown, near: pointer, for: ticket)
            return
        }
        lookup = Task {
            switch await SelectionReader.read(from: app) {
            case .nothing(let reason):
                panel.show(.nothingToLookUp(reason), near: pointer, for: ticket)
            case .selected(let selection):
                await lookUp(selection, near: pointer, requestedAt: requestedAt, ticket: ticket)
            }

        }
    }

    /// A word the reader rested on. The same path as the shortcut from here: one lookup at a
    /// time, and a newer one supersedes whatever was still arriving.
    /// **Not private: `--panel-report` drives it.** That report measures the panel's window and the
    /// cost of clicking it, and a panel filled by a presentation the report made up would be a
    /// different card from the one the reader gets — the footer's controls exist only where a
    /// dictionary answered. So the instrument goes in by the same door hover does.
    func lookUpHovered(_ selection: Selection, at pointer: UpPoint) {
        let requestedAt = Date.now
        let ticket = panel.newRequest()
        lookup?.cancel()
        lookup = Task { await lookUp(selection, near: pointer, requestedAt: requestedAt, ticket: ticket) }
    }

    // MARK: - Hover

    /// Every answered lookup is recorded — a miss too, marked as one: it is usually a typo or a
    /// stray selection, which later triage can tell from a real gap. A lookup superseded before its
    /// answer arrived was never seen, and is not.
    private func lookUp(_ selection: Selection, near pointer: UpPoint, requestedAt: Date, ticket: PanelTicket) async {
        guard let row = await runner.run(selection, near: pointer, requestedAt: requestedAt, ticket: ticket) else { return }
        await record(row, request: ticket.number)
    }

    /// A sense the reader tapped. Recorded as theirs — `chosen_by: reader` — which the ledger
    /// keeps apart from the selector's guesses, because a hypothesis and a fact must never merge.
    private func study(_ encounter: SenseEncounter, request: Int) {
        guard ledger != nil, let lookup = taps.tapped(encounter, request: request) else { return }
        write(encounter, for: lookup)
    }

    private func write(_ encounter: SenseEncounter, for lookup: Int) {
        guard let ledger else { return }
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
            let id = try await ledger.value.record(record)
            // Whatever the reader tapped while this row was being written now has somewhere to go.
            for encounter in taps.recorded(request: request, id: id) { write(encounter, for: id) }
        } catch {
            problem = "The last lookup was not recorded: \(error)"
            log.error("ledger write failed: \(String(describing: error), privacy: .public)")
        }
        if request >= ledgerStatus.request { ledgerStatus = (request, problem) }
    }

    // MARK: - Shortcut

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
        // **The Dictionary pane lists what the service reports, and nothing asks the service until a
        // menu is opened.** So a route that opens it directly could leave the pane reading "Asking the
        // dictionary service…" for good. Started here rather than at each call site: the menu and the
        // setup board happen to ask before they get here, `--settings-report` had to remember to, and
        // the panel's new route would have been the third place to forget. Fire-and-forget on purpose —
        // opening the window must not wait on a probe that parses real entries.
        if pane == .dictionary { Task { await askForDictionaries() } }
        NSApplication.shared.activate()
        WindowActions.shared.openSettings()
    }

    /// Opens the setup board, bringing XiaolaiDict forward with it.
    ///
    /// Activating is right here for the same reason it is right for Settings, and for the opposite
    /// reason to the panels: this is a window the reader asked for, from the menu or from Settings,
    /// and one they are about to act in. "No panel may activate XiaolaiDict" governs the surfaces
    /// that appear while they are mid-sentence in another app. The launch-time open does **not**
    /// come through here — see `openSetupOnFirstLaunch` for why it must not ask to activate.
    func showSetup() {
        // Logged, because "the board did not come forward" has two very different causes — the
        // request never arrived, or it arrived and activation was refused — and only the app can
        // say which. An end-to-end run could not tell them apart from outside.
        log.notice("setup: opened on request (app active before: \(NSApp.isActive, privacy: .public))")
        NSApplication.shared.activate()
        WindowActions.shared.openWindow(id: XiaolaiDictScene.setupID)
    }

    /// Opens the board unasked, once in the life of an install.
    ///
    /// **Waits for the window actions before opening.** They are captured by `MenuBarLabel`'s
    /// `.task`, which has not run when the delegate finishes launching — and
    /// `WindowActions.shared.open` being nil at that moment opens nothing, silently, which is
    /// exactly how a drawer once reported success while never being drawn.
    ///
    /// **Opening is not the same as being seen, so this does not write the flag.** Measured on the
    /// E2E machine 2026-09-22: launched with another app in front, the board was drawn — the
    /// compositor listed it — and that app stayed frontmost, because macOS's cooperative activation
    /// refuses focus to an app the reader did not just bring forward. Marking the flag here recorded
    /// the board as shown to a reader who never saw it, and it never opened by itself again. The
    /// flag is written by `setupWindow` becoming key instead, which is the reader actually having it.
    ///
    /// Not forcing activation is deliberate: stealing focus at launch — at login, above whatever the
    /// reader was doing — is exactly what cooperative activation exists to stop. The board waits
    /// behind, and it tries again at the next launch until it has been seen.
    ///
    /// **And it does not ask to activate.** That request is refused at launch — measured in every
    /// E2E run, the board drawn behind the app in front — so it does nothing for the reader, and it
    /// can do harm: in the stage, a reader's own click on Set Up… arriving just before this task ran
    /// was intermittently left in the background, the board drawn, main and focused inside
    /// XiaolaiDict, and the frontmost app never changing. Ten of ten clicks came forward with this
    /// open switched off. A launch the reader started is activated by LaunchServices already, so the
    /// window comes forward there without asking; an unasked launch has no business asking.
    private func openSetupOnFirstLaunch() {
        guard !setupPresentation.hasOpenedBefore() else { return }
        Task { @MainActor [weak self] in
            guard await Instrument.settle(until: .seconds(5), { WindowActions.shared.open != nil })
            else { return }
            // Opened from the menu in the meantime: the reader already has it, and ordering it again
            // from here would only be a second, unasked request.
            guard self?.setupWindow?.isVisible != true else { return }
            self?.log.notice("setup: opened unasked at launch")
            WindowActions.shared.openWindow(id: XiaolaiDictScene.setupID)
        }
    }

    /// The setup window, taken from the view inside it — the same way `settingsWindow` is.
    ///
    /// Held so the app can tell when the reader has actually seen the board: its becoming key is
    /// that moment, and it is what writes `SetupPresentationStore`'s flag.
    @ObservationIgnored weak var setupWindow: NSWindow? {
        didSet { watchSetupWindow() }
    }
    @ObservationIgnored private var setupKeyObserver: NSObjectProtocol?

    private func watchSetupWindow() {
        if let setupKeyObserver { NotificationCenter.default.removeObserver(setupKeyObserver) }
        setupKeyObserver = nil
        guard let window = setupWindow else { return }
        // Already key by the time the view reported its window — opened from the menu, say.
        if window.isKeyWindow { setupWasSeen() }
        setupKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setupWasSeen() }
        }
    }

    /// The reader has the board in front of them. Idempotent: writing `true` twice is one fact.
    func setupWasSeen() {
        log.notice("setup: the board became key (app active: \(NSApp.isActive, privacy: .public))")
        setupPresentation.markOpened()
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
    var drawerReload: Task<Void, Never>? { drawer.reload }
    var drawerHoldsEscape: Bool { drawer.isEscapeClaimed }

    // MARK: - What the menu reads

    /// The shortcut as the reader set it, or nil while there is none.
    var shortcutLabel: String? { shortcuts.label }

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
        [permissions.menuWarning, shortcuts.problem, ledgerStatus.problem].compactMap { $0 }
    }

    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when the
    /// menu is opened rather than at launch, and only once.
    func askForDictionaries(refreshing: Bool = false) async {
        // **Assigned only when it changed.** `@Observable` notifies on every assignment, equal or
        // not, and this runs each time the menu opens — so it re-rendered the open menu about 70 ms
        // later, every time, for nothing. Measured on the E2E machine 2026-09-22: a click landing
        // while the menu re-renders is dropped — `menu-click` reported the click, the app never saw
        // it — 2 lost of 6 on a cold start, 0 of 8 once nothing was changing under the menu.
        let probed = await PermissionsReport.probe()
        if probed != permissions { permissions = probed }
        // Re-read from the store, not just written to on choosing. A lookup takes the primary
        // from disk, so a change made outside this process — a second copy, a `defaults write` —
        // would otherwise leave every window naming a dictionary that is no longer the one marks
        // are recorded against.
        let onDisk = primaryDictionary.load().chosen
        if onDisk != chosenDictionary { chosenDictionary = onDisk }
        guard refreshing || dictionaries == nil else { return }
        let found = await client.dictionaries(reprobing: refreshing)
        // Same reason. A refresh that finds the same dictionaries must not re-render an open menu.
        if found != dictionaries { dictionaries = found }
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
