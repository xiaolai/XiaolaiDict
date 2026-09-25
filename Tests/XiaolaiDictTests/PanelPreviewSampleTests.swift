import DictionaryModel
import Foundation
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// The lookup panel's preview sample, checked as data.
///
/// A preview is the only way to look at this panel without a dictionary installed, and it is built
/// the way the app is — real `d:entry` markup through `EntryDocument.parse` — so that a preview
/// cannot look right while the parser is wrong. The failure this guards is the quiet one: markup
/// that stops parsing gives an entry with no senses, which draws as a card with nothing to lead
/// with and reads exactly like a bug in the app rather than a stale fixture.
struct PanelPreviewSampleTests {
    private let entry = sampleEntry("New Oxford American Dictionary")

    @Test func theSampleParsesIntoTheEntryTheCardNeeds() {
        #expect(entry.headword == "fine")
        #expect(entry.entryID == "m_en_gbus0362750")
        #expect(entry.pronunciations.isEmpty == false, "the heading would have no respelling")
        // Two part-of-speech blocks, so a sense carries a part of speech the card can lead with.
        #expect(entry.blocks.count == 2)
        #expect(entry.senseCount == 4)
    }

    /// Publisher ids, not positions — the sample has to exercise the rung the real dictionaries
    /// reach, or the preview shows a weaker keying than the reader will ever see.
    @Test func theSampleSensesCarryPublisherKeys() {
        #expect(entry.senseKeyKind == .publisher)
        #expect(entry.senses.allSatisfy { $0.keyKind == .publisher })
    }

    /// **The mismatch that would show nothing and explain nothing.** The previews mark a sense by
    /// key; a key that no sense carries draws no mark at all, and the preview would look like a
    /// selector that had failed rather than a fixture that had drifted.
    @Test func everyKeyThePreviewsMarkIsAKeyTheSampleHas() {
        let keys = Set(entry.senses.compactMap(\.key))
        #expect(keys.contains("m_en_gbus0362750.005"), "the reader-chosen preview marks nothing")
        #expect(keys.contains("m_en_gbus0362750.020"), "the XiaolaiDict-guessed preview marks nothing")
    }

    /// Two dictionaries, so the panel has a primary and an auxiliary — the case where the card's
    /// footer, D8's tap-to-study and `PanelSelection`'s per-entry filing are worth looking at. A
    /// one-dictionary sample previews none of them.
    @Test func theSampleIsTwoDictionariesAndNotOne() {
        let entries = [
            sampleEntry("New Oxford American Dictionary"), sampleEntry("Oxford Thesaurus"),
        ]
        #expect(Set(entries.map(\.dictionary.key)).count == 2)
        // And the panel can tell them apart. Both are built from the same markup, so they carry
        // the same publisher ids — an identity taken from the entry id alone would file a tap in
        // the thesaurus against NOAD.
        #expect(PanelSelection.identity(of: entries[0]) != PanelSelection.identity(of: entries[1]))
    }

    /// The pane is a web view, so the markup has to arrive as a document rather than as a
    /// fragment, and it has to carry the style that makes it read as an entry.
    @Test func theSampleIsAWholeStyledDocument() {
        let markup = sampleMarkup()
        #expect(markup.hasPrefix("<html"))
        #expect(markup.contains("<style>"))
        #expect(markup.contains("-apple-system"), "the pane would not follow the system appearance")
    }

    /// **The entry previews are not the waiting preview.**
    ///
    /// Worth asserting because the two are indistinguishable from the outside if `outcome` is
    /// ever left nil: `PanelView` falls back to the waiting pane, and the preview quietly shows a
    /// spinner and the term — which is exactly what the panel looked like when it had no entry
    /// preview at all, and is therefore the one wrong result nobody would question.
    @Test func theEntryPreviewsActuallyCarryAnEntry() {
        let marked = sampleLookup(.chosen(key: "m_en_gbus0362750.005", by: .reader))
        #expect(marked.outcome != nil, "the preview would fall back to the waiting pane")
        #expect(PanelContent.lookup(marked).waitingDescription == nil, "the preview is still waiting")
        #expect(marked.memory != nil)
        #expect(marked.sentence?.isEmpty == false)
        // The header and the entry have to be the same word. They were not at first: the sample
        // was built from the waiting one, so the panel read "ephemeral" above an entry for "fine".
        #expect(marked.term == entry.headword)
        #expect(marked.sentence?.localizedCaseInsensitiveContains(marked.term) == true,
                "the sentence does not contain the word it is the cue for")

        // And the waiting preview still is one, so the pair keeps covering both states.
        #expect(sampleWaiting().outcome == nil)
        #expect(PanelContent.lookup(sampleWaiting()).waitingDescription != nil)
    }
}
