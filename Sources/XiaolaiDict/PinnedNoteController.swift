import AppKit
import Capture
import XiaolaiDictUI
import SwiftUI

@MainActor
final class PinnedNoteController {
    private var notes: [UUID: PinnedNote] = [:]
    /// A note's size until the reader resizes one. Named rather than inline because it is a design
    /// value in a file the view layer's scan does not reach — see `NoMagicValuesTests`.
    static let noteSize = NSSize(width: 320, height: 200)
    /// How far each successive note is stepped down and right, and how many steps before the
    /// cascade starts again at the top.
    static let cascadeStep: CGFloat = 24
    static let cascadeLength = 8
    /// The gap kept between a note and the screen's edge.
    static let screenMargin: CGFloat = 8
    /// **The narrowest a reader may drag a note to** and still have it hold a sentence. A width alone: the
    /// height is the note's words', which the fit gives it (`PinnedNoteView`), and a floor of 140 pt
    /// under them stood a short note in white below its last line, as the fixed opening height did.
    static let narrowestNote: CGFloat = 240

    /// Where the next note should be placed, read back by `defaultWindowPlacement`.
    private(set) var placement = NSRect(origin: .zero, size: noteSize)

    func note(_ id: UUID) -> PinnedNote? { notes[id] }

    /// The window each note is drawn in, as its scene reports it — **by the note's id, never by its
    /// title**, which is the headword and two notes can share. Weak: a closed note's window is not
    /// this controller's to keep.
    private var windows: [UUID: Held] = [:]
    private struct Held { weak var window: NSWindow? }

    /// Reported by the note's scene once SwiftUI has made its window.
    func attach(_ window: NSWindow, to id: UUID) { windows[id] = Held(window: window) }

    func window(of id: UUID) -> NSWindow? { windows[id]?.window }

    /// How many notes are on screen. Read by the tests that hold "one sticky per sense", because the
    /// rule is about the size of this set and nothing else could see it.
    var count: Int { notes.count }

    /// The reader dismissed one. Reported by the scene's `onDisappear`, since SwiftUI owns the
    /// window and there is no `willClose` to observe.
    func dismissed(_ id: UUID) {
        notes[id] = nil
        windows[id] = nil
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
        let size = placement.size
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        // Offset per open note, so pinning several does not stack them exactly on top of one another.
        let offset = CGFloat(notes.count % Self.cascadeLength) * Self.cascadeStep
        placement = NSRect(
            origin: NSPoint(
                x: min(pointer.x + Self.cascadeStep + offset,
                       visible.maxX - size.width - Self.screenMargin),
                y: max(pointer.y - Self.cascadeStep - size.height - offset,
                       visible.minY + Self.screenMargin)),
            size: size)

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
        .frame(minWidth: PinnedNoteController.narrowestNote)
        .xiaolaiDictPanelBehaviour(transient: true) { window in
            PinnedNoteWindow.configure(window)
            controller.attach(window, to: id)
        }
        .onDisappear { controller.dismissed(id) }
    }
}
