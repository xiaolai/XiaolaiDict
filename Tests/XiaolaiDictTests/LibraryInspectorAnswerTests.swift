import Foundation
import StudyPresentation
import Testing

/// **A saved target with no answer can be given one.**
///
/// The inspector's closed state had two shapes: a reveal over an answer, and a sentence saying
/// there was none — with nothing to press. The editor sat behind the reveal, so a blank answer,
/// the one that most needs writing, was the one that could never be written. A blank answer has
/// nothing to give away, so offering the editor straight off teaches the reader nothing early.
struct LibraryInspectorAnswerTests {
    private func inspector(_ answer: String) -> LibraryPresentation.Inspector {
        LibraryPresentation.Inspector(id: UUID(), word: "hold", answer: answer, isReaders: false)
    }

    @Test func ablankAnswerOffersTheEditor() {
        #expect(inspector("").closedAnswer == .write)
        // Swift's `.whitespacesAndNewlines`, the rule the Save button uses: tabs, newlines and the
        // ideographic space are blank too, so the two never disagree about what can be saved.
        #expect(inspector(" \t\n\u{3000}").closedAnswer == .write)
    }

    @Test func anAnswerStaysBehindTheReveal() {
        #expect(inspector("a ship's storage space").closedAnswer == .reveal)
    }
}
