import Foundation
import XiaolaiDictCore
import Testing

/// What a card may say about the sense the reader met.
struct SenseNoteTests {
    private func note(gloss: String?, chosenBy: SenseChoice?) -> SenseNote {
        SenseNote(dictionary: "NOAD", ordinal: 3, outOf: 12, gloss: gloss, chosenBy: chosenBy)
    }

    /// A sense the selector proposed is a hypothesis; one the reader tapped is a fact. The card
    /// draws them differently, and this is the line it draws them on.
    @Test func onlyTheReadersOwnTapAndASingleSenseAreFacts() {
        #expect(note(gloss: "x", chosenBy: .reader).isConfirmed)
        #expect(note(gloss: "x", chosenBy: .onlySense).isConfirmed)
        #expect(note(gloss: "x", chosenBy: .model).isConfirmed == false)
        // Nothing chose it at all — an entry-level encounter. Not a fact either.
        #expect(note(gloss: "x", chosenBy: nil).isConfirmed == false)
    }

    /// The card must not offer to reveal something it does not have: an empty promise is worse
    /// than no promise, because the reader spends a click finding out.
    @Test func thereIsNothingToRevealWithoutAGloss() {
        #expect(note(gloss: "a neutralizing force", chosenBy: .reader).canReveal)
        #expect(note(gloss: nil, chosenBy: .reader).canReveal == false)
        #expect(note(gloss: "", chosenBy: .reader).canReveal == false)
        #expect(note(gloss: "   \n ", chosenBy: .reader).canReveal == false)
    }
}
