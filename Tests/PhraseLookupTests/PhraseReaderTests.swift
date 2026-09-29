import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Testing

@testable import PhraseLookup

/// **The adapter, asserted on the wire rather than on its parts.**
///
/// `PhraseSpanTests` proves the matcher against word arrays; these prove the three translations that stand
/// between a reader's sentence and it — lemma form, a captured UTF-16 range to a word, and a matched word
/// range back to UTF-16 the card can draw. Each of the three has been a defect class in this project before.
@Suite struct PhraseReaderTests {
    private func reader() -> PhraseReader {
        PhraseReader(phrases: [
            "purple passage", "give up", "give up the ghost", "give something up",
            "take something into account", "turn down", "look after",
        ])
    }

    /// Nothing read yet is **not** "no phrase here", and the two must be distinguishable from outside.
    @Test func anUnreadInventoryIsNotReadyRatherThanEmpty() {
        let unread = PhraseReader(bundles: [])
        #expect(unread.isReady == false)
        #expect(unread.phrase(in: "they give up the ghost", at: NSRange(location: 5, length: 4)) == nil)
        #expect(reader().isReady, "and an inventory handed in directly is ready at once")
    }

    /// The everyday case, end to end: the reader's own inflected text, the dictionary's own spelling back.
    @Test func aPhraseIsFoundInTheReadersOwnSentence() {
        let sentence = "they gave up the ghost eventually"
        let found = reader().phrase(in: sentence, at: NSRange(location: 5, length: 4))
        #expect(found?.phrase == "give up the ghost", "gave is lemmatised before the keys are asked")
        #expect(found?.separation == PhraseSeparation.none)
        let text = sentence as NSString
        #expect(found.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) }
            == "gave up the ghost", "and the span is drawable on the sentence that was sent")
    }

    /// **The span covers the gap, because that is what the reader sees.** Joining only the matched words'
    /// own ranges would draw two fragments and leave the object outside the phrase.
    @Test func aSplitPhraseSpansTheGapItStepsOver() {
        let sentence = "take what people think and other possible edge cases all into account"
        let found = reader().phrase(in: sentence, at: NSRange(location: 0, length: 4))
        #expect(found?.phrase == "take something into account")
        #expect(found?.separation == .marked(9))
        let text = sentence as NSString
        #expect(found.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) }
            == sentence, "the whole span, verb through particle")
    }

    /// **A capture's range is not always a whole word**, which is the same fact `Lemmatizer` documents:
    /// *temper* captured in "justice tempered with mercy" is a range over `temper` inside `tempered`. A
    /// reader hovering a phrase must not lose it to that.
    @Test func aRangeInsideALongerWordStillFindsItsWord() {
        let sentence = "they are giving up the ghost"
        // "giv" — a partial capture of "giving", as the screen readers produce.
        let found = reader().phrase(in: sentence, at: NSRange(location: 9, length: 3))
        #expect(found?.phrase == "give up the ghost")
    }

    /// A range covering no word at all answers nothing rather than the nearest word.
    @Test func aRangeOnNoWordFindsNothing() {
        let words = Lemmatizer.lemmas(in: "give up")
        #expect(PhraseReader.word(covering: NSRange(location: 4, length: 1), among: words) == nil,
                "past the end of the text")
        #expect(PhraseReader.word(covering: NSRange(location: 0, length: 0), among: words) == nil,
                "an empty range intersects nothing")
    }

    /// An ordinary word is the common case and must answer nothing.
    @Test func anOrdinaryWordFindsNoPhrase() {
        #expect(reader().phrase(in: "i read a long passage aloud",
                                at: NSRange(location: 14, length: 7)) == nil)
    }

    /// **Every case of the separation maps across, and the mapping is the only place it could be lost.**
    /// Two spellings of one fact exist because the module that crosses the XPC boundary may not bind the one
    /// that reads `KeyText.data`; a silent default here would flatten a guess into a publisher's mark.
    @Test func everySeparationCrossesTheBoundaryUnchanged() {
        #expect(PhraseReader.separation(.none) == PhraseSeparation.none)
        #expect(PhraseReader.separation(.marked(9)) == .marked(9))
        #expect(PhraseReader.separation(.inferred(2)) == .inferred(2))
    }

    /// An inferred split reaches the wire labelled as one, so nothing downstream can weigh it as a mark.
    @Test func anInferredSplitArrivesLabelledAsInferred() {
        let found = reader().phrase(in: "they turn the offer down", at: NSRange(location: 5, length: 4))
        #expect(found?.phrase == "turn down")
        #expect(found?.separation == .inferred(2))
    }

    /// Reading no dictionaries is ready and finds nothing — and **says** it read none, so a service cannot
    /// report a working detector over an empty inventory.
    @Test func readingNothingReportsThatItReadNothing() {
        let reading = PhraseReader(bundles: []).read()
        #expect(reading == PhraseReader.Reading(phrases: 0, explained: 0, read: [], failed: []))
    }

    /// A bundle that cannot be read is named rather than dropped, and does not stop the reading.
    @Test func anUnreadableBundleIsNamed() throws {
        let missing = DictionaryBundle(
            url: URL(fileURLWithPath: "/nonexistent/Nope.dictionary"),
            identifier: "test.nope", displayName: "Nope")
        let reading = PhraseReader(bundles: [missing], phrases: { _ in nil }).read()
        #expect(reading.failed == ["Nope"])
        #expect(reading.read.isEmpty)
        #expect(reading.phrases == 0, "a dictionary that cannot be read contributes nothing")

        // And one that can: the reading names it, and its phrases and meanings both arrive.
        let store = DictionaryBundle(url: URL(fileURLWithPath: "/nonexistent/Fine.dictionary"),
                                    identifier: "test.fine", displayName: "Fine")
        let stocked = PhraseReader(bundles: [store], phrases: { _ in
            PhraseInventory(contentVersion: "v1", phrases: ["out of the blue", "purple passage"],
                            meanings: ["out of the blue": "unexpectedly"])
        }).read()
        #expect(stocked.read == ["Fine"])
        #expect(stocked.phrases == 2)
        #expect(stocked.explained == 1, "the key index contributes spellings without definitions")
    }
}
