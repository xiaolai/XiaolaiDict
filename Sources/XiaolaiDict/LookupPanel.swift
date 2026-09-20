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
    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket)
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
/// What the panel is showing. A scene's content reads this; nothing hands a window a view.
@Observable
@MainActor
final class LookupPanelModel {
    var content: PanelContent?
    /// Per kind, so a panel of one kind does not inherit the minimum of another.
    var minimumSize: NSSize = PanelContent.Kind.lookup.minimumSize
}

@MainActor
final class LookupPanelController: LookupPanelPresenting {
    let model = LookupPanelModel()
    private var current = 0
    private var shownKind: PanelContent.Kind?
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "panel")
    /// Sizes the reader chose by resizing, per kind of content; kept for the next panel of that kind.
    private var chosenSizes: [PanelContent.Kind: NSSize] = [:]
    private let escape: EscapeKey
    /// Pinned notes outlive the panel that made them, so they are owned here rather than by a view.
    let notes = PinnedNoteController()
    /// Where the last panel was put, so a note pinned from it lands beside it.
    private(set) var lastPointer = UpPoint(.zero)
    /// Where the scene should be placed, worked out before it opens. A scene cannot be handed a
    /// frame, so `defaultWindowPlacement` reads this back.
    private(set) var placement = NSRect(origin: .zero, size: PanelContent.Kind.lookup.defaultSize)

    init(hotkeys: HotkeyCenter = .shared) {
        escape = EscapeKey(hotkeys: hotkeys)
    }

    /// What the reader asked to study, as they ask for it. Set by the app, which owns the ledger.
    var onStudySense: (@MainActor (SenseEncounter) -> Void)?

    /// The window SwiftUI made for the panel's scene, or nil when it is not up.
    ///
    /// `NSApplication.shared`, never `NSApp`: the latter is implicitly unwrapped and nil in a
    /// process that has not made one, where it traps instead of answering "no window".
    private var window: NSWindow? {
        NSApplication.shared.windows.first { $0.identifier?.rawValue.contains(XiaolaiDictScene.lookupID) == true }
            ?? NSApplication.shared.windows.first { $0.title == XiaolaiDictScene.lookupTitle }
    }

    /// Whether the **compositor** has it on screen — not the controller's bookkeeping, and not
    /// AppKit's `isVisible`. A window the compositor does not list is not on screen.
    var isDrawnOnScreen: Bool {
        guard let number = window?.windowNumber else { return false }
        let listed = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return listed.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == Int(number) }
    }

    func newRequest() -> PanelTicket {
        current += 1
        return PanelTicket(number: current)
    }

    func isCurrent(_ ticket: PanelTicket) -> Bool { ticket.number == current }

    func show(_ content: PanelContent, near pointer: UpPoint, for ticket: PanelTicket) {
        guard isCurrent(ticket) else { return }
        lastPointer = pointer
        let kind = content.kind
        let screen = NSScreen.screens.first { $0.frame.contains(pointer.cg) } ?? NSScreen.main
        let visible = UpRect(screen?.visibleFrame ?? NSRect(origin: .zero, size: kind.defaultSize))
        placement = PanelPlacement.frame(
            for: chosenSizes[kind] ?? kind.defaultSize, near: pointer, within: visible)

        model.minimumSize = kind.minimumSize
        model.content = content
        shownKind = kind
        // The environment's real action, captured from the menu-bar label. An `EnvironmentValues()`
        // built on the spot is wired to nothing and silently opens no window at all.
        WindowActions.shared.open?(id: XiaolaiDictScene.lookupID)
        // A scene already on screen is not re-placed, so a panel being reused is moved by hand.
        if let window, window.isVisible { window.setFrame(placement, display: true) }
        escape.claim { [weak self] in self?.close() }
    }

    /// Fills in a panel already on screen. Same kind, so the size and the minimum stay as they
    /// were, and **the placement is not touched**: the reader may have moved or resized it while
    /// waiting. Setting the content is all it takes — a scene is not re-placed because its content
    /// changed, which the hand-built panel had to be careful to preserve.
    func update(_ content: PanelContent, for ticket: PanelTicket) {
        guard isCurrent(ticket), shownKind == content.kind else {
            // A kind that changed mid-lookup is a mistake in the caller, not something to paper
            // over by silently resizing the panel under the reader.
            if isCurrent(ticket), let shownKind, shownKind != content.kind {
                log.error("panel update changed kind from \(String(describing: shownKind), privacy: .public)")
            }
            return
        }
        model.content = content
    }

    func close() {
        WindowActions.shared.dismiss?(id: XiaolaiDictScene.lookupID)
        closed()
    }

    /// Everything still running for the panel is now stale. Also called when the reader closes the
    /// window themselves, which the scene reports through `onDisappear`.
    func closed() {
        guard shownKind != nil else { return }
        shownKind = nil
        model.content = nil
        current += 1
        escape.release()
    }

    /// Only a size the reader chose by dragging is remembered — not one the panel was given, or
    /// shrunk to, to fit a smaller screen.
    func rememberChosenSize(_ size: NSSize) {
        guard let shownKind else { return }
        chosenSizes[shownKind] = size
    }
}

/// The lookup panel's scene content.
struct LookupPanelSceneView: View {
    let controller: LookupPanelController
    @Bindable var model: LookupPanelModel

    var body: some View {
        Group {
            if let content = model.content {
                PanelView(content: content)
                    .environment(\.pinNote) { [controller] note in
                        controller.notes.pin(note, near: controller.lastPointer)
                    }
                    .environment(\.studySense) { [controller] encounter in
                        controller.onStudySense?(encounter)
                    }
            }
        }
        .frame(minWidth: model.minimumSize.width, minHeight: model.minimumSize.height)
        .xiaolaiDictPanelBehaviour(transient: true) { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [controller] _ in
                MainActor.assumeIsolated { controller.rememberChosenSize(window.frame.size) }
            }
        }
        // The reader closing the window is as final as Escape: whatever is still arriving for this
        // lookup is stale.
        .onDisappear { controller.closed() }
    }
}
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

    /// Answers a bare `NSRect` because its one caller hands it straight to `NSPanel.setFrame`.
    static func frame(for size: NSSize, near pointer: UpPoint, within visible: UpRect) -> NSRect {
        let pointer = pointer.cg
        let visible = visible.cg
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
