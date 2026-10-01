import AppKit
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
    /// The dictionary the reader studies from and the list it was chosen out of — see
    /// `StudyDictionary`. Not built here: it needs the client, which means after `super.init()`.
    // swiftlint:disable:next implicitly_unwrapped_optional
    @ObservationIgnored private(set) var dictionary: StudyDictionary!
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
        preferences = defaults
        keepPolicyStore = LookupKeepPolicyStore(defaults: defaults)
        hover = HoverControl(defaults: defaults)
        // **The suite the app was given, not `.standard`.** Built inline against the real
        // preferences while `init(defaults:)` existed for exactly this reason, so every test that
        // touched the shortcut rewrote the reader's own — the objection this project makes to
        // driving the GUI on the building Mac, in a unit test.

        setupPresentation = SetupPresentationStore(defaults: defaults)
        self.models = models
        super.init()
        // After `super.init()`: the registrar's press handler captures `self`, which an
        // initialiser may not hand out before the object exists.
        shortcuts = ShortcutRegistrar(defaults: defaults, hotkeys: hotkeys) { [weak self] in
            self?.lookUpSelection()
        }
        dictionary = StudyDictionary(defaults: defaults) { [client] refreshing in
            await client.dictionaries(reprobing: refreshing)
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
            guard let opening = self?.recorder.store else { return .unavailable("The ledger is not open yet.") }
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
        drawer.model.discard = { [weak self] entry in
            guard let self, let opening = recorder.store else { throw LedgerError.corruptRow("ledger unavailable") }
            let receipt = try await opening.value.changeDisposition(.discarded, lookups: entry.lookupIDs, operation: UUID())
            LedgerChanges.shared.committed()
            drawer.refresh()
            return receipt
        }
        drawer.model.undoDiscard = { [weak self] operation in
            guard let self, let opening = recorder.store else { throw LedgerError.corruptRow("ledger unavailable") }
            let result = try await opening.value.undoDisposition(operation: operation)
            LedgerChanges.shared.committed()
            drawer.refresh()
            return result
        }
        drawer.model.keepForLearning = { [weak self] entry in
            guard let self, let opening = recorder.store else { return }
            Task {
                do {
                    if try await opening.value.keepHistory(entry.id) == nil { self.reopenReading(entry) }
                    LedgerChanges.shared.committed()
                    drawer.refresh()
                } catch { drawer.model.problem = error.localizedDescription }
            }
        }
        drawer.model.showInLibrary = { [weak self] entry in
            guard let self else { return }
            libraryModel.show(.history, lookup: entry.id)
            showLibrary()
        }
        return drawer
    }

    let preferences: UserDefaults
    let keepPolicyStore: LookupKeepPolicyStore

    private func makeRunner() -> LookupRunner {
        let store = dictionary.store
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
                guard let opening = await MainActor.run(body: { self?.recorder.store }) else { return PriorEncounters() }
                // A ledger that cannot be read costs the memory strip, never the lookup.
                return (try? await opening.value.priorEncounters(
                    of: lemma, before: before, language: language)) ?? PriorEncounters()
            },
            prewarm: { await models.prewarm() },
            keepPolicy: { [weak self] in self?.keepPolicyStore.load() ?? .automatic },
            initialRecording: { [weak self] row, request in self?.recorder.begin(row, request: request) })
    }
    /// The lookup shortcut and everything about registering it — see `ShortcutRegistrar`, which
    /// holds the three-state machine this delegate used to carry as four adjacent properties.
    // Set in `init` after `super.init()`, for the same reason as `dictionary`.
    // swiftlint:disable:next implicitly_unwrapped_optional
    @ObservationIgnored private(set) var shortcuts: ShortcutRegistrar!
    /// What reaches the reader's ledger, and what to tell them when nothing did — see
    /// `LookupRecorder`, which holds the three ordering rules this delegate used to interleave.
    let recorder = LookupRecorder()
    /// The lookup in flight. A new shortcut press cancels it: one lookup at a time.
    private var lookup: Task<Void, Never>?
    private var termination: (any DispatchSourceSignal)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside
        // the bundle behaves the same. Before *did* finish, so no window can flash as an ordinary
        // app's would.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onStudySense = { [weak self] encounter, request in
            self?.recorder.study(encounter, request: request)
        }
        // **Both, and in that order.** The reader met the sense *and* asked to study it; the ledger
        // keeps the two apart, so enrolling writes the encounter as well rather than instead.
        panel.onEnrolSense = { [weak self] encounter, request in
            self?.recorder.enrol(encounter, request: request, language: nil)
        }
        panel.onOpenDictionarySettings = { [weak self] in self?.showSettings(on: .dictionary) }
        recorder.start()
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
        // **The history is one click away, not two**, which needs this app to own its menu bar
        // item — `MenuBarItem` says why `MenuBarExtra` cannot. Installed in every run, instrument
        // or not: the end-to-end stages drive this menu, and without it there is none to drive.
        menuBar = MenuBarItem(app: self)
        menuBar?.install()
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

    /// A word the reader named rather than met — **Study** on a suggestion in the library.
    ///
    /// **No sentence, and the capture says so.** There is no reading behind a suggestion, only a
    /// lemma the reader has looked up on several days, so the context is `.missing` and the card
    /// draws no sentence rather than echoing the word back as if it were one.
    func lookUpWord(_ word: String) {
        lookUpHovered(
            Selection(text: word, sentence: nil, rangeInSentence: nil,
                      quality: .accessibility(.accessibilityTextRange, context: .missing),
                      place: ReadingPlace(bundleID: XiaolaiDictIdentity.app, name: nil)),
            at: UpPoint(NSEvent.mouseLocation))
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

    func reopenReading(_ row: ReadingEntry) {
        let selection = Selection(text: row.surface, sentence: row.cue == .none ? nil : row.sentence,
            rangeInSentence: row.sentenceRange,
            quality: row.quality ?? .accessibility(.accessibilityTextRange, context: .missing), place: row.place)
        let ticket = panel.newRequest(); lookup?.cancel()
        lookup = Task { await lookUp(selection, near: UpPoint(NSEvent.mouseLocation), requestedAt: row.at,
                                    ticket: ticket, existingLookupID: row.id) }
    }

    // MARK: - Hover

    /// Every answered lookup is recorded — a miss too, marked as one: it is usually a typo or a
    /// stray selection, which later triage can tell from a real gap. A lookup superseded before its
    /// answer arrived was never seen, and is not.
    private func lookUp(_ selection: Selection, near pointer: UpPoint, requestedAt: Date, ticket: PanelTicket, existingLookupID: Int? = nil) async {
        guard let row = await runner.run(selection, near: pointer, requestedAt: requestedAt, ticket: ticket, existingLookupID: existingLookupID) else { return }
        await recorder.record(row, request: ticket.number)
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
    /// Opens the Review window and brings it forward.
    ///
    /// **`NSApplication.shared.activate()`, unlike the panel and the drawer**, which must never
    /// activate the app. The reader chose this one from the menu and is about to type into it: a
    /// window that opened behind their reading, with keyboard shortcuts that go to the app in front,
    /// would be a review surface that cannot be reviewed in.
    func showReview() {
        log.notice("review: opened on request (app active before: \(NSApp.isActive, privacy: .public))")
        NSApplication.shared.activate()
        libraryModel.show(.review)
        WindowActions.shared.openWindow(id: XiaolaiDictScene.libraryID)
    }

    /// Opens the Library and brings it forward — a window the reader chose, and types into.
    func showLibrary() {
        log.notice("library: opened on request (app active before: \(NSApp.isActive, privacy: .public))")
        NSApplication.shared.activate()
        WindowActions.shared.openWindow(id: XiaolaiDictScene.libraryID)
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
    /// flag is written by the settings window becoming key on the setup pane instead, which is the
    /// reader actually having it.
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
            guard self?.settingsWindow?.isVisible != true else { return }
            self?.log.notice("setup: opened unasked at launch")
            // **Not `showSetup()`**, which activates. That request is refused at launch and can do
            // harm — the reason is in this method's own doc comment, and routing through the
            // activating path would have quietly undone it.
            self?.settings.pane = .setup
            WindowActions.shared.openSettings()
        }
    }

    /// The setup window, taken from the view inside it — the same way `settingsWindow` is.
    ///
    /// Held so the app can tell when the reader has actually seen the board: its becoming key is
    /// that moment, and it is what writes `SetupPresentationStore`'s flag.
    @ObservationIgnored private var setupKeyObserver: NSObjectProtocol?

    /// Watches the settings window for the reader actually having the board in front of them.
    ///
    /// **Becoming key, not being opened — and only while the setup pane is the one selected.**
    /// Measured on the E2E machine 2026-09-22: launched with another app in front, the board was
    /// drawn and that app stayed frontmost, because macOS's cooperative activation refuses focus to
    /// an app the reader did not just bring forward. Marking it seen on open recorded a board the
    /// reader never saw, and it never opened by itself again.
    ///
    /// The pane test is what the move to a settings pane added. This window is now opened for
    /// five other reasons, and a reader who came to change their text size has not seen setup.
    private func watchSettingsWindow() {
        if let setupKeyObserver { NotificationCenter.default.removeObserver(setupKeyObserver) }
        setupKeyObserver = nil
        guard let window = settingsWindow else { return }
        // Already key by the time the view reported its window — opened from the menu, say.
        if window.isKeyWindow { setupWasSeenIfShowing() }
        setupKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setupWasSeenIfShowing() }
        }
    }

    /// The window came forward. It counts as the board having been seen only if the board is what
    /// it is showing.
    private func setupWasSeenIfShowing() {
        guard settings.pane == .setup else { return }
        setupWasSeen()
    }

    /// The reader has the board in front of them. Idempotent: writing `true` twice is one fact.
    func setupWasSeen() {
        log.notice("setup: the board became key (app active: \(NSApp.isActive, privacy: .public))")
        setupPresentation.markOpened()
    }

    // MARK: - Menu

    // MARK: - What the scenes read

    var lookupRecorder: LookupRecorder { recorder }
    var panelController: LookupPanelController { panel }
    var panelModel: LookupPanelModel { panel.model }
    func refreshHistory() { drawer.refresh() }
    func attachHistoryWindow(_ window: NSWindow) { drawer.attach(window) }
    var drawerModel: HistoryDrawerModel { drawer.model }

    /// The Review window's model. **Built once and kept**, so a window closed mid-batch and reopened
    /// does not lose the sitting — and so the grade in flight when it closed has somewhere to land.
    /// `@ObservationIgnored` because the *reference* never changes and the model is `@Observable`
    /// itself: tracking it here would invalidate every scene in the app's body whenever a review
    /// card changed — the defect this file already carries a note about, one window over.
    @ObservationIgnored lazy var reviewModel = ReviewModel(
        store: { [weak self] in self?.recorder.store },
        primary: { [weak self] in self?.dictionary.store.load() ?? PrimaryDictionary() })

    /// The Library window's model, kept for the same reason.
    @ObservationIgnored lazy var libraryModel = LibraryModel(
        store: { [weak self] in self?.recorder.store },
        lookUp: { [weak self] word in self?.lookUpWord(word) },
        reopen: { [weak self] row in self?.reopenReading(row) }, defaults: preferences,
        primary: { [weak self] in self?.dictionary.store.load() ?? PrimaryDictionary() },
        primaryName: { [weak self] key in self?.dictionary.enabled?.first { $0.identity.key == key }?.identity.name },
        // The drawer's filter, read the same way: History is the reading history too.
        studying: { [weak self] in self?.hover.policy.scripts ?? HoverPolicy.defaultScripts })

    /// The erase command's model, in the Reading settings pane.
    @ObservationIgnored lazy var eraseModel = EraseModel(
        store: { [weak self] in self?.recorder.store })

    /// What the settings window is showing — which pane, and the permission probe's last answer.
    /// Owned here rather than inside the window so `--settings-report` can select a pane from
    /// outside and measure what the window does about it.
    let settings = SettingsModel()
    /// The setup board's permission state, held here so `SetupView` keeps polling across opens and
    /// an instrument can read it back.
    let setup = SetupModel()

    /// The menu bar item, held for the life of the process — `NSStatusBar` keeps its own reference,
    /// but the object driving it is ours and a released one leaves a dead icon.
    @ObservationIgnored private var menuBar: MenuBarItem?

    /// The settings window, taken from the view inside it rather than searched for among
    /// `NSApp.windows`. A window found by matching its title is a window the report only *believes*
    /// it is measuring — and on a bad day it measures the menu bar's.
    @ObservationIgnored weak var settingsWindow: NSWindow? {
        didSet { watchSettingsWindow() }
    }

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

    /// Everything the reader should be told, in the place they already look.
    var problems: [String] {
        [permissions.menuWarning, shortcuts.problem, recorder.problem].compactMap { $0 }
    }

    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when the
    /// menu is opened rather than at launch, and only once.
    /// What a surface opening needs refreshed: the permission probe the menu warns from, and the
    /// dictionary list and choice.
    ///
    /// **Composed here rather than inside one of them**, because "when the menu opens, refresh
    /// these" is the delegate's job and nothing else's. It used to be one method named
    /// `askForDictionaries` that also probed TCC — a caller wanting the list got a ScreenCaptureKit
    /// round trip it never asked for, and nothing in the name said so.
    func askForDictionaries(refreshing: Bool = false) async {
        let probed = await PermissionsReport.probe()
        // **Assigned only when it changed.** `@Observable` notifies on every assignment, equal or
        // not, and this runs each time the menu opens — so it re-rendered the open menu about 70 ms
        // later, every time, for nothing. A click landing while the menu re-renders is dropped:
        // measured 2 lost of 6 on a cold start, 0 of 8 once nothing was changing under the menu.
        if probed != permissions { permissions = probed }
        await dictionary.refresh(refreshing: refreshing)
    }


    func toggleHistory() {
        drawer.toggle()
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
