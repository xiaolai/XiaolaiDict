import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **The library marks the word the reader looked up, where they looked it up.**
///
/// The row's sentence was marked by a case-insensitive substring search for the word, so *he* lit
/// up inside *Then* and *the*, and the second word of a phrasal verb read apart was never marked.
/// The drawer already answers this question from the captured range through `Lemmatizer.parts`;
/// the library carries the same facts and asks the same function.
struct LibraryExcerptMarksTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(surface: String, lemma: String, sentence: String,
                     at range: NSRange?) throws -> LibraryRow {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(LookupRecord(
            surface: surface, lemma: lemma, context: sentence, lemmaBasis: .tagger,
            language: "en", contextRange: range, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a meaning"), lookupID: lookup, at: now)
        return try #require(try ledger.library(LibraryQuery()).first)
    }

    @Test func aShortWordIsNotMarkedInsideLongerOnes() throws {
        let sentence = "Then the man said he would."
        let he = (sentence as NSString).range(of: " he ").location + 1
        let marked = NSRange(location: he, length: 2)
        let found = try row(surface: "he", lemma: "he", sentence: sentence, at: marked)
        #expect(found.excerptMarks == [marked], "only the word looked up, not `he` in Then or the")
    }

    @Test func thePhraseIsMarkedWhereItsWordsAre() throws {
        let sentence = "She took it over."
        let text = sentence as NSString
        let took = text.range(of: "took")
        let found = try row(surface: "took", lemma: "take over", sentence: sentence, at: took)
        #expect(found.excerptMarks == [took, text.range(of: "over")])
    }

    /// The same adapter the drawer's `markedRanges` is, so the two surfaces cannot disagree.
    @Test func theMarksAreTheDrawersMarks() throws {
        let sentence = "Justice tempered with mercy."
        let range = NSRange(location: 8, length: 6)
        let found = try row(surface: "temper", lemma: "temper", sentence: sentence, at: range)
        #expect(found.excerptMarks == Lemmatizer.parts(of: "temper", surface: "temper",
                                                       in: sentence, at: range))
        #expect(found.excerptMarks == [NSRange(location: 8, length: 8)], "the whole word, tempered")
    }
}
