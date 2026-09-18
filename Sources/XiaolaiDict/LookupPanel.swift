import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
import os
import SwiftUI

/// What the panel shows.
enum PanelContent {
    case lookup(term: String, lemma: Lemma, source: String?, capture: CaptureQuality, outcome: LookupOutcome)
    /// Something the reader needs to know instead of an entry: no selection, no permission.
    case message(title: String, detail: String)

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
final class LookupPanelController {
    private var panel: LookupWindow?
    private var current = 0
    private var shownKind: PanelContent.Kind?
    /// Sizes the reader chose by resizing, per kind of content; kept for the next panel of that kind.
    private var chosenSizes: [PanelContent.Kind: NSSize] = [:]
    private let escape: EscapeKey

    init(hotkeys: HotkeyCenter = .shared) {
        escape = EscapeKey(hotkeys: hotkeys)
    }

    func newRequest() -> PanelTicket {
        current += 1
        return PanelTicket(number: current)
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { ticket.number == current }

    func show(_ content: PanelContent, near pointer: NSPoint, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let kind = content.kind
        panel.contentView = NSHostingView(rootView: PanelView(content: content))
        panel.contentMinSize = kind.minimumSize
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: kind.defaultSize)
        let size = chosenSizes[kind] ?? kind.defaultSize
        panel.setFrame(PanelPlacement.frame(for: size, near: pointer, within: visible), display: true)
        shownKind = kind
        panel.orderFrontRegardless()
        escape.claim { [weak self] in self?.panel?.close() }
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
