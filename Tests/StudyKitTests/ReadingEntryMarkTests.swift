import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
import Testing

/// The one test that mixed the two subjects, split out of `LemmatizerTests` when the ledger left the core:
/// a reading's marks are the lemmatizer's, asked through the study side's own adapter.
struct ReadingEntryMarkTests {
    /// `ReadingEntry.markedRanges` is an adapter and nothing more. This is what says so.
    @Test func aCardAsksTheLemmatizerRatherThanRepeatingIt() {
        let sentence = "He took it over."
        let entry = ReadingEntry(
            id: 1, lemma: "take over", surface: "took", sentence: sentence,
            sentenceRange: (sentence as NSString).range(of: "took"),
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found, quality: nil)
        #expect(entry.markedRanges == Lemmatizer.parts(
            of: "take over", surface: "took", in: sentence,
            at: (sentence as NSString).range(of: "took")))
    }
}
