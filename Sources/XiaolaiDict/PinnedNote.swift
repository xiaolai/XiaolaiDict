import AppKit
import XiaolaiDictCore
import XiaolaiDictUI
import SwiftUI

@MainActor
final class PinnedNoteController {
    private var notes: [UUID: PinnedNote] = [:]
    /// Where the next note should be placed, read back by `defaultWindowPlacement`.
    private(set) var placement = NSRect(origin: .zero, size: NSSize(width: 320, height: 200))

    var count: Int { notes.count }

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
        let offset = CGFloat(notes.count % 8) * 24
        placement = NSRect(
            origin: NSPoint(
                x: min(pointer.x + 24 + offset, visible.maxX - size.width - 8),
                y: max(pointer.y - 24 - size.height - offset, visible.minY + 8)),
            size: size)

        notes[note.id] = note
        WindowActions.shared.open?(value: note.id)
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
        .frame(minWidth: 240, minHeight: 140)
        .xiaolaiDictPanelBehaviour(transient: true)
        .onDisappear { controller.dismissed(id) }
    }
}
