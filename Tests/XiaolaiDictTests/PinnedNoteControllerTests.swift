import AppKit
import DictionaryModel
import Testing
import XiaolaiDictCore

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
}
