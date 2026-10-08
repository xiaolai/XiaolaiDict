import Testing
@testable import XiaolaiDict

@MainActor
struct GhosttySelectionReaderTests {
    @Test func oldClipboardContentsAreNeverTreatedAsASelection() {
        guard case .nothing = GhosttySelectionReader.result(after: 3, current: 3, text: "private old clipboard text") else {
            Issue.record("An unchanged clipboard must not become a translation request")
            return
        }
    }

    @Test func aNewNonemptySelectionCanBeTranslated() {
        #expect(GhosttySelectionReader.result(after: 3, current: 4, text: "  This is a sentence.\n") ==
                .selected("This is a sentence."))
    }

    @Test func emptyAndOversizeSelectionsAreRejected() {
        for text in ["\n ", String(repeating: "x", count: GhosttySelectionReader.maximumLength + 1)] {
            guard case .nothing = GhosttySelectionReader.result(after: 3, current: 4, text: text) else {
                Issue.record("Only a bounded nonempty selection may reach the translator")
                return
            }
        }
    }
}
