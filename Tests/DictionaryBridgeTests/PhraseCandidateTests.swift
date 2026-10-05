@testable import DictionaryBridge
import AppleDictionaryFormat
import DictionaryModel
import Foundation
import PhraseLookup
import Synchronization
@testable import XiaolaiDictCore
import Testing

/// **Stage C's gate: what a phrase does to the sense ladder's honesty.**
///
/// Adding a phrase's senses to the candidate set can only move the confidently-wrong rate, and that rate
/// is the number the whole ladder's order was decided on. `dev-docs/wiring-phrase-lookup.md` says this
/// stage is gated on a measurement rather than an opinion, so here is the measurement — before the
/// enlargement is shipped, not after.
///
/// This suite needs NOAD enabled, like every other in this target.
struct PhraseCandidateTests {
    /// The inventory, read once for the whole suite: about a second per dictionary, and every test here
    /// wants the same one.
    static let inventory: PhraseReader = {
        let reader = PhraseReader.forReader("zh-Hans")
        reader.read()
        return reader
    }()

    /// **First question, and it decides whether any of the rest means anything.** If no labelled sentence
    /// holds a phrase, the candidate set never grows on this set and a "no change" result would be evidence
    /// of nothing at all — the trap of a measurement that cannot move.
    @Test func whichLabelledSentencesHoldAPhrase() throws {
        var found: [(String, String, PhraseSeparation)] = []
        for labelled in SenseSelectionAccuracyTests.hardCases + LabelledSenses.inflectedCases {
            let sentence = labelled.sentence
            let words = Lemmatizer.lemmas(in: sentence)
            guard let at = words.firstIndex(where: {
                $0.lemma.text.compare(labelled.word, options: .caseInsensitive) == .orderedSame
            }) else {
                print("PhraseCandidateTests: \(labelled.word) is not in its own sentence in lemma form")
                continue
            }
            if let span = Self.inventory.phrase(in: sentence, at: words[at].range) {
                found.append((labelled.word, span.phrase, span.separation))
            }
        }
        print("PhraseCandidateTests: \(found.count) labelled sentences hold a phrase")
        for (word, phrase, separation) in found {
            print("  \(word) → \(phrase)  \(separation)")
        }
    }
}

extension PhraseCandidateTests {
    /// NOAD's senses for one string, as the primary dictionary would offer them.
    static func candidates(for term: String) throws -> [SenseCandidate] {
        let entries = try DictionaryBridge.entries(for: term).entries
            .filter { $0.dictionary.identifier == DictionaryIdentity.noad }
        return entries.flatMap { entry in
            entry.blocks.flatMap { block in
                block.senses.map {
                    SenseCandidate(
                        entryID: entry.entryID ?? "", key: $0.key ?? "", keyKind: $0.keyKind,
                        text: $0.text, partOfSpeech: block.partOfSpeech)
                }
            }
        }
    }

    static func noad(_ term: String) throws -> [DictionaryEntry] {
        try DictionaryBridge.entries(for: term).entries
            .filter { $0.dictionary.identifier == DictionaryIdentity.noad }
    }

    /// **The distinction Stage C rests on, against the live dictionaries.**
    ///
    /// A phrase with an entry of its own contributes its meaning; a phrase filed as a sub-entry is answered
    /// with its parent, so its senses are the parent's and contribute nothing but noise. Named individually
    /// because the whole design turns on which is which, and a content update moving one from one column to
    /// the other must be a finding rather than a silent change of behaviour.
    @Test func everyPhraseIsClassifiedByWhoseEntryAnsweredIt() throws {
        /// Whether the phrase is expected to have an entry of its own.
        let expected: [(phrase: String, hovered: String, ownEntry: Bool)] = [
            ("purple passage", "passage", true),
            ("red herring", "herring", true),
            ("once in a blue moon", "moon", true),
            ("take something into account", "take", false),
            ("kick the bucket", "kick", false),
            ("keep a tight rein on", "keep", false),
            ("give up the ghost", "give", false),
        ]
        for (phrase, hovered, ownEntry) in expected {
            let answered = try Self.noad(phrase)
            let span = PhraseSpan(phrase: phrase, location: 0, length: 1, separation: .none,
                                  filings: Self.inventory.filings(of: phrase))
            let meaning = DictionaryBridge.meaning(
                of: span, answered: answered, term: try Self.noad(hovered))
            if ownEntry {
                #expect(!meaning.ownEntries.isEmpty, "\(phrase) was expected to have an entry of its own")
                print("PC \(phrase) — its own entry, \(meaning.ownEntries.count) of \(answered.count)")
            } else {
                #expect(meaning.ownEntries.isEmpty, "\(phrase) was expected to be a sub-entry")
                // **The point of the whole rework**: a sub-entry phrase is explained, not deferred. The
                // definition comes from the body walk, because the entry the framework answered with is
                // another word's and its senses are not this phrase's.
                let definition = meaning.filings.compactMap(\.definition).first ?? ""
                #expect(!definition.isEmpty, "\(phrase) reached the wire with no meaning")
                print("PC \(phrase) — sub-entry: \(definition.prefix(60))")
            }
        }
    }

    /// **The gate: enlarging the candidate set must not raise `confidently wrong`.**
    ///
    /// Measured on the labelled set with the phrase's own senses added wherever one is detected. The number
    /// this project decided the ladder's order on is `wrong`, and the rule is that it does not rise.
    ///
    /// **And the honest limit, stated rather than buried**: only 1 of the 12 labelled sentences holds a
    /// phrase at all (*rein* → `keep a tight rein on`), and that one is filed under *rein* — the word the
    /// reader hovered — so it contributes nothing. The labelled set was written for "which sense of this
    /// word" and provably cannot move on this change. This test records that it does not move and why;
    /// measuring the enlargement properly needs labelled **phrase** cases, which is a labelling job and not
    /// something a passing test here should be read as having done.
    @Test func enlargingTheCandidateSetDoesNotRaiseTheConfidentlyWrongRate() async throws {
        let selector = EmbeddingSenseSelector(matchesPartOfSpeech: false)
        var wrongAlone = 0, wrongBoth = 0, moved = 0, withAPhrase = 0
        for labelled in SenseSelectionAccuracyTests.hardCases {
            let word = try Self.candidates(for: labelled.word)
            let words = Lemmatizer.lemmas(in: labelled.sentence)
            let at = words.firstIndex {
                $0.lemma.text.compare(labelled.word, options: .caseInsensitive) == .orderedSame
            }
            let span = at.flatMap { Self.inventory.phrase(in: labelled.sentence, at: words[$0].range) }
            // Exactly what the runner hands the resolver: an own entry's senses, and nothing for a sub-entry.
            var phrase: [SenseCandidate] = []
            if let span {
                withAPhrase += 1
                let answered = try Self.noad(span.phrase)
                if !DictionaryBridge.meaning(
                    of: span, answered: answered, term: try Self.noad(labelled.word))
                    .ownEntries.isEmpty {
                    phrase = try Self.candidates(for: span.phrase)
                }
            }
            let partOfSpeech = Lemmatizer.partOfSpeech(of: labelled.word, in: labelled.sentence, at: nil)
            func choose(_ set: [SenseCandidate]) async -> SenseSelection {
                await selector.choose(from: set, reading: labelled.sentence,
                                     context: .complete, partOfSpeech: partOfSpeech)
            }
            let alone = await choose(word), both = await choose(word + phrase)
            if LabelledSenses.bucket(alone, correct: labelled.correct) == .wrong { wrongAlone += 1 }
            if LabelledSenses.bucket(both, correct: labelled.correct) == .wrong { wrongBoth += 1 }
            if alone.key != both.key { moved += 1 }
        }
        print("""
            PC \(withAPhrase) of \(SenseSelectionAccuracyTests.hardCases.count) labelled sentences hold a \
            phrase; \(moved) answers moved; confidently wrong \(wrongAlone) → \(wrongBoth)
            """)
        #expect(wrongBoth <= wrongAlone, "the enlargement raised the confidently-wrong rate")
        #expect(withAPhrase <= 1, """
            more labelled sentences hold a phrase than when this was measured — the set can now say \
            something about the enlargement, so score it properly rather than trusting this floor
            """)
    }
}

/// **A phrase can be an entry in one dictionary and a filing in another, and the reply must carry both.**
///
/// Synthetic on purpose: it asserts the partition itself, with no dependence on which dictionaries this Mac
/// has or on two of them disagreeing about one phrase today. The words are nonsense so the bridge's lookup
/// of the phrase's own words finds nothing and cannot accidentally supply the parent.
struct PhrasePartitionTests {
    private static func entry(_ id: String, headword: String, in dictionary: String = "test") -> DictionaryEntry {
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="\(id)" \
            d:title="\(headword)"><span class="hg x_xh0"><span class="hw">\(headword)</span></span>\
            <span id="\(id).001" class="se1 x_xd0"><span id="\(id).002" class="se2 x_xd1 hasSn">\
            <span d:def="1" class="df">a meaning</span></span></span></d:entry>
            """
        return DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Test", identifier: dictionary, version: "1"),
            headword: headword, lookedUp: headword, html: markup,
            document: EntryDocument.parse(markup))
    }

    private static func filing(parent: String, _ definition: String) -> PhraseFiling {
        PhraseFiling(dictionary: DictionaryIdentity(name: "Test", identifier: "test"),
                     parentEntryID: parent, blockID: "\(parent).01", definitions: [definition],
                     contentVersion: "v1", formatVersion: "phrases/6")
    }

    /// The defect this replaced: one matching parent id made the **whole** answer a sub-entry, so the
    /// dictionary that gave the phrase an entry of its own lost every sense it had.
    @Test func anOwnEntrySurvivesAnotherDictionarysParent() {
        let own = Self.entry("own1", headword: "zzqq wwvv")
        let parent = Self.entry("par1", headword: "wwvv")
        let span = PhraseSpan(phrase: "zzqq wwvv", location: 0, length: 9, separation: .none,
                              filings: [Self.filing(parent: "par1", "what the filing says")])
        let meaning = DictionaryBridge.meaning(of: span, answered: [own, parent],
                                               term: [Self.entry("par1", headword: "wwvv")])
        #expect(meaning.ownEntries.map(\.entryID) == ["own1"],
                "the parent is not a candidate and the own entry must not go with it")
        #expect(meaning.filings.count == 1, "and the filing is carried beside it, not instead of it")
    }

    /// **An entry id is a dictionary's, not the world's.** Two dictionaries can use the same `d:entry`
    /// id for different entries; the parent found in one must not make the other's own entry a
    /// sub-entry. Red if the partition compares raw ids — `AGENTS.md`: never key by the raw id.
    @Test func aCollidingIDInAnotherDictionaryIsNotAParent() {
        let parentHere = Self.entry("e1", headword: "wwvv", in: "test")
        let ownThere = Self.entry("e1", headword: "zzqq wwvv", in: "other")
        let span = PhraseSpan(phrase: "zzqq wwvv", location: 0, length: 9, separation: .none,
                              filings: [Self.filing(parent: "e1", "what the filing says")])
        let meaning = DictionaryBridge.meaning(of: span, answered: [parentHere, ownThere], term: [parentHere])
        #expect(meaning.ownEntries.map(\.dictionary.identifier) == ["other"],
                "another dictionary's own entry was taken for a sub-entry because its id collided")
    }

    /// With no own entry among them, nothing reaches the ladder — the parent's senses are that word's.
    @Test func aparentAloneOffersNoCandidates() {
        let parent = Self.entry("par1", headword: "wwvv")
        let span = PhraseSpan(phrase: "zzqq wwvv", location: 0, length: 9, separation: .none,
                              filings: [Self.filing(parent: "par1", "what the filing says")])
        let meaning = DictionaryBridge.meaning(of: span, answered: [parent], term: [parent])
        #expect(meaning.ownEntries.isEmpty)
        #expect(meaning.filings.first?.definition == "what the filing says")
    }

    /// **The filing whose parent actually answered is drawn first.** `blow a fuse` is filed under *blow*
    /// and under *fuse* with different meanings; before the locators were kept, the body walk's order chose
    /// between them, which is nobody's intent.
    @Test func thefilingWhoseParentAnsweredComesFirst() {
        let parent = Self.entry("fuse", headword: "fuse")
        let span = PhraseSpan(phrase: "zzqq wwvv", location: 0, length: 9, separation: .none,
                              filings: [Self.filing(parent: "blow", "lose one's temper"),
                                        Self.filing(parent: "fuse", "use too much power")])
        let meaning = DictionaryBridge.meaning(of: span, answered: [parent], term: [parent])
        #expect(meaning.filings.map(\.parentEntryID) == ["fuse", "blow"])
        #expect(meaning.filings.count == 2, "and the other one is kept, not dropped")
    }
}
