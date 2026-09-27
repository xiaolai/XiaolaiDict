import AppKit
import DictionaryModel
import Testing
import XiaolaiDictCore

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **A pinned note looks like the card it came from, not like a document window.**
///
/// Reported by a reader 2026-09-27. The note's scene is `.hiddenTitleBar`, which hides the bar and
/// leaves the three traffic lights floating over the content — so a sticky announced itself as a
/// window to manage, and reserved 28 pt at its top to dodge controls it never wanted. The lookup
/// panel had already gone the other way with `.plain`; the note cannot follow it there, because a
/// borderless window gives up the drag region and the resize edges a sticky needs.
@MainActor struct PinnedNoteChromeTests {
    /// **A pinned note carries no traffic lights.** `.hiddenTitleBar` hides the bar and leaves the
    /// three buttons floating over the content — which is why the note used to reserve room at its
    /// top for them. The first two `#expect`s are the positive control: AppKit really does give a
    /// titled, closable, resizable window all three, so this check can fail.
    @Test func aNoteWindowCarriesNoWindowButtons() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for button in buttons {
            #expect(window.standardWindowButton(button)?.isHidden == false)
        }
        PinnedNoteWindow.configure(window)
        for button in buttons {
            #expect(window.standardWindowButton(button)?.isHidden == true)
        }
    }

    /// **Hiding the controls must not cost the reader the note itself.** A sticky they cannot move or
    /// resize is worse than one with chrome, and the zoom button is the one that looks like it owns
    /// resizing — it does not, the style mask does. Hiding a button changes neither, and this is what
    /// says so, because "it still drags" is exactly the kind of thing assumed rather than checked.
    @Test func aNoteCanStillBeMovedAndResized() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        PinnedNoteWindow.configure(window)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.isMovable)
    }
}
