import DictionaryModel
import Foundation
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import XiaolaiDictCore
import Testing

/// What the popup *claims*, given an entry and what the ledger knows. The plan asks for this at
/// view-model level, because what a popup asserts is the part that can be wrong.
struct EntryPresentationTests {
    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    private static func sense(_ ordinal: Int, _ key: String?, _ kind: SenseKeyKind, _ text: String) -> DictionarySense {
        DictionarySense(
            path: SensePath(block: 1, ordinal: ordinal), key: key, keyKind: kind,
            definition: text, text: text)
    }

    private static func entry(
        _ identity: DictionaryIdentity = noad, entryID: String? = "m2", homograph: String? = "2",
        blocks: [SenseBlock], pronunciations: [String] = ["fīn"]
    ) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: identity, headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: entryID, homograph: homograph,
                blocks: blocks, pronunciations: pronunciations))
    }

    private static let penalty = entry(blocks: [
        SenseBlock(number: 1, partOfSpeech: "noun", senses: [
            sense(1, "m2.005", .publisher, "money a court orders you to pay"),
        ]),
        SenseBlock(number: 2, partOfSpeech: "verb", senses: [
            sense(1, "m2.009", .publisher, "make someone pay for breaking a rule"),
        ]),
    ])

    @Test func theHeadingCarriesItsHomographNumber() {
        let popup = EntryPresentation(entry: Self.penalty, mark: nil, met: [])
        #expect(popup.heading == "fine²")
        #expect(popup.partsOfSpeech == ["noun", "verb"])
        #expect(popup.pronunciations == ["fīn"])
        #expect(popup.senses.count == 2)
        #expect(popup.canKeySenses)
    }

    /// A part of speech listed twice would read as two blocks of the same kind.
    @Test func partsOfSpeechDoNotRepeat() {
        let repeated = Self.entry(blocks: [
            SenseBlock(number: 1, partOfSpeech: "noun", senses: [Self.sense(1, "a", .publisher, "x")]),
            SenseBlock(number: 2, partOfSpeech: "noun", senses: [Self.sense(1, "b", .publisher, "y")]),
        ])
        #expect(EntryPresentation(entry: repeated, mark: nil, met: []).partsOfSpeech == ["noun"])
    }

    // MARK: - What may be called confirmed

    /// The assertion the plan names: **a sense a dictionary cannot key is never presented as a
    /// confirmed sense** — however it was marked. "This is the sense you read" needs a key to be
    /// true of.
    @Test func anUnkeyableSenseIsNeverConfirmed() {
        let unkeyable = Self.entry(entryID: "_8pm", homograph: nil, blocks: [
            SenseBlock(number: 1, partOfSpeech: nil, senses: [
                Self.sense(1, nil, SenseKeyKind.none, "made or done very well"),
            ]),
        ])
        for mark in [SenseMark.chosen(key: "1.1", by: .reader),
                     .chosen(key: "1.1", by: .onlySense),
                     .chosen(key: "1.1", by: .model)] {
            let popup = EntryPresentation(entry: unkeyable, mark: mark, met: [])
            #expect(popup.senses.allSatisfy { !$0.standing.isConfirmed }, "confirmed under \(mark)")
            #expect(!popup.canKeySenses)
        }
    }

    /// A sense the reader tapped is a fact.
    @Test func aSenseTheReaderTappedIsConfirmed() {
        let popup = EntryPresentation(
            entry: Self.penalty, mark: .chosen(key: "m2.005", by: .reader), met: [])
        #expect(popup.senses[0].standing == .confirmed(.reader))
        #expect(popup.senses[1].standing == .unclaimed)
    }

    /// One sense in an entry is a fact too: nothing was chosen, so nothing can be wrong.
    @Test func theOnlySenseIsConfirmed() {
        let single = Self.entry(blocks: [
            SenseBlock(number: 1, partOfSpeech: "noun", senses: [Self.sense(1, "m2.005", .publisher, "x")]),
        ])
        let popup = EntryPresentation(entry: single, mark: .chosen(key: "m2.005", by: .onlySense), met: [])
        #expect(popup.senses[0].standing == .confirmed(.onlySense))
    }

    /// A sense XiaolaiDict guessed is **proposed, never confirmed**. Measured on the only labelled set
    /// there is, the selector is confidently wrong between 0% and 33% of the time depending on
    /// which rung can run, so this distinction is not decoration.
    @Test func aSenseTheModelGuessedIsProposedNotConfirmed() {
        let popup = EntryPresentation(
            entry: Self.penalty, mark: .chosen(key: "m2.005", by: .model), met: [])
        #expect(popup.senses[0].standing == .proposed)
        #expect(!popup.senses[0].standing.isConfirmed, "a guess was presented as a fact")
    }

    /// An abstention claims nothing about any sense.
    @Test func anAbstentionMarksNothing() {
        let popup = EntryPresentation(entry: Self.penalty, mark: .couldNot(.tooClose), met: [])
        #expect(popup.senses.allSatisfy { $0.standing == .unclaimed })
    }

    /// A position key reads as the weaker claim it is (I4).
    @Test func aPositionalSenseSaysSo() {
        let positional = Self.entry(entryID: "e_id016730", homograph: nil, blocks: [
            SenseBlock(number: 1, partOfSpeech: "adjective", senses: [
                Self.sense(1, "1.1", .position, "很好的"),
            ]),
        ])
        let popup = EntryPresentation(entry: positional, mark: nil, met: [])
        #expect(popup.senses[0].keyKind == .position)
        #expect(popup.canKeySenses, "a positional sense is still keyable, just less precisely")
    }

    // MARK: - C3: senses already read

    /// Marked in the entry — which no surveyed dictionary does — and it is *whether*, never *what*.
    @Test func aSenseReadBeforeIsMarked() {
        let met: Set<StudyItem> = [StudyItem(
            dictionary: Self.noad.key, entryID: "m2", senseKey: "m2.009", senseKeyKind: .publisher)]
        let popup = EntryPresentation(entry: Self.penalty, mark: nil, met: met)
        #expect(popup.senses.map(\.metBefore) == [false, true])
    }

    /// The same sense key under a different dictionary is a different study item.
    @Test func anotherDictionarysSenseDoesNotCount() {
        let met: Set<StudyItem> = [StudyItem(
            dictionary: "name:Elsewhere", entryID: "m2", senseKey: "m2.005", senseKeyKind: .publisher)]
        let popup = EntryPresentation(entry: Self.penalty, mark: nil, met: met)
        #expect(popup.senses.allSatisfy { !$0.metBefore })
    }
}

/// C1–C4: prior encounters, not prior meanings.
struct MemoryStripTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// **Absent for a first lookup** — no empty state, no "0 previous". An empty memory strip is
    /// noise on the commonest case.
    @Test func aFirstLookupHasNoStrip() {
        #expect(MemoryStrip(PriorEncounters()) == nil)
    }

    @Test func itCountsTheLookupInHand() throws {
        let prior = PriorEncounters(occasions: [
            PriorEncounter(at: now.addingTimeInterval(-86_400), where: "Safari", title: "A page"),
            PriorEncounter(at: now.addingTimeInterval(-172_800), where: "Preview", title: nil),
        ])
        let strip = try #require(MemoryStrip(prior))
        #expect(strip.occasion == 3)
        #expect(strip.headline == "3rd lookup")
    }

    @Test(arguments: [(2, "2nd lookup"), (3, "3rd lookup"), (4, "4th lookup"),
                      (11, "11th lookup"), (21, "21st lookup"), (22, "22nd lookup"), (23, "23rd lookup")])
    func theOrdinalReadsCorrectly(occasion: Int, headline: String) throws {
        let earlier = (1..<occasion).map {
            PriorEncounter(at: now.addingTimeInterval(TimeInterval(-86_400 * $0)), where: "Safari", title: nil)
        }
        #expect(try #require(MemoryStrip(PriorEncounters(occasions: earlier))).headline == headline)
    }

    /// The strip says where and when, and is bounded — a strip that grows without bound is not one.
    @Test func itShowsWhereAndWhenBounded() throws {
        let earlier = (1...6).map {
            PriorEncounter(at: now.addingTimeInterval(TimeInterval(-86_400 * $0)), where: "Safari", title: "Page \($0)")
        }
        let strip = try #require(MemoryStrip(PriorEncounters(occasions: earlier)))
        #expect(strip.lines.count == MemoryStrip.shown)
        #expect(strip.more == 3, "the rest were dropped without saying so")
        #expect(strip.lines.allSatisfy { $0.contains("Page") })
    }

    /// An app that could say nothing still gives a when.
    @Test func anEncounterWithNoPlaceStillHasATime() throws {
        let strip = try #require(MemoryStrip(PriorEncounters(occasions: [
            PriorEncounter(at: now.addingTimeInterval(-3_600), where: nil, title: nil),
        ])))
        #expect(strip.lines.count == 1)
        #expect(!strip.lines[0].isEmpty)
    }
}

/// Decision D3: a pinned note is a **copy**, with its dictionary id and version recorded, so a
/// dictionary update cannot silently rewrite a note the reader kept.
struct PinnedNoteTests {
    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    private func note(_ dictionary: DictionaryIdentity, text: String) -> PinnedNote {
        PinnedNote(
            heading: "fine²", dictionary: dictionary, partOfSpeech: "noun",
            pronunciation: "fīn", text: text, standing: .confirmed)
    }

    /// The words are held by value. Nothing reaches back into the dictionary to re-read them.
    @Test func itHoldsItsOwnWords() {
        let pinned = note(noad, text: "money a court orders you to pay")
        #expect(pinned.text == "money a court orders you to pay")
        #expect(pinned.heading == "fine²")
    }

    /// Which dictionary, and which version of it — a sense key is only meaningful inside one version.
    @Test func itRecordsWhichVersionOfWhichDictionary() {
        #expect(note(noad, text: "x").provenance == "New Oxford American Dictionary 2.6")
    }

    /// A sideloaded conversion has no version; the note says what it can rather than inventing one.
    @Test func aDictionaryWithoutAVersionStillSaysWhichItWas() {
        let collins = DictionaryIdentity(name: "Collins COBUILD")
        #expect(note(collins, text: "x").provenance == "Collins COBUILD")
    }

    /// Two notes pinned from the same sense are still two notes, so closing one cannot close both.
    @Test func everyNoteIsItsOwn() {
        #expect(note(noad, text: "x") != note(noad, text: "x"))
    }
}
