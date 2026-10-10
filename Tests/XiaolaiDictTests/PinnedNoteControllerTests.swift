import AppKit
import Capture
import DictionaryModel
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **One sticky per sense, and a note that carries no window controls.**
///
/// Both reported by a reader on 2026-09-27. Pressing pin repeatedly put a fresh copy of the same
/// sense on screen every time: `PinnedNote.id` is a new `UUID` per value — deliberately, so closing
/// one note can never close another — and `pin` inserted under it without ever asking whether those
/// words were already on screen.
///
/// The rule lives in the controller rather than in `PinnedNote` because the two are different
/// questions. A note is a value and every value is its own; *what is on screen* is this controller's
/// subject, and it is the thing the reader was complaining about. `PinnedNoteTests` holds the other
/// half, so neither reads as a contradiction of the other.
@MainActor struct PinnedNoteControllerTests {
    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    private func note(_ dictionary: DictionaryIdentity? = nil, text: String = "a penalty") -> PinnedNote {
        PinnedNote(
            heading: "fine", dictionary: dictionary ?? noad, partOfSpeech: "noun",
            pronunciation: "fīn", text: text, standing: .confirmed)
    }

    /// The reported defect, at the smallest scale that shows it.
    @Test func pinningTheSameSenseTwiceLeavesOneNote() {
        let notes = PinnedNoteController()
        let first = notes.pin(note(), near: .zero)
        let again = notes.pin(note(), near: .zero)
        #expect(notes.count == 1)
        #expect(again == first)
        #expect(notes.note(first) != nil)
    }

    /// Held down rather than pressed twice — the shape the reader actually hit.
    @Test func holdingItDownStillLeavesOneNote() {
        let notes = PinnedNoteController()
        for _ in 1...12 { notes.pin(note(), near: .zero) }
        #expect(notes.count == 1)
    }

    /// The dedupe is about one sense, not about one word: *fine* has several and each may be kept.
    @Test func anotherSenseOfTheSameWordIsItsOwnNote() {
        let notes = PinnedNoteController()
        notes.pin(note(text: "a penalty"), near: .zero)
        notes.pin(note(text: "of high quality"), near: .zero)
        #expect(notes.count == 2)
    }

    /// Two dictionaries can print the same words, and a note says which one it came from (D3), so
    /// they are not the same note.
    @Test func theSameWordsFromAnotherDictionaryAreTheirOwnNote() {
        let notes = PinnedNoteController()
        notes.pin(note(), near: .zero)
        notes.pin(note(DictionaryIdentity(name: "Collins COBUILD")), near: .zero)
        #expect(notes.count == 2)
    }

    /// **A note's window is found by its id, and let go with the note.** Two notes may share a headword, which is
    /// their windows' title, so the scene reports each window against the id it was opened for.
    @Test func aNotesWindowIsFoundByItsIdAndLetGoWithIt() {
        let notes = PinnedNoteController()
        let first = notes.pin(note(text: "a penalty"), near: .zero)
        let second = notes.pin(note(text: "of high quality"), near: .zero)
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        }
        notes.attach(windows[0], to: first)
        notes.attach(windows[1], to: second)
        #expect(notes.window(of: first) === windows[0])
        #expect(notes.window(of: second) === windows[1])
        notes.dismissed(first)
        #expect(notes.window(of: first) == nil, "an unpinned note's window is still held")
        #expect(notes.window(of: second) === windows[1])
    }

    /// **Unpinning really lets go.** Without this the dedupe would be a one-way door: a sense
    /// pinned, closed, and wanted back would match nothing on screen and still have to open.
    @Test func aSenseCanBePinnedAgainAfterItIsUnpinned() {
        let notes = PinnedNoteController()
        let first = notes.pin(note(), near: .zero)
        notes.dismissed(first)
        #expect(notes.count == 0)
        let second = notes.pin(note(), near: .zero)
        #expect(notes.count == 1)
        #expect(second != first)
    }

    // MARK: - Where a note opens

    /// The cascade step the design names, written here rather than read from the controller, so a changed step fails.
    private let step: CGFloat = 24

    /// **What the scene hands `WindowPlacement` is a top-left, y down from the top of the primary display** — the space
    /// SwiftUI reads it in, measured 2026-10-10 on the E2E Mac: an AppKit origin of y 780 (the bottom of a note pinned
    /// 80 pt under the menu bar) opened the note with its *top* 780 pt down. So the placement for a pointer near the top
    /// must be near the top.
    @Test func whatTheSceneIsHandedIsTheTopLeftYDown() throws {
        let screen = try #require(NSScreen.screens.first, "no display to place a note on")
        let visible = screen.visibleFrame
        let pointer = NSPoint(x: visible.minX + 100, y: visible.maxY - 80)
        let notes = PinnedNoteController()
        notes.pin(note(), near: UpPoint(pointer))
        let fromTheTop = screen.frame.height - pointer.y
        #expect(notes.placement.minX == pointer.x + step)
        #expect(notes.placement.minY == fromTheTop + step,
                "the note's top is handed to SwiftUI \(notes.placement.minY) pt down for a pointer \(fromTheTop) pt down")
    }

    /// **The window is put where the note was pinned once the scene reports it** — SwiftUI's placement is a first guess,
    /// and for a second window of the group it is not taken at all: measured on the E2E Mac, the second of two notes
    /// pinned 820 pt apart opened 29 pt from the first, its own cascade, and covered the first's unpin control.
    @Test func theReportedWindowIsMovedBesideThePointer() async throws {
        let screen = try #require(NSScreen.screens.first, "no display to place a note on")
        let visible = screen.visibleFrame
        let pointer = NSPoint(x: visible.minX + 100, y: visible.maxY - 80)
        let notes = PinnedNoteController()
        let first = notes.pin(note(text: "a penalty"), near: UpPoint(pointer))
        let second = notes.pin(note(text: "of high quality"), near: UpPoint(pointer))
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless],
                     backing: .buffered, defer: true)
        }
        notes.attach(windows[0], to: first)
        notes.attach(windows[1], to: second)
        let placed = await Poll.until(within: .seconds(2)) {
            windows[0].frame.minX == pointer.x + step && windows[1].frame.minX == pointer.x + step + step
        }
        #expect(placed == .met, "the windows stayed at \(windows.map(\.frame))")
        // Top-left, the cascade a step further for the note already open.
        #expect(windows[0].frame.maxY == pointer.y - step)
        #expect(windows[1].frame.maxY == pointer.y - step - step)
    }

    /// **Placed once.** The scene reports its window on every update; a reader who drags a note keeps it where they put it.
    @Test func aNoteIsPlacedOnceNotOnEveryReport() async throws {
        let screen = try #require(NSScreen.screens.first, "no display to place a note on")
        let visible = screen.visibleFrame
        let notes = PinnedNoteController()
        let id = notes.pin(note(), near: UpPoint(NSPoint(x: visible.minX + 100, y: visible.maxY - 80)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        notes.attach(window, to: id)
        _ = await Poll.until(within: .seconds(2)) { window.frame.minX != 0 }
        let dragged = NSPoint(x: visible.minX + 400, y: visible.maxY - 300)
        window.setFrameTopLeftPoint(dragged)
        notes.attach(window, to: id)
        _ = await Poll.until(within: .milliseconds(300)) { window.frame.minX != dragged.x }
        #expect(window.frame.minX == dragged.x && window.frame.maxY == dragged.y, "a reported window was placed again")
    }

    /// **The arithmetic at the screen's edges**: a pointer in the bottom-right corner keeps the note on the usable area,
    /// a screen margin in, and the cascade starts again after its length.
    @Test func aNoteNearAnEdgeStaysOnTheScreen() {
        let visible = NSRect(x: 0, y: 40, width: 1000, height: 700)
        let size = NSSize(width: 300, height: 200)
        let margin: CGFloat = 8
        let corner = PinnedNoteController.frame(near: NSPoint(x: 990, y: 50), size: size, visible: visible, openBefore: 0)
        #expect(corner.maxX == visible.maxX - margin)
        #expect(corner.minY == visible.minY + margin)
        let top = PinnedNoteController.frame(near: NSPoint(x: 100, y: 739), size: size, visible: visible, openBefore: 0)
        #expect(top.maxY == 739 - step)
        let wrapped = PinnedNoteController.frame(near: NSPoint(x: 100, y: 600), size: size, visible: visible, openBefore: 8)
        let fresh = PinnedNoteController.frame(near: NSPoint(x: 100, y: 600), size: size, visible: visible, openBefore: 0)
        #expect(wrapped == fresh, "the cascade does not start again after eight notes")
    }

    // MARK: - How wide a note opens

    /// **At the reader's text size, as the card it came from** — 25 em, the quick card's measure. It was 320 pt at every
    /// size, so at Huge, where an em is 24 pt, a line held half the words a line of the card did. The ems are written
    /// here, not read from the scale, so a changed measure fails.
    @Test func aNoteOpensAsWideAsTheReadersTextAsks() throws {
        for size in [TextSize.standard, .huge] {
            let notes = PinnedNoteController()
            notes.textSize = { size }
            notes.pin(note(), near: .zero)
            #expect(notes.placement.width == size.em * 25, "at \(size) a note opens \(notes.placement.width) pt wide")
        }
    }

    /// The size is the reader's at the moment of pinning, read each time: a reader who changes the size between two
    /// notes gets the second at the new one.
    @Test func eachNoteReadsTheSizeWhenItIsPinned() {
        let notes = PinnedNoteController()
        notes.textSize = { .standard }
        notes.pin(note(text: "a penalty"), near: .zero)
        let first = notes.placement.width
        notes.textSize = { .huge }
        notes.pin(note(text: "of high quality"), near: .zero)
        #expect(notes.placement.width == first * 2)
    }
}
