import AppKit
import XiaolaiDictCore
import SwiftUI

/// A sense the reader kept: a sticky note that survives the next lookup and is dismissed on its own
/// terms (`feature-ledger-ux.md` B5).
///
/// **A copy, not a live reference** (decision D3). The dictionary's id and content version are
/// recorded with it, so a dictionary update — or the reader disabling that dictionary — cannot
/// silently rewrite a note they chose to keep. What the note says is what it said when it was
/// pinned, and it can say which version of which dictionary it came from.
struct PinnedNote: Equatable, Identifiable {
    let id = UUID()
    let term: String
    let heading: String
    let dictionary: DictionaryIdentity
    let partOfSpeech: String?
    let pronunciation: String?
    /// The sense's own words, copied at the moment of pinning.
    let text: String
    let senseKey: String?
    let pinnedAt: Date

    /// Where it came from, precisely enough to be checked later.
    var provenance: String {
        let version = dictionary.version.map { " \($0)" } ?? ""
        return "\(dictionary.name)\(version)"
    }

    static func == (a: PinnedNote, b: PinnedNote) -> Bool { a.id == b.id }
}

/// The pinned notes on screen. Each is its own always-on-top window, closed by its own button — a
/// new lookup never touches them, which is the whole point of pinning one.
///
/// A `WindowGroup(for:)` scene rather than an `NSPanel` per note: SwiftUI opens one window per
/// value, which is exactly the shape of "several notes, each independent". The note itself is held
/// here and looked up by id, because a scene is handed a value and not an object.
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

struct PinnedNoteView: View {
    let note: PinnedNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(note.heading).font(.title3.weight(.semibold))
                    if let partOfSpeech = note.partOfSpeech {
                        Text(partOfSpeech).font(.caption).italic().foregroundStyle(.secondary)
                    }
                    if let pronunciation = note.pronunciation {
                        Text(pronunciation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(note.text).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // What it is a copy of, and from when. A note that outlives its dictionary can
                // still say where it came from.
                Text(note.provenance).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
