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

/// The pinned notes on screen. Each is its own always-on-top panel, closed by its own button — a
/// new lookup never touches them, which is the whole point of pinning one.
@MainActor
final class PinnedNoteController {
    private var panels: [UUID: NSPanel] = [:]

    var count: Int { panels.count }

    func pin(_ note: PinnedNote, near pointer: UpPoint) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 200)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.title = note.term
        panel.contentView = NSHostingView(rootView: PinnedNoteView(note: note))

        // Unwrapped once for the placement math below, which is all in AppKit's space.
        let pointer = pointer.cg
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: panel.frame.size)
        // Offset per open note, so pinning several does not stack them exactly on top of one another.
        let offset = CGFloat(panels.count % 8) * 24
        let origin = NSPoint(
            x: min(pointer.x + 24 + offset, visible.maxX - panel.frame.width - 8),
            y: max(pointer.y - 24 - panel.frame.height - offset, visible.minY + 8))
        panel.setFrameOrigin(origin)
        panels[note.id] = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels[note.id] = nil }
        }
        panel.orderFrontRegardless()
    }
}

private struct PinnedNoteView: View {
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
