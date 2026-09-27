import AppKit
import XiaolaiDictCore
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
    /// The smallest a reader may drag a note to and still have it hold a sentence.
    static let smallestNote = NSSize(width: 240, height: 140)

    /// Where the next note should be placed, read back by `defaultWindowPlacement`.
    private(set) var placement = NSRect(origin: .zero, size: noteSize)

    func note(_ id: UUID) -> PinnedNote? { notes[id] }

    /// How many notes are on screen. Read by the tests that hold "one sticky per sense", because the
    /// rule is about the size of this set and nothing else could see it.
    var count: Int { notes.count }

    /// The reader dismissed one. Reported by the scene's `onDisappear`, since SwiftUI owns the
    /// window and there is no `willClose` to observe.
    func dismissed(_ id: UUID) { notes[id] = nil }

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
/// put away by its own button, revealed under the pointer.
///
/// A named type rather than a closure inside the scene: a window is configured in AppKit, where
/// nothing about it is assertable from a view, and this is the one line standing between the reader
/// and a note they cannot tell from a window.
enum PinnedNoteWindow {
    static func configure(_ window: NSWindow) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
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
                PinnedNoteView(note: note) { dismiss() }
            }
        }
        .frame(minWidth: PinnedNoteController.smallestNote.width,
               minHeight: PinnedNoteController.smallestNote.height)
        .xiaolaiDictPanelBehaviour(transient: true) { PinnedNoteWindow.configure($0) }
        .onDisappear { controller.dismissed(id) }
    }
}
