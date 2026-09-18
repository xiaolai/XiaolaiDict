import AppKit
import XiaolaiDictCore
import os

/// The menu-bar app: a shortcut on a selection opens the lookup panel and records the lookup.
@MainActor
final class XiaolaiDictApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")
    private let client = DictionaryClient()
    private let panel = LookupPanelController()
    private let recorder = ShortcutRecorder()
    private let shortcuts = ShortcutStore(defaults: .standard)
    private var statusItem: NSStatusItem?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
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
        registerShortcut(shortcuts.load())
        quitOnTerminationSignal()
    }

    // MARK: - Looking up

    @objc private func lookUpSelection() {
        let pointer = NSEvent.mouseLocation
        let requestedAt = Date.now
        let ticket = panel.newRequest()
        lookup?.cancel()
        // Asked, not assumed: without Accessibility there is no selection to read, and saying so
        // is better than an empty panel.
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            panel.show(.message(
                title: "XiaolaiDict needs Accessibility access",
                detail: "It reads your selection through Accessibility. Allow XiaolaiDict in System Settings → Privacy & Security → Accessibility, then press the shortcut again."),
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

    /// Every answered lookup is recorded — a miss too, marked as one: it is usually a typo or a
    /// stray selection, which later triage can tell from a real gap. A lookup superseded before its
    /// answer arrived was never seen, and is not.
    private func lookUp(_ selection: Selection, near pointer: NSPoint, requestedAt: Date, ticket: PanelTicket) async {
        let lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        guard let outcome = try? await client.lookup(selection.text), panel.isCurrent(ticket) else { return }
        let source = [selection.appName, selection.url.flatMap { URL(string: $0)?.host() }]
            .compactMap { $0 }.joined(separator: " · ")
        panel.show(
            .lookup(term: selection.text, lemma: lemma, source: source, capture: selection.quality, outcome: outcome),
            near: pointer, for: ticket)
        await record(LookupRecord(
            surface: selection.text, lemma: lemma.text, context: selection.sentence ?? selection.text,
            sourceApp: selection.bundleID, sourceURL: selection.url, lookedUpAt: requestedAt,
            result: outcome.result, answeredBy: outcome.answeredBy, quality: selection.quality), request: ticket.number)
    }

    private func record(_ record: LookupRecord, request: Int) async {
        guard let ledger else { return }
        var problem: String?
        do {
            try await ledger.value.record(record)
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

    @objc private func changeShortcut() {
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

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = Self.menuBarImage() {
            item.button?.image = image
        } else {
            item.button?.title = "XiaolaiDict"  // no image at all is still no reason to crash
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Rebuilt on every open, so a problem that appeared since launch is shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let lookUp = menu.addItem(withTitle: "Look Up Selection", action: #selector(lookUpSelection), keyEquivalent: "")
        lookUp.target = self
        if let hotkey { lookUp.title = "Look Up Selection    \(hotkey.shortcut.label())" }
        menu.addItem(withTitle: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "").target = self
        for problem in [hotkeyProblem, ledgerStatus.problem].compactMap({ $0 }) {
            let item = menu.addItem(withTitle: problem, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit XiaolaiDict", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The designer's 22 pt template, marked as a template so the system draws it in the menu bar's
    /// own colour; only its alpha is read. Outside the bundle (`swift run`) there is no resource,
    /// and a symbol beats an empty slot.
    private static func menuBarImage() -> NSImage? {
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
