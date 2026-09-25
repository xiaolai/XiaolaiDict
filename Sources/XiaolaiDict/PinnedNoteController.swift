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

    /// The reader dismissed one. Reported by the scene's `onDisappear`, since SwiftUI owns the
    /// window and there is no `willClose` to observe.
    func dismissed(_ id: UUID) { notes[id] = nil }

    func pin(_ note: PinnedNote, near pointer: UpPoint) {
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
    }
}

/// One pinned note's scene content.
struct PinnedNoteSceneView: View {
    let controller: PinnedNoteController
    let id: UUID

    var body: some View {
        Group {
            if let note = controller.note(id) {
                PinnedNoteView(note: note)
            }
        }
        .frame(minWidth: PinnedNoteController.smallestNote.width,
               minHeight: PinnedNoteController.smallestNote.height)
        .xiaolaiDictPanelBehaviour(transient: true)
        .onDisappear { controller.dismissed(id) }
    }
}
