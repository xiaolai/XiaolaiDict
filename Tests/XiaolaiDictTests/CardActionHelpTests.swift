import DictionaryModel
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **A disabled Pin or Copy says what to do, not only why it is off.** The card lists the entry's other
/// meanings beside a greyed Pin, and "No meaning was identified" left the reader no way to tell that
/// choosing one is what turns it on. The help is the tooltip and the accessibility hint both
/// (`IconButton.tooltip`, `IconButton.spokenHint`), so asserting it here covers both.
struct CardActionHelpTests {
    private let entry = sampleEntry("New Oxford American Dictionary")

    private func card(_ mark: SenseMark?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: "It was a fine piece of filmmaking.", mark: mark)
    }

    @Test func aCardWithMeaningsToChooseSaysToChooseOne() {
        let undecided = card(.couldNot(.tooClose))
        #expect(undecided.senseToKeep == nil, "the premise: nothing to pin yet")
        #expect(!undecided.alternatives.isEmpty, "the premise: meanings are listed to choose from")
        #expect(CardActionHelp.pin(undecided) == Text("Choose a meaning first, then pin it"))
        #expect(CardActionHelp.copy(undecided) == Text("Choose a meaning first, then copy it"))
    }

    @Test func anEnabledControlHasNoHelp() {
        let chosen = card(.chosen(key: "m_en_gbus0362750.005", by: .reader))
        #expect(chosen.senseToKeep != nil)
        #expect(CardActionHelp.pin(chosen) == nil)
        #expect(CardActionHelp.copy(chosen) == nil)
    }

    /// Where there is nothing to choose, choosing is not the remedy and the help does not offer it.
    @Test func aCardWithNothingToChooseKeepsTheReason() {
        let nothing = LookupCard(
            presentation: EntryPresentation(entry: DictionaryEntry(
                dictionary: DictionaryIdentity(name: "Plain", identifier: "plain"), headword: "fine", lookedUp: "fine",
                html: "<p/>", document: EntryDocument(isStyled: true, entryID: "e", homograph: nil, blocks: [])),
                mark: nil, met: []),
            term: "fine", sentence: nil, mark: nil)
        #expect(nothing.alternatives.isEmpty, "the premise: no meanings listed")
        #expect(CardActionHelp.pin(nothing) == Text("No meaning was identified, so there is nothing to pin"))
        #expect(CardActionHelp.copy(nothing) == Text("No meaning was identified, so there is nothing to copy"))
    }
}
