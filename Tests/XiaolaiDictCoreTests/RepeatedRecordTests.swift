import DictionaryModel
import Foundation
import XiaolaiDictCore
import Testing

/// One entry indexed under several headwords is **one entry**, however many records the framework
/// answers with.
///
/// Measured through the private API on this Mac, 2026-09-21: NOAD answers *cougher* with two
/// records, both `m_en_gbus0224890`, headed *cough* and *cougher*; the Writer's Thesaurus answers
/// *run* with two, both `t_en_gb0012791`, headed *run* and *-run*; 譯典通 answers 的 with three,
/// all `z_id009726`, headed by its three readings. The documents are the same entry — for 的 they
/// are byte-identical, and the other two differ only in the `aria-label` naming the index form the
/// search matched.
///
/// Left alone, each copy became a `DictionaryEntry`, and the two places that treat an entry id as
/// an identity both read the copies as ambiguity: `SenseResolver` refuses a chosen sense whose key
/// more than one entry holds, and `PrimaryDictionary.encounter` records nothing where the primary
/// answered with more than one entry. So a reader looking up *run* with the thesaurus as their
/// primary got no sense mark and no ledger encounter — silently, with no abstention reason, and
/// for 6.4% of the words in a 300-word sweep.
struct RepeatedRecordTests {
    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD")
    private let thesaurus = DictionaryIdentity(
        name: "Oxford American Writer's Thesaurus", identifier: "com.apple.dictionary.OAWT")

    private func entry(
        _ dictionary: DictionaryIdentity, headword: String, lookedUp: String, id: String?
    ) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: dictionary, headword: headword, lookedUp: lookedUp, html: "<p/>",
            document: EntryDocument(isStyled: true, entryID: id, homograph: nil))
    }

    /// The thesaurus case: *run* and *-run* are two ways into `t_en_gb0012791`.
    @Test func oneEntryIndexedTwiceAnswersOnce() {
        let records = [
            entry(thesaurus, headword: "run", lookedUp: "run", id: "t_en_gb0012791"),
            entry(thesaurus, headword: "-run", lookedUp: "run", id: "t_en_gb0012791"),
        ]
        #expect(DictionaryEntry.collapsingRepeatedRecords(records).map(\.entryID) == ["t_en_gb0012791"])
    }

    /// The NOAD case, and why the one kept is chosen rather than taken first: the reader looked up
    /// *cougher*, and the record NOAD lists first is headed *cough*. Keeping that one would title
    /// the panel with a word the reader did not read and report the match as `.otherHeadword`.
    @Test func theRecordThatAnswersTheTermIsTheOneKept() {
        let records = [
            entry(noad, headword: "cough", lookedUp: "cougher", id: "m_en_gbus0224890"),
            entry(noad, headword: "cougher", lookedUp: "cougher", id: "m_en_gbus0224890"),
        ]
        let kept = DictionaryEntry.collapsingRepeatedRecords(records)
        #expect(kept.map(\.headword) == ["cougher"])
        #expect(kept.map(\.match) == [.exact])
    }

    /// A dictionary's entries stay contiguous and in the order the reader set in Dictionary.app,
    /// so the one kept sits where the first of its copies did — never at the end.
    @Test func theKeptRecordStaysWhereTheFirstCopyWas() {
        let records = [
            entry(noad, headword: "cough", lookedUp: "cougher", id: "m_en_gbus0224890"),
            entry(noad, headword: "coughing", lookedUp: "cougher", id: "m_en_gbus0224900"),
            entry(noad, headword: "cougher", lookedUp: "cougher", id: "m_en_gbus0224890"),
        ]
        let kept = DictionaryEntry.collapsingRepeatedRecords(records)
        #expect(kept.map(\.headword) == ["cougher", "coughing"])
    }

    /// **Homographs are not copies.** *fine* is four entries in NOAD sharing one headword, and
    /// collapsing by headword rather than by id would throw away three meanings. Only the id
    /// decides.
    @Test func entriesSharingOnlyAHeadwordAreBothKept() {
        let records = [
            entry(noad, headword: "fine", lookedUp: "fine", id: "m_en_gbus0362750"),
            entry(noad, headword: "fine", lookedUp: "fine", id: "m_en_gbus0362760"),
        ]
        #expect(DictionaryEntry.collapsingRepeatedRecords(records).count == 2)
    }

    /// An entry that declared no id is unknown, not equal to every other unknown. Merging on nil
    /// would collapse a whole dictionary's answer into one entry.
    @Test func entriesWithoutAnIDAreNeverMerged() {
        let records = [
            entry(noad, headword: "cough", lookedUp: "cougher", id: nil),
            entry(noad, headword: "cougher", lookedUp: "cougher", id: nil),
        ]
        #expect(DictionaryEntry.collapsingRepeatedRecords(records).count == 2)
    }

    /// Ids are a dictionary's own; two dictionaries may use the same string for different entries.
    @Test func theSameIDInTwoDictionariesIsTwoEntries() {
        let records = [
            entry(noad, headword: "run", lookedUp: "run", id: "m1"),
            entry(thesaurus, headword: "run", lookedUp: "run", id: "m1"),
        ]
        #expect(DictionaryEntry.collapsingRepeatedRecords(records).count == 2)
    }

    @Test func nothingToCollapseLeavesTheAnswerAsItWas() {
        let records = [
            entry(noad, headword: "run", lookedUp: "run", id: "m1"),
            entry(thesaurus, headword: "run", lookedUp: "run", id: "t1"),
        ]
        #expect(DictionaryEntry.collapsingRepeatedRecords(records) == records)
    }
}
