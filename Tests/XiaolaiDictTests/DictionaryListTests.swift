import DictionaryModel
import Foundation
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **The footer's dictionary control, as a value — because the chips it replaces could not name their
/// own items.**
///
/// `showing` indexes *entries*, and one dictionary contributes several: NOAD answers *fine* with four,
/// and `DictionaryEntry.collapsingRepeatedRecords` merges only same-*id* records, so all four survive
/// on purpose ("the private API returns several records per dictionary, and **every one reaches the
/// reader**"). The chips were labelled by dictionary name alone, so the row drew four chips reading
/// "New Oxford American Dictionary" and a reader picking among them was guessing.
///
/// Measured beside it: eight full names need **1,282 pt** in a card 396 pt wide, so the row overflowed
/// at four dictionaries as well.
struct DictionaryListTests {
    private func entry(_ dictionary: String, headword: String, id: String) -> DictionaryEntry {
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rfc" id="\(id)" d:title="\(headword)">
            <span class="hg x_xh0"><span class="hw">\(headword)</span></span>
            <span id="\(id).001" class="se1 x_xd0"><span id="\(id).002" class="se2 x_xd1 hasSn">
            <span d:def="1" class="df">a meaning</span></span></span>
            </d:entry>
            """
        return DictionaryEntry(
            dictionary: DictionaryIdentity(name: dictionary, identifier: dictionary, version: "1"),
            headword: headword, lookedUp: "fine", html: markup,
            document: EntryDocument.parse(markup))
    }

    /// Four homographs from one dictionary and one entry from another — the shape that broke the chips.
    private var eight: [DictionaryEntry] {
        (1...4).map { entry("New Oxford American Dictionary", headword: "fine\($0)", id: "noad\($0)") }
            + [entry("Oxford American Writer's Thesaurus", headword: "fine", id: "oawt")]
    }

    /// **No two rows read alike.** The one property the chips did not have, and the reason a reader
    /// could not choose between them.
    @Test func everyRowNamesADifferentEntry() {
        let labels = DictionaryList(of: eight).rows.map(\.label)
        #expect(labels.count == 5)
        #expect(Set(labels).count == labels.count, "two rows read the same: \(labels)")
    }

    /// **The headword only where it separates two rows.** A dictionary that answered once is named by
    /// itself; adding its headword everywhere would be noise on the ordinary card.
    @Test func theHeadwordIsAddedOnlyWhereADictionaryAnsweredMoreThanOnce() throws {
        let rows = DictionaryList(of: eight).rows
        let thesaurus = try #require(rows.last)
        #expect(thesaurus.label == "Oxford American Writer's Thesaurus",
                "a dictionary that answered once was given a headword it did not need")
        #expect(rows.dropLast().allSatisfy { $0.label.contains("fine") },
                "the four NOAD entries are not told apart by their headwords: \(rows.map(\.label))")
    }

    /// **Every entry is reachable.** Collapsing by dictionary would lose three of NOAD's four, which
    /// is the invariant about every record reaching the reader, broken at the last step.
    @Test func everyEntryIsReachable() {
        #expect(DictionaryList(of: eight).rows.map(\.index) == [0, 1, 2, 3, 4])
    }

    /// **The count is of dictionaries, never of entries.** "4 others" for one dictionary answering
    /// four times would be counting NOAD four times.
    @Test func theSummaryCountsDictionariesAndNotEntries() {
        #expect(DictionaryList(of: eight).otherDictionaries == 1)
        let two = [eight[0], eight[4]]
        #expect(DictionaryList(of: two).otherDictionaries == 1)
        #expect(DictionaryList(of: [eight[0]]).otherDictionaries == 0)
    }

    /// One entry is no choice at all, and the control says nothing.
    @Test func oneEntryIsNotAChoice() {
        #expect(DictionaryList(of: [eight[0]]).isWorthShowing == false)
        #expect(DictionaryList(of: eight).isWorthShowing)
    }

    /// **Four entries from one dictionary is still a choice**, even though only one dictionary
    /// answered — the reader has four entries to pick between and the old chips made that unusable.
    @Test func severalEntriesFromOneDictionaryAreStillAChoice() {
        let noadOnly = Array(eight.prefix(4))
        let list = DictionaryList(of: noadOnly)
        #expect(list.isWorthShowing, "four entries were offered as no choice at all")
        #expect(list.otherDictionaries == 0)
        #expect(Set(list.rows.map(\.label)).count == 4)
    }
}
