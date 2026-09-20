import AppKit
import XiaolaiDictCore
import Observation
import os

/// The menu-bar app: a shortcut on a selection opens the lookup panel and records the lookup.
@Observable
@MainActor
final class XiaolaiDictApp: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")
    private let panel = LookupPanelController()
    private let client = DictionaryClient()
    private let primaryDictionary = PrimaryDictionaryStore()
    @ObservationIgnored private lazy var runner = makeRunner()
    @ObservationIgnored private lazy var drawer = makeDrawer()
    /// Milestone 2's trigger. Watches the pointer and reads the word under it when the reader
    /// rests with the modifier held; the reading itself is `HoverReader`, already tested.
    private let hover = HoverWatcher()
    /// The last permission probe. Cached because asking costs a ScreenCaptureKit round trip and
    /// `menuNeedsUpdate` cannot wait for one; the menu shows what was last known and asks again.
    private var permissions = PermissionsReport(states: [])

    /// The history drawer reads the ledger itself, bounded in both directions, and reports a
    /// failure rather than an empty drawer — the two must not look the same.
    private func makeDrawer() -> HistoryDrawerController {
        HistoryDrawerController { [weak self] in
            guard let opening = self?.ledger else { return .unavailable("The ledger is not open yet.") }
            do {
                let since = Date.now.addingTimeInterval(-HistoryDrawerController.window)
                return .entries(try await opening.value.recentLookups(
                    since: since, limit: HistoryDrawerController.cardLimit))
            } catch {
                return .unavailable("\(error)")
            }
        }
    }

    private func makeRunner() -> LookupRunner {
        let store = primaryDictionary
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
    private let recorder = ShortcutRecorder()
    private let shortcuts = ShortcutStore(defaults: .standard)
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
            NSApp.windows.first { $0.className.contains("StatusBar") }?.frame
        }
        Task { [weak self] in self?.permissions = await .probe() }
        hover.onWord = { [weak self] selection, at in self?.lookUpHovered(selection, at: at) }
        // Watching the pointer is something the reader must be able to stop, so it is a setting
        // and not a fact of running XiaolaiDict — on by default, because it is Milestone 2's whole point.
        if hoverEnabled { hover.start() }
        registerShortcut(shortcuts.load())
        quitOnTerminationSignal()
        // The report measures the running app rather than a controller built for the occasion,
        // because a SwiftUI scene exists only inside the app that declares it.
        if HistoryReport.isWanted {
            Task { exit(await HistoryReport.run(in: self).rawValue) }
        }
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

    @discardableResult
    private func registerShortcut(_ shortcut: Shortcut) -> Bool {
        hotkey = nil  // released first: registration is exclusive, and would collide with itself
        do {
            hotkey = try HotkeyCenter.shared.register(shortcut) { [weak self] in self?.lookUpSelection() }
            hotkeyProblem = nil
            return true
        } catch {
            hotkeyProblem = "\(shortcut.label()) is unavailable: \(error)"
            log.error("hotkey unavailable: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func changeShortcut() {
        let previous = hotkey?.shortcut ?? shortcuts.load()
        // Released while recording: pressed, it would look something up instead of being recorded.
        hotkey = nil
        recorder.record(current: previous) { [weak self] chosen in
            guard let self else { return }
            guard let chosen, chosen != previous else {
                registerShortcut(previous)
                return
            }
            guard registerShortcut(chosen) else {
                // Keep the problem with the new one in view, and the old one working.
                let problem = hotkeyProblem
                registerShortcut(previous)
                hotkeyProblem = problem.map { "\($0) — still using \(previous.label())" }
                return
            }
            do {
                try shortcuts.save(chosen)
            } catch {
                log.error("shortcut not saved: \(String(describing: error), privacy: .public)")
                hotkeyProblem = "\(chosen.label()) works now but was not saved: \(error)"
            }
        }
    }

    // MARK: - Menu

    // MARK: - What the scenes read

    var drawerModel: HistoryDrawerModel { drawer.model }
    var drawerPlacement: CGRect? { drawer.placement }
    var drawerReload: Task<Void, Never>? { drawer.reload }
    var drawerHoldsEscape: Bool { drawer.isEscapeClaimed }

    // MARK: - What the menu reads

    /// The shortcut as the reader set it, or nil while there is none.
    var shortcutLabel: String? { hotkey?.shortcut.label() }
    var hoverIsWatching: Bool { hover.isWatching }
    var drawerIsVisible: Bool { drawer.isVisible }
    var chosenDictionary: String? { primaryDictionary.load().chosen }

    /// Everything the reader should be told, in the place they already look.
    var problems: [String] {
        [permissions.menuWarning, hotkeyProblem, ledgerStatus.problem].compactMap { $0 }
    }

    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when the
    /// menu is opened rather than at launch, and only once.
    func askForDictionaries() async {
        permissions = await .probe()
        guard dictionaries == nil else { return }
        dictionaries = await client.dictionaries()
    }

    func toggleHistory() {
        drawer.toggle()
    }

    func choosePrimaryDictionary(_ key: String?) {
        primaryDictionary.save(key)
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
