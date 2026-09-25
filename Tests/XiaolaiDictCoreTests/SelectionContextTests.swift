import DictionaryModel
import Foundation
import XiaolaiDictCore
import Testing

/// The sentence a selection sits in: the ledger's context now, and what the LLM pane will explain
/// the word against later. Ranges are UTF-16, as Accessibility reports them.
struct SelectionContextTests {
    private func range(of needle: String, in text: String) -> NSRange { (text as NSString).range(of: needle) }

    private func sentence(_ needle: String, in text: String, clipped: TextSegmenter.Clipping = []) -> SentenceContext? {
        TextSegmenter.sentence(in: text, around: range(of: needle, in: text), clipped: clipped)
    }

    @Test func aWordSelectionGetsItsWholeSentence() throws {
        let text = "Intro here. An ephemeral beauty fades before the reader can name it. After."
        let context = try #require(sentence("ephemeral", in: text))
        #expect(context.text == "An ephemeral beauty fades before the reader can name it.")
        #expect(!context.mayBeCut)
    }

    /// Where the selection sits in the sentence travels with it: the lemmatizer needs to know
    /// which occurrence of a repeated word was the selected one.
    @Test func theSelectionIsLocatedInItsSentence() throws {
        let text = "Intro.\n  The meeting ended after we stopped meeting. Later."
        let second = (text as NSString).range(of: "meeting", options: .backwards)
        let context = try #require(TextSegmenter.sentence(in: text, around: second))
        let selection = try #require(context.selection)
        #expect((context.text as NSString).substring(with: selection) == "meeting")
        #expect(selection.location == (context.text as NSString).range(of: "meeting", options: .backwards).location)
    }

    @Test func aSelectionOutsideTheSentenceIsNotLocated() {
        #expect(SentenceContext(text: "Short.", mayBeCut: false, selection: NSRange(location: 4, length: 9)) == nil)
    }

    @Test func aSelectionAcrossASentenceBoundaryGetsBothSentences() {
        let text = "First one. Second one. Third one."
        #expect(sentence("one. Second", in: text)?.text == "First one. Second one.")
    }

    /// Offsets are UTF-16: each emoji is two units, and reading them as Characters would select the
    /// wrong sentence entirely.
    @Test func offsetsAreUTF16() {
        let text = "🙂🙂🙂 Emoji first. The target sentence."
        #expect(sentence("target", in: text)?.text == "The target sentence.")
    }

    @Test func aChineseSelectionGetsItsSentence() {
        let text = "我们今天学习英语语法。然后去图书馆看书。"
        #expect(sentence("图书馆", in: text)?.text == "然后去图书馆看书。")
    }

    @Test func theSentenceIsTrimmed() {
        let text = "Intro.\n\n   Hello brave world.   \nMore."
        #expect(sentence("brave", in: text)?.text == "Hello brave world.")
    }

    /// Ranges come from another process and can be anything. `NSNotFound` is `Int.max`: added to a
    /// length, it overflows — which must be a nil, not a crash.
    @Test(arguments: [
        NSRange(location: 99, length: 3), NSRange(location: -1, length: 2), NSRange(location: 3, length: 99),
        NSRange(location: NSNotFound, length: 0), NSRange(location: NSNotFound, length: 5),
        NSRange(location: 2, length: Int.max), NSRange(location: 0, length: -1),
    ])
    func aRangeOutsideTheTextHasNoSentence(range: NSRange) {
        #expect(TextSegmenter.sentence(in: "Short text.", around: range) == nil)
    }

    /// A window cut from a longer document can start or end inside a sentence. That fragment is
    /// the best context there is, but it must say it may be incomplete.
    @Test func aSentenceRunningIntoTheCutMayBeCut() {
        let window = "rest of a long sentence that began before the window. A whole one. And one that runs"
        #expect(sentence("began", in: window, clipped: .start)?.mayBeCut == true)
        #expect(sentence("runs", in: window, clipped: .end)?.mayBeCut == true)
        #expect(sentence("whole", in: window, clipped: [.start, .end])?.mayBeCut == false)
    }

    /// The document's own start and end are not cuts: a sentence reaching them is complete.
    @Test func aSentenceAtTheDocumentsOwnEdgeIsComplete() {
        let text = "The first sentence. The last one"
        #expect(sentence("first", in: text)?.mayBeCut == false)
        #expect(sentence("last", in: text)?.mayBeCut == false)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func aBlankSentenceIsNoSentence(text: String) {
        #expect(SentenceContext(text: text, mayBeCut: false) == nil)
    }
}
