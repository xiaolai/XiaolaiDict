import DictionaryModel
import Foundation
@testable import XiaolaiDict
import XiaolaiDictCore
import Testing
import XiaolaiDictTestSupport

/// Decision D7: the reader studies from one dictionary, and the others are there to consult.
struct PrimaryDictionaryTests {
    private static func entry(
        _ name: String, identifier: String?, entryID: String?, senses: [DictionarySense]
    ) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: name, identifier: identifier, version: "1.0"),
            headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: entryID, homograph: nil,
                blocks: senses.isEmpty ? [] : [SenseBlock(number: 1, partOfSpeech: "noun", senses: senses)]))
    }

    private static func sense(_ ordinal: Int, _ key: String, _ kind: SenseKeyKind = .publisher) -> DictionarySense {
        DictionarySense(
            path: SensePath(block: 1, ordinal: ordinal), key: key, keyKind: kind,
            definition: "meaning \(ordinal)", text: "meaning \(ordinal)")
    }

    private static let collins = entry("Collins COBUILD", identifier: nil, entryID: "_8pm", senses: [])
    private static let noad = entry(
        "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", entryID: "m1",
        senses: [sense(1, "m1.001")])
    private static let oxford = entry(
        "牛津英汉汉英词典", identifier: "com.apple.dictionary.zh_CN-en.OCD", entryID: "b1",
        senses: [sense(1, "b1.001"), sense(2, "b1.002")])

    /// Unchosen, XiaolaiDict does not simply take the first dictionary the reader happened to rank first:
    /// a primary that cannot key a sense can never produce a sense-level card.
    @Test func unchosenItPicksTheFirstThatCanKeyASense() {
        let primary = PrimaryDictionary()
        #expect(primary.identity(among: [Self.collins, Self.noad, Self.oxford])?.name
            == "New Oxford American Dictionary")
    }

    /// If none of them can, an entry-level study item is still a study item.
    @Test func withNothingKeyableItTakesTheFirst() {
        #expect(PrimaryDictionary().identity(among: [Self.collins])?.name == "Collins COBUILD")
        #expect(PrimaryDictionary().identity(among: []) == nil)
    }

    @Test func theReadersChoiceWins() {
        let primary = PrimaryDictionary(chosen: "com.apple.dictionary.zh_CN-en.OCD")
        #expect(primary.identity(among: [Self.collins, Self.noad, Self.oxford])?.name == "牛津英汉汉英词典")
    }

    /// A dictionary the reader chose and then disabled must not make every lookup unkeyed.
    @Test func aChoiceThatDidNotAnswerFallsBack() {
        let primary = PrimaryDictionary(chosen: "com.apple.dictionary.gone")
        #expect(primary.identity(among: [Self.collins, Self.noad])?.name == "New Oxford American Dictionary")
    }

    // MARK: - What a lookup may record

    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    /// One entry, one sense: nothing was chosen, so nothing can be wrong.
    @Test func oneEntryWithOneSenseIsRecordedAsTheOnlySense() throws {
        let encounter = try #require(PrimaryDictionary().encounter(among: [Self.noad], at: when))
        #expect(encounter.senseKey == "m1.001")
        #expect(encounter.chosenBy == .onlySense)
        #expect(encounter.entrySenseCount == 1)
        #expect(encounter.senseHash != nil)
    }

    /// One entry, several senses: the entry is known, the sense is not, and null says exactly that.
    @Test func oneEntryWithSeveralSensesIsRecordedAtEntryLevel() throws {
        let encounter = try #require(
            PrimaryDictionary(chosen: "com.apple.dictionary.zh_CN-en.OCD").encounter(among: [Self.oxford], at: when))
        #expect(encounter.entryID == "b1")
        #expect(encounter.senseKey == nil)
        #expect(encounter.chosenBy == nil, "a sense nobody chose was attributed to somebody")
        #expect(encounter.entrySenseCount == 2)
    }

    /// Several entries from the primary: *fine* is four in NOAD, and picking one would be a guess.
    @Test func severalEntriesRecordNothingYet() {
        let a = Self.entry("NOAD", identifier: "n", entryID: "m1", senses: [Self.sense(1, "m1.1")])
        let b = Self.entry("NOAD", identifier: "n", entryID: "m2", senses: [Self.sense(1, "m2.1")])
        #expect(PrimaryDictionary().encounter(among: [a, b], at: when) == nil)
    }

    /// Decision D8: auxiliary dictionaries are consulted, never studied automatically.
    @Test func onlyThePrimaryIsRecorded() throws {
        let encounter = try #require(PrimaryDictionary().encounter(among: [Self.noad, Self.oxford], at: when))
        #expect(encounter.dictionary.name == "New Oxford American Dictionary")
    }

    /// A dictionary with no sense structure still gives an entry-level encounter, and says so.
    @Test func anUnkeyableDictionaryStillRecordsItsEntry() throws {
        let encounter = try #require(PrimaryDictionary().encounter(among: [Self.collins], at: when))
        #expect(encounter.senseKeyKind == SenseKeyKind.none)
        #expect(encounter.senseKey == nil)
        #expect(encounter.entrySenseCount == 0)
        #expect(encounter.dictionary.key == "name:Collins COBUILD")
    }

    /// Without an entry id there is nothing to key to, and nothing is written.
    @Test func anEntryWithoutAnIDRecordsNothing() {
        let anonymous = Self.entry("X", identifier: "x", entryID: nil, senses: [Self.sense(1, "a")])
        #expect(PrimaryDictionary().encounter(among: [anonymous], at: when) == nil)
    }

    @Test func theChoiceSurvivesALaunch() {
        let defaults = TemporaryDefaults.suite()
        let store = PrimaryDictionaryStore(defaults: defaults)
        #expect(store.load().chosen == nil)
        store.save("com.apple.dictionary.NOAD")
        #expect(PrimaryDictionaryStore(defaults: defaults).load().chosen == "com.apple.dictionary.NOAD")
        store.save(nil)
        #expect(store.load().chosen == nil)
    }
}

/// The resolver: rung 0 first, then the selector, then honest silence — and the provenance that
/// keeps a guess apart from a fact.
struct SenseResolverTests {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entry(
        _ name: String, identifier: String?, entryID: String?, senses: [DictionarySense],
        partOfSpeech: String? = "noun"
    ) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: name, identifier: identifier, version: "1.0"),
            headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: entryID, homograph: nil,
                blocks: senses.isEmpty ? [] : [SenseBlock(number: 1, partOfSpeech: partOfSpeech, senses: senses)]))
    }

    private static func sense(_ ordinal: Int, _ key: String) -> DictionarySense {
        DictionarySense(
            path: SensePath(block: 1, ordinal: ordinal), key: key, keyKind: .publisher,
            definition: "meaning \(ordinal)", text: "meaning \(ordinal)")
    }

    /// A sense addressed by where it sits. Its key is `"block.ordinal"` and carries nothing about
    /// which entry it came from, which is the whole reason the resolver needs the entry as well.
    private static func positional(_ ordinal: Int, in block: Int = 1) -> DictionarySense {
        DictionarySense(
            path: SensePath(block: block, ordinal: ordinal), key: "\(block).\(ordinal)",
            keyKind: .position, definition: "meaning \(ordinal)", text: "meaning \(ordinal)")
    }

    private static func unkeyable() -> DictionarySense {
        DictionarySense(
            path: SensePath(block: 1, ordinal: 1), key: nil, keyKind: SenseKeyKind.none,
            definition: "meaning", text: "meaning")
    }

    /// A selector that always says the same thing, so the resolver is what is under test.
    private struct Fixed: SenseSelecting {
        let answer: SenseSelection
        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection { answer }
    }

    private func resolve(
        _ entries: [DictionaryEntry], _ answer: SenseSelection, context: CaptureQuality.Context = .complete
    ) async -> SenseResolution {
        await SenseResolver(primary: PrimaryDictionary(), selector: Fixed(answer: answer)).resolve(
            entries: entries, sentence: "He paid the fine.", context: context, partOfSpeech: "noun", at: when)
    }

    /// Rung 0: one entry, one sense. The selector never runs, and what is recorded is not credited
    /// to a model that did nothing.
    @Test func oneSenseIsResolvedWithoutTheSelector() async throws {
        let single = Self.entry("NOAD", identifier: "n", entryID: "e1", senses: [Self.sense(1, "e1.001")])
        // A selector that would answer wrongly if it were asked — it must not be asked.
        let resolution = await resolve([single], .chose(key: "wrong", margin: 9))
        #expect(resolution.mark == .chosen(key: "e1.001", by: .onlySense))
        #expect(resolution.encounter?.chosenBy == .onlySense)
    }

    /// **Two entries, one key.** A positional key is literally `"\(block).\(ordinal)"` — no entry
    /// id, no hash — so every entry in a dictionary has a sense keyed `"1.1"`. Resolving a choice
    /// by key alone took the first entry that happened to contain one, which is the right sense of
    /// the wrong word, written into the study ledger as a fact.
    @Test func aPositionalKeyIsResolvedInTheEntryItWasChosenFrom() async throws {
        let first = Self.entry(
            "NOAD", identifier: "n", entryID: "first",
            senses: [Self.positional(1)])
        let second = Self.entry(
            "NOAD", identifier: "n", entryID: "second",
            senses: [Self.positional(1)])

        let resolution = await resolve(
            [first, second], .chose(key: "1.1", margin: 9, entryID: "second"))
        let encounter = try #require(resolution.encounter)
        // `entryKey` is the entry's own id where it has one, so it names which of the two.
        #expect(encounter.entryID == "second",
                "resolved to \(encounter.entryID) — the first entry that happened to match")
    }

    /// Where the selector did not say which entry, the old behaviour stands rather than the
    /// resolution failing: an answer from a selector that predates the field is still an answer.
    @Test func aChoiceWithNoEntryStillResolves() async throws {
        let entry = Self.entry(
            "NOAD", identifier: "n", entryID: "only",
            senses: [Self.positional(1), Self.positional(2)])
        let resolution = await resolve([entry], .chose(key: "1.2", margin: 9))
        #expect(resolution.mark == .chosen(key: "1.2", by: .model))
    }

    /// **An unkeyable sense is never presented as confirmed, however it was marked.** It reaches
    /// the resolver with an empty key, and `.onlySense` is the most confirmed mark there is —
    /// writing one would have put the id of a sense nothing can point at again into the ledger.
    @Test func theOnlySenseOfAnUnkeyableEntryIsNotConfirmed() async throws {
        let unkeyable = Self.entry(
            "Collins", identifier: "c", entryID: "e1",
            senses: [Self.unkeyable()])
        let resolution = await resolve([unkeyable], .abstained(.noCandidates))
        #expect(resolution.mark?.key == nil, "an unkeyable sense was marked as chosen")
        if case .chosen(_, let by) = resolution.mark {
            Issue.record("marked \(by) for a sense the dictionary cannot key")
        }
        // **And the encounter, not only the mark.** The guard was on the mark alone, so the
        // abstention fallback wrote `.onlySense` — the most confirmed provenance there is — into
        // the ledger for the same sense the panel had just refused to confirm. Checking the mark
        // here and stopping is what let that live: the two paths have to agree.
        //
        // The entry is still recorded, because it is still a fact that the reader met it. What
        // must be empty is every field that would claim a *sense*: asserting only that `chosenBy`
        // is not `.onlySense` would pass on an encounter that named the unkeyable sense and merely
        // attributed it differently.
        let encounter = try #require(resolution.encounter, "the entry the reader met was dropped")
        #expect(encounter.chosenBy == nil, "the ledger confirmed a sense the dictionary cannot key")
        #expect(encounter.chosenAt == nil)
        #expect(encounter.senseKey == nil)
        #expect(encounter.senseHash == nil)
        #expect(encounter.gloss == nil)
    }

    /// **A key alone does not name an entry, so an ambiguous one is refused rather than guessed
    /// at.** Positional keys are literally `"block.ordinal"`, so every entry for a headword has a
    /// `"1.1"`. Taking the first match picks by document order — the right sense of the wrong
    /// entry, written to the ledger as a fact. Where the selector named no entry and more than one
    /// holds the key, nothing is claimed: no mark and no encounter. Not the mark without the
    /// encounter — a mark is a highlight drawn in an entry, and which entry is exactly what is
    /// unknown here.
    @Test func anAmbiguousKeyWithNoEntryResolvesToNothing() async throws {
        let first = Self.entry(
            "NOAD", identifier: "n", entryID: "first", senses: [Self.positional(1)])
        let second = Self.entry(
            "NOAD", identifier: "n", entryID: "second", senses: [Self.positional(1)])
        let resolution = await resolve([first, second], .chose(key: "1.1", margin: 9))
        #expect(resolution.encounter == nil,
                "resolved \(resolution.encounter?.entryID ?? "?") from a key both entries hold")
        #expect(resolution.mark == nil, "marked a sense in an entry it could not identify")
    }

    /// A sense the selector picked is a hypothesis, and is recorded as one.
    @Test func aChosenSenseIsRecordedAsTheModelsGuess() async throws {
        let entry = Self.entry(
            "NOAD", identifier: "n", entryID: "e1",
            senses: [Self.sense(1, "e1.001"), Self.sense(2, "e1.002")])
        let resolution = await resolve([entry], .chose(key: "e1.002", margin: 0.2))
        #expect(resolution.mark == .chosen(key: "e1.002", by: .model))
        #expect(resolution.mark?.isHypothesis == true, "a guess did not read as a guess")
        let encounter = try #require(resolution.encounter)
        #expect(encounter.senseKey == "e1.002")
        #expect(encounter.chosenBy == .model)
        #expect(encounter.chosenAt == when)
        #expect(encounter.entrySenseCount == 2)
        #expect(encounter.senseHash != nil)
    }

    /// An abstention still says why, and still records whatever *is* a fact — the entry.
    @Test func anAbstentionSaysWhyAndKeepsTheEntry() async throws {
        let entry = Self.entry(
            "NOAD", identifier: "n", entryID: "e1",
            senses: [Self.sense(1, "e1.001"), Self.sense(2, "e1.002")])
        let resolution = await resolve([entry], .abstained(.tooClose))
        #expect(resolution.mark == .couldNot(.tooClose))
        #expect(resolution.mark?.isHypothesis == false)
        let encounter = try #require(resolution.encounter)
        #expect(encounter.entryID == "e1")
        #expect(encounter.senseKey == nil, "an abstention wrote down a sense anyway")
        #expect(encounter.chosenBy == nil, "a sense nobody chose was attributed to somebody")
    }

    /// The case that makes *fine* work: the right sense is in the primary's **second** entry, and
    /// the selector chooses across all of them.
    @Test func aSenseInAnotherEntryOfThePrimaryIsStillChosen() async throws {
        let first = Self.entry("NOAD", identifier: "n", entryID: "m1", senses: [Self.sense(1, "m1.005")])
        let second = Self.entry("NOAD", identifier: "n", entryID: "m2", senses: [Self.sense(1, "m2.005")])
        let resolution = await resolve([first, second], .chose(key: "m2.005", margin: 0.3))
        #expect(resolution.encounter?.entryID == "m2", "the sense was hung off the wrong entry")
        #expect(resolution.encounter?.senseKey == "m2.005")
    }

    /// Several entries and an abstention: the entry is unknown too, and nothing is written.
    @Test func severalEntriesAndNoChoiceRecordNothing() async {
        let first = Self.entry("NOAD", identifier: "n", entryID: "m1", senses: [Self.sense(1, "m1.005")])
        let second = Self.entry("NOAD", identifier: "n", entryID: "m2", senses: [Self.sense(1, "m2.005")])
        let resolution = await resolve([first, second], .abstained(.tooClose))
        #expect(resolution.mark == .couldNot(.tooClose))
        #expect(resolution.encounter == nil, "an unknown entry was written down anyway")
    }

    /// Decision D8: the selector never runs over an auxiliary dictionary's senses.
    @Test func onlyThePrimarysSensesAreOffered() async throws {
        let noad = Self.entry(
            "NOAD", identifier: "n", entryID: "m1",
            senses: [Self.sense(1, "m1.005"), Self.sense(2, "m1.009")])
        let other = Self.entry("Other", identifier: "o", entryID: "o1", senses: [Self.sense(1, "o1.005")])
        // The selector answers with a key from the auxiliary dictionary; it is not honoured.
        let resolution = await resolve([noad, other], .chose(key: "o1.005", margin: 0.5))
        #expect(resolution.mark == nil, "an auxiliary dictionary's sense was marked")
        #expect(resolution.encounter?.entryID == "m1", "the primary's entry was not kept")
        #expect(resolution.encounter?.senseKey == nil)
    }

    /// A key the selector invented belongs to no entry, and nothing is claimed for it.
    @Test func aKeyThatBelongsToNoEntryIsNotHonoured() async {
        let entry = Self.entry(
            "NOAD", identifier: "n", entryID: "e1",
            senses: [Self.sense(1, "e1.001"), Self.sense(2, "e1.002")])
        let resolution = await resolve([entry], .chose(key: "invented", margin: 1))
        #expect(resolution.mark == nil)
        #expect(resolution.encounter?.senseKey == nil)
    }

    @Test func noPrimaryEntriesResolveToNothing() async {
        #expect(await resolve([], .abstained(.noCandidates)) == SenseResolution(mark: nil, encounter: nil))
    }
}
