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
        let unread = PhraseReader(bundles: [], phrases: { _ in nil })
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
        let words = Lemmatizer.forms(in: "give up")
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
        let reading = PhraseReader(bundles: [], phrases: { _ in nil }).read()
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
                            explanations: ["out of the blue": [
                                PhraseExplanation(parentEntryID: "blue", blockID: "blue.01",
                                                  definitions: ["unexpectedly"])]])
        }).read()
        #expect(stocked.read == ["Fine"])
        #expect(stocked.phrases == 2)
        #expect(stocked.explained == 1, "the key index contributes spellings without definitions")
    }

    /// **Two dictionaries explaining the same phrase both survive, and each says which it is.**
    ///
    /// They were merged `{ first, _ in first }` in `DictionaryLocator.installed()` order — by identifier,
    /// which is nobody's preference — so one answer was discarded and the survivor was anonymous. On
    /// 牛津粵英雙語詞典 the same first-wins rule inside one dictionary loses **70 of 647** phrases.
    @Test func twoDictionariesExplainingOnePhraseBothSurvive() {
        func bundle(_ identifier: String, _ name: String) -> DictionaryBundle {
            DictionaryBundle(url: URL(fileURLWithPath: "/nonexistent/\(name).dictionary"),
                             identifier: identifier, displayName: name)
        }
        let reader = PhraseReader(
            bundles: [bundle("test.a", "A"), bundle("test.b", "B")],
            phrases: { bundle in
                PhraseInventory(
                    contentVersion: "v1", phrases: ["add up"],
                    explanations: ["add up": [PhraseExplanation(
                        parentEntryID: bundle.identifier, blockID: "\(bundle.identifier).01",
                        definitions: bundle.identifier == "test.a"
                            ? ["to seem reasonable or consistent"]
                            : ["to find the total of several numbers"])]])
            })
        reader.read()
        let filings = reader.filings(of: "add up")
        #expect(filings.count == 2, "neither dictionary's answer may be dropped")
        #expect(filings.map(\.dictionary.name) == ["A", "B"])
        #expect(filings.flatMap(\.definitions)
            == ["to seem reasonable or consistent", "to find the total of several numbers"])
    }

    /// **Every filing says which build of its dictionary and which extraction read it** (ADR-0049). A
    /// phrase the reader saves records where its meaning was found as a `StudyLocator`, and a block id is
    /// only true of the bytes and the walk it came from — so both travel with the filing, from the
    /// inventory that has them, rather than being guessed at the far end of the wire.
    @Test func everyFilingSaysWhichBuildAndWhichExtractionReadIt() {
        func bundle(_ identifier: String) -> DictionaryBundle {
            DictionaryBundle(url: URL(fileURLWithPath: "/nonexistent/\(identifier).dictionary"),
                             identifier: identifier, displayName: identifier)
        }
        let reader = PhraseReader(
            bundles: [bundle("test.a"), bundle("test.b")],
            phrases: { bundle in
                PhraseInventory(
                    contentVersion: "\(bundle.identifier):build", phrases: ["add up"],
                    explanations: ["add up": [PhraseExplanation(
                        parentEntryID: "p", blockID: "p.01", definitions: ["total"])]])
            })
        reader.read()
        let filings = reader.filings(of: "add up")
        #expect(filings.map(\.contentVersion) == ["test.a:build", "test.b:build"])
        #expect(filings.allSatisfy { $0.formatVersion == PhraseInventory.formatVersion })
        #expect(PhraseInventory.formatVersion.hasPrefix("phrases/"), "premise: the inventory's own version")
    }

    /// And the span the reader is standing in carries them, so the reply can attribute its own answer.
    @Test func aspanCarriesEveryFilingOfItsPhrase() {
        let filing = { (name: String, definition: String) in
            PhraseFiling(dictionary: DictionaryIdentity(name: name, identifier: "test.\(name)"),
                         parentEntryID: "p", blockID: "p.01", definitions: [definition],
                         contentVersion: "v1", formatVersion: "phrases/6")
        }
        let reader = PhraseReader(phrases: ["give up"], filings: [
            "give up": [filing("A", "stop trying"), filing("B", "surrender")]])
        let span = reader.phrase(in: "they give up too soon", at: NSRange(location: 5, length: 4))
        #expect(span?.filings.count == 2)
        #expect(span?.filings.first?.dictionary.name == "A")
    }
}
