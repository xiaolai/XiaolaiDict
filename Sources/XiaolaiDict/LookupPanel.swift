import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
import os
import SwiftUI

/// One lookup, as the panel shows it — a container that fills in rather than a payload that is
/// awaited. Everything known the moment the reader pressed the shortcut is here at once; what the
/// dictionaries say arrives later, in the same panel.
struct LookupPresentation: Equatable {
    let term: String
    let lemma: Lemma
    /// The app, and the site, the word was read in.
    let source: String?
    let capture: CaptureQuality
    /// The reader's own sentence, where one was captured. The sentence pane explains this, and it
    /// is the only text the remote tier would ever be allowed to see.
    var sentence: String?
    /// Nil while the dictionaries are still being asked. The panel says so rather than showing an
    /// empty pane that reads like an entry.
    var outcome: LookupOutcome?
    /// Nil while the selector is still deciding. The entry is readable with all of its senses long
    /// before this arrives — the mark is late, the entry is not.
    var sense: SenseMark?
    /// Nil on a first lookup, and until the ledger has been read. Prior encounters, never prior
    /// meanings.
    var memory: MemoryStrip?
    /// The study items the reader has already met, so a sense read before can be marked (C3).
    var met: Set<StudyItem> = []
}

/// What the panel shows.
enum PanelContent {
    case lookup(LookupPresentation)
    /// Something the reader needs to know instead of an entry: no selection, no permission.
    case message(title: String, detail: String)

    /// What this panel is waiting for, in words, or nil when it is waiting for nothing.
    var waitingDescription: String? {
        guard case .lookup(let presentation) = self, presentation.outcome == nil else { return nil }
        return "Looking up “\(presentation.term)” in your dictionaries…"
    }

    enum Kind: Hashable {
        case lookup
        case message

        /// Exhaustive, so a new kind of content cannot quietly get another kind's size.
        var defaultSize: NSSize {
            switch self {
            case .lookup: NSSize(width: 760, height: 520)
            case .message: NSSize(width: 420, height: 150)
            }
        }

        var minimumSize: NSSize {
            switch self {
            case .lookup: NSSize(width: 480, height: 300)
            case .message: NSSize(width: 320, height: 120)
            }
        }
    }

    var kind: Kind {
        switch self {
        case .lookup: .lookup
        case .message: .message
        }
    }
}

/// What a lookup needs of the panel: present it, fill it in, and say whether this lookup is still
/// the one the reader is waiting on. `LookupPanelController` is it in the app; a test puts a
/// recorder in its place, because the *order* — panel first, content later — is the thing under
/// test and cannot be seen from outside.
@MainActor
protocol LookupPanelPresenting: AnyObject {
    func newRequest() -> PanelTicket
    func isCurrent(_ ticket: PanelTicket) -> Bool
    func show(_ content: PanelContent, near pointer: NSPoint, for ticket: PanelTicket)
    /// Replaces a shown panel's content without moving or resizing it. A panel the reader has
    /// dragged somewhere must not jump when its entry arrives.
    func update(_ content: PanelContent, for ticket: PanelTicket)
}

/// A request for the panel. A newer request supersedes every older one, and closing the panel
/// supersedes them all: a result that arrives late is dropped, not shown over a newer one or
/// reopened after the reader dismissed it.
struct PanelTicket: Equatable {
    let number: Int
}

/// The lookup panel: floats over the app being read — in its Space, even full screen — without
/// activating XiaolaiDict or taking keyboard focus, so typing stays where the reader left it. A click in
/// the panel focuses it; Escape closes it either way.
@MainActor
final class LookupPanelController: LookupPanelPresenting {
    private var panel: LookupWindow?
    private var current = 0
    private var shownKind: PanelContent.Kind?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
    /// Sizes the reader chose by resizing, per kind of content; kept for the next panel of that kind.
    private var chosenSizes: [PanelContent.Kind: NSSize] = [:]
    private let escape: EscapeKey
    /// Pinned notes outlive the panel that made them, so they are owned here rather than by a view.
    private let notes = PinnedNoteController()
    /// Where the last panel was put, so a note pinned from it lands beside it.
    private var lastPointer: NSPoint = .zero

    init(hotkeys: HotkeyCenter = .shared) {
        escape = EscapeKey(hotkeys: hotkeys)
    }

    /// What the reader asked to study, as they ask for it. Set by the app, which owns the ledger.
    var onStudySense: (@MainActor (SenseEncounter) -> Void)?

    /// The panel's view, with the app's own capabilities handed to it.
    private func view(_ content: PanelContent) -> some View {
        PanelView(content: content)
            .environment(\.pinNote) { [notes, lastPointer] note in notes.pin(note, near: lastPointer) }
            .environment(\.studySense) { [weak self] encounter in self?.onStudySense?(encounter) }
    }

    func newRequest() -> PanelTicket {
        current += 1
        return PanelTicket(number: current)
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { ticket.number == current }

    func show(_ content: PanelContent, near pointer: NSPoint, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        lastPointer = pointer
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let kind = content.kind
        panel.contentView = NSHostingView(rootView: view(content))
        panel.contentMinSize = kind.minimumSize
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: kind.defaultSize)
        let size = chosenSizes[kind] ?? kind.defaultSize
        panel.setFrame(PanelPlacement.frame(for: size, near: pointer, within: visible), display: true)
        shownKind = kind
        panel.orderFrontRegardless()
        escape.claim { [weak self] in self?.panel?.close() }
    }

    /// Fills in a panel already on screen. Same kind, so the size and the minimum stay as they
    /// were, and the frame is not touched: the reader may have moved or resized it while waiting.
    func update(_ content: PanelContent, for ticket: PanelTicket) {
        guard isCurrent(ticket), let panel, shownKind == content.kind else {
            // A kind that changed mid-lookup is a mistake in the caller, not something to paper
            // over by silently resizing the panel under the reader.
            if isCurrent(ticket), let shownKind, shownKind != content.kind {
                log.error("panel update changed kind from \(String(describing: shownKind), privacy: .public)")
            }
            return
        }
        panel.contentView = NSHostingView(rootView: view(content))
    }

    private func makePanel() -> LookupWindow {
        let panel = LookupWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // Over a full-screen app and in whichever Space the reader is in; not a window to cycle to.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Key only when the reader clicks into it — never just because it appeared.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.onClose = { [weak self] in self?.closed() }
        // Only a size the reader chose by dragging is remembered — not one the panel was given, or
        // shrunk to, to fit a smaller screen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberChosenSize() }
        }
        return panel
    }

    /// Everything still running for the panel is now stale.
    private func closed() {
        shownKind = nil
        current += 1
        escape.release()
    }

    private func rememberChosenSize() {
        guard let panel, let shownKind else { return }
        chosenSizes[shownKind] = panel.frame.size
    }

}

/// Escape, for as long as the panel shows. The panel is not key — it must not take focus from the
/// app being read — so Escape would go to that app. Taken as a hot key instead, it comes to XiaolaiDict
/// without XiaolaiDict being active, needs no permission, and is consumed: the app being read never sees
/// an Escape meant for the panel. Released the moment the panel closes, so Escape is the app's
/// again. (A global event monitor would do neither: it cannot consume the key, and without
/// Accessibility it never hears it.)
@MainActor
final class EscapeKey {
    static let shortcut = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    private let hotkeys: HotkeyCenter
    private var held: Hotkey?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")

    init(hotkeys: HotkeyCenter) {
        self.hotkeys = hotkeys
    }

    var isHeld: Bool { held != nil }

    func claim(_ action: @escaping @MainActor () -> Void) {
        guard held == nil else { return }
        do {
            held = try hotkeys.register(Self.shortcut, action: action)
        } catch {
            // The panel still has its close button; Escape stays with the app being read.
            log.error("Escape not claimed for the panel: \(String(describing: error), privacy: .public)")
        }
    }

    func release() {
        held = nil
    }
}

/// Where the panel goes: below and to the right of the pointer, and wholly on the screen — shrunk
/// first when the screen is smaller than the panel, so no clamp can push it off an edge.
enum PanelPlacement {
    static let margin: CGFloat = 8

    static func frame(for size: NSSize, near pointer: NSPoint, within visible: NSRect) -> NSRect {
        let size = NSSize(
            width: max(0, min(size.width, visible.width - 2 * margin)),
            height: max(0, min(size.height, visible.height - 2 * margin)))
        let origin = NSPoint(
            x: clamp(pointer.x + 12, visible.minX + margin, visible.maxX - margin - size.width),
            y: clamp(pointer.y - 24 - size.height, visible.minY + margin, visible.maxY - margin - size.height))
        return NSRect(origin: origin, size: size)
    }

    /// Bounds in the wrong order — a screen narrower than its margins — pin to the lower one.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

final class LookupWindow: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        onClose?()
        super.close()
    }
}
