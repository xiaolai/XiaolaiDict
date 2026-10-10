import AppKit
import Capture
import XiaolaiDictUI
import SwiftUI

@MainActor
final class PinnedNoteController {
    private var notes: [UUID: PinnedNote] = [:]
    /// **How tall a note opens**, before the fit gives it its words' height (`PinnedNoteView`). Named rather than inline
    /// because it is a design value in a file the view layer's scan does not reach — see `NoMagicValuesTests`. Its width is
    /// the reader's text size's (`PinnedNoteView.openingWidth`).
    static let openingHeight: CGFloat = 200
    /// The reader's text size, read as each note is pinned. Set by the app; the standard size until then.
    var textSize: @MainActor () -> TextSize = { .standard }
    /// How far each successive note is stepped down and right, and how many steps before the
    /// cascade starts again at the top.
    static let cascadeStep: CGFloat = 24
    static let cascadeLength = 8
    /// The gap kept between a note and the screen's edge.
    static let screenMargin: CGFloat = 8
    /// **Where the next note opens, as `defaultWindowPlacement` reads it: its top-left, y down from the top of the primary
    /// display.** It was an AppKit frame, origin at the bottom, and SwiftUI took that origin for the top: measured
    /// 2026-10-10 on the E2E Mac, a note pinned 80 pt under the menu bar opened with its top 780 pt down. Only a first
    /// guess, which SwiftUI does not always take — `attach` puts the window where it belongs.
    private(set) var placement = NSRect(origin: .zero, size: NSSize(width: PinnedNoteView.openingWidth(for: .standard),
                                                                         height: openingHeight))

    /// **Each note's frame in AppKit's space until its window is reported**, then put there once (`attach`). SwiftUI
    /// placed the second of two notes 29 pt from the first, by its own cascade, whatever the closure said — measured on
    /// the E2E Mac with the two pinned 820 pt apart — and that note covered the first one's unpin control, so a click
    /// on it reached the second note's scroll area.
    private var opening: [UUID: NSRect] = [:]

    func note(_ id: UUID) -> PinnedNote? { notes[id] }

    /// The window each note is drawn in, as its scene reports it — **by the note's id, never by its
    /// title**, which is the headword and two notes can share. Weak: a closed note's window is not
    /// this controller's to keep.
    private var windows: [UUID: Held] = [:]
    private struct Held { weak var window: NSWindow? }

    /// Reported by the note's scene once SwiftUI has made its window, and again on every update of it. **The first report
    /// puts the window beside where the note was pinned, and no later one moves it** — a reader who drags a note keeps it
    /// where they put it. Set on the next turn of the main queue, outside the update that reported it: a frame set inside
    /// layout re-enters layout (plan-pinned-cards §4). Top-left, because the fit holds a note's top edge and grows it down.
    func attach(_ window: NSWindow, to id: UUID) {
        windows[id] = Held(window: window)
        guard let frame = opening.removeValue(forKey: id) else { return }
        DispatchQueue.main.async { [weak window] in
            window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        }
    }

    func window(of id: UUID) -> NSWindow? { windows[id]?.window }

    /// How many notes are on screen. Read by the tests that hold "one sticky per sense", because the
    /// rule is about the size of this set and nothing else could see it.
    var count: Int { notes.count }

    /// The reader dismissed one. Reported by the scene's `onDisappear`, since SwiftUI owns the
    /// window and there is no `willClose` to observe.
    func dismissed(_ id: UUID) {
        notes[id] = nil
        windows[id] = nil
        opening[id] = nil
    }

    /// **Puts a note away, handing back first the activation a click on it gave this app** (reported 2026-10-10).
    ///
    /// A click on a note makes this app active and the note key; when the note then closes, AppKit makes the window
    /// left behind it key and orders it front — measured on the E2E Mac, Settings, left open behind TextEdit, came in
    /// front of it, key and main, as the only note was unpinned. So where an ordinary window of another app is in front
    /// of every one of this app's, activation goes back to that app before the note closes, and the close happens once
    /// this app is no longer active: an inactive app's new key window is ordered in front of nothing. Where this app's
    /// own window is in front — a reader working in Settings — it is closed where it stands.
    func unpin(_ id: UUID, closing dismiss: @escaping @MainActor () -> Void) {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let windows = listed.compactMap { entry -> PinnedNoteClosing.Listed? in
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return PinnedNoteClosing.Listed(owner: owner, layer: layer)
        }
        guard let pid = PinnedNoteClosing.handBack(
                  among: windows, ours: getpid(), isActive: NSApplication.shared.isActive),
              let reader = NSRunningApplication(processIdentifier: pid)
        else {
            dismiss()
            return
        }
        NSApplication.shared.yieldActivation(to: reader)
        reader.activate(from: NSRunningApplication.current, options: [])
        Task { @MainActor in
            // Bounded: an activation the system declines still closes the note, as it did before.
            _ = await Poll.until(within: Self.handBackPatience) { !NSApplication.shared.isActive }
            dismiss()
        }
    }

    /// **A note's frame, in AppKit's space, for a pointer**: its top-left a cascade step down and right of the pointer, a
    /// step further for each note already open — starting again after `cascadeLength` — and kept on the usable area a
    /// screen margin in, so a note pinned in a corner opens where it can be read.
    static func frame(near pointer: NSPoint, size: NSSize, visible: NSRect, openBefore: Int) -> NSRect {
        let offset = CGFloat(openBefore % cascadeLength + 1) * cascadeStep
        let x = max(visible.minX + screenMargin, min(pointer.x + offset, visible.maxX - size.width - screenMargin))
        let top = min(visible.maxY - screenMargin, max(pointer.y - offset, visible.minY + screenMargin + size.height))
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// How long a note waits for this app to stop being active before it closes anyway.
    static let handBackPatience: Duration = .milliseconds(500)

    /// Keeps a sense as a note, and answers with the id of the note now on screen.
    ///
    /// **The same sense pins once.** Every `PinnedNote` value carries a fresh `UUID`, so inserting
    /// unconditionally put an identical sticky on screen per press — a dozen for a held button
    /// (reported 2026-09-27). Asked again for a sense already kept, this opens *that* note rather
    /// than a second one: `openWindow` with a value a window already exists for brings it forward,
    /// and if it does not, nothing visible happens, which is still the bug fixed. The guarantee is
    /// the early return, not the framework's focus behaviour.
    ///
    /// Returning the id is what makes the rule assertable — two presses answering with the same id
    /// is the wire, where a count alone would pass for a controller that had quietly stopped
    /// opening anything.
    @discardableResult
    func pin(_ note: PinnedNote, near pointer: UpPoint) -> UUID {
        // At most one can match, because this check is what keeps the set that way.
        if let kept = notes.first(where: { $0.value.holdsTheSameSense(as: note) }) {
            WindowActions.shared.openWindow(value: kept.key)
            return kept.key
        }
        // Unwrapped once for the placement math below, which is all in AppKit's space.
        let pointer = pointer.cg
        let size = NSSize(width: PinnedNoteView.openingWidth(for: textSize()), height: Self.openingHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let frame = Self.frame(near: pointer, size: size, visible: visible, openBefore: notes.count)
        opening[note.id] = frame
        // The same frame in the space SwiftUI reads, about the primary display — whose top every global y starts from.
        let primary = NSScreen.screens.first?.frame.height ?? visible.maxY
        placement = UpRect(frame).flipped(aboutPrimaryHeight: primary).cg

        notes[note.id] = note
        WindowActions.shared.openWindow(value: note.id)
        return note.id
    }
}

/// **A pinned note carries no window controls.**
///
/// `.hiddenTitleBar` hides the bar and leaves the three traffic lights floating over the content —
/// which is why the note used to reserve room at its top for them, and why it did not look like the
/// card it came from. A reader asked for the card's own chrome instead (2026-09-27), so the note is
/// put away by its own button, revealed under the pointer — and, since 2026-10-02, by Command-W,
/// Escape or its context menu, because a pointer is not something every reader has.
///
/// A named type rather than a closure inside the scene: a window is configured in AppKit, where
/// nothing about it is assertable from a view, and this is the one line standing between the reader
/// and a note they cannot tell from a window.
enum PinnedNoteWindow {
    /// **`@MainActor`, because `NSWindow` is.** Without it this compiled with a Swift 6 warning that the
    /// call was implicitly asynchronous — which is to say the buttons might be hidden after the reader has
    /// already seen them. A window is configured where windows live.
    @MainActor static func configure(_ window: NSWindow) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}

/// **Which app a note's activation goes back to as it closes** — a decision over the compositor's front-to-back list, so
/// it can be held without a window server.
enum PinnedNoteClosing {
    /// One window the compositor lists: who owns it, and at what level.
    struct Listed: Equatable {
        let owner: pid_t
        let layer: Int
    }

    /// The level ordinary windows are at — Settings, the Library, another app's document.
    static let ordinaryLayer = 0
    /// The level a note and the lookup panel float at (`NSWindow.Level.floating`).
    static let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))

    /// The app to hand activation back to before a note closes, or nil to close it where it stands: the owner of the
    /// frontmost ordinary window, where that is not this app and this app is active.
    static func handBack(among listed: [Listed], ours: pid_t, isActive: Bool) -> pid_t? {
        guard isActive, let front = listed.first(where: { $0.layer == ordinaryLayer }), front.owner != ours else {
            return nil
        }
        return front.owner
    }
}

/// One pinned note's scene content.
struct PinnedNoteSceneView: View {
    let controller: PinnedNoteController
    let id: UUID
    /// Closes this note's window. `onDisappear` then takes it out of the set, which is the same
    /// route the traffic-light close button used to take.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let note = controller.note(id) {
                PinnedNoteView(note: note) { controller.unpin(id) { dismiss() } }
            }
        }
        // **Under the title bar the scene hides.** `.hiddenTitleBar` hides the bar and keeps its
        // inset: SwiftUI still laid the note out below it, so its first line stood the bar's height
        // (32 pt on macOS 27) further from the top than the card's padding says.
        .ignoresSafeArea(.container, edges: .top)
        .xiaolaiDictPanelBehaviour(transient: true) { window in
            PinnedNoteWindow.configure(window)
            controller.attach(window, to: id)
        }
        .onDisappear { controller.dismissed(id) }
    }
}
