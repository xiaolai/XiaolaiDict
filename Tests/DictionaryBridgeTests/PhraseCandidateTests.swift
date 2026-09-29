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
                                  definition: Self.inventory.meaning(of: phrase))
            let meaning = DictionaryBridge.meaning(
                of: span, answered: answered, term: try Self.noad(hovered))
            switch meaning {
            case .ownEntry:
                #expect(ownEntry, "\(phrase) was expected to be a sub-entry")
                print("PC \(phrase) — its own entry, \(answered.count) entries")
            case .subEntry(let definition):
                #expect(!ownEntry, "\(phrase) was expected to have an entry of its own")
                // **The point of the whole rework**: a sub-entry phrase is explained, not deferred. The
                // definition comes from the body walk, because the entry the framework answered with is
                // another word's and its senses are not this phrase's.
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
                if case .ownEntry = DictionaryBridge.meaning(
                    of: span, answered: answered, term: try Self.noad(labelled.word)) {
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
