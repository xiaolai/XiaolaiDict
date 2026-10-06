@testable import DictionaryModel
import Foundation
import Testing

/// **The lemmatiser with the dictionary's inflection list in force.** Every word the table is asked about
/// here is invented, so the tagger certainly knows none of them and nothing depends on what `NLTagger`
/// says on this macOS; the table is the only thing that can have produced the lemma.
struct LemmatizerFormTableTests {
    typealias Reading = FormTable.Reading

    static let table = FormTable(sources: ["fixture"], forms: [
        "zorbled": [Reading(lemma: "zorble", partOfSpeech: "verb")],
        "zorbling": [Reading(lemma: "zorble", partOfSpeech: "verb")],
        "glimmeries": [Reading(lemma: "glimmery", partOfSpeech: "noun")],
        "found": [Reading(lemma: "find", partOfSpeech: "verb")],
    ], ownHeadwords: ["found"])

    private func lemma(_ word: String, _ sentence: String?, using table: FormTable? = Self.table) -> Lemma {
        Lemmatizer.lemma(of: word, in: sentence, at: nil, using: table)
    }

    @Test func aGapTheTaggerLeavesIsFilledFromTheDictionaryAndSaysSo() {
        let found = lemma("zorbled", "She zorbled the thing.")
        #expect(found == Lemma(text: "zorble", basis: .inferred))
    }

    @Test func withoutATableTheTaggerAnswersAlone() {
        let found = lemma("zorbled", "She zorbled the thing.", using: nil)
        #expect(found.basis != .inferred)
    }

    @Test func theSentenceIsNotNeeded() {
        #expect(lemma("zorbling", nil).text == "zorble")
    }

    /// **The invariant the own-headword flag exists for.** `found` is listed under *find*, and *they will
    /// found a company* must not be filed there: the grammar around it decides, as it did before the table.
    @Test(arguments: [("They will found a company.", "found"), ("He had found it.", "find")])
    func aFormThatIsAlsoAHeadwordIsLeftToTheGrammar(sentence: String, expected: String) {
        #expect(lemma("found", sentence).text == expected)
        #expect(lemma("found", sentence).text == lemma("found", sentence, using: nil).text,
                "the table changed a lemma it was never to decide")
    }

    /// **The regular form Oxford does not print**, found through the word list; a name is not one.
    @Test func aRegularFormOfAListedWordIsDetachedAndAMidSentenceCapitalIsAName() {
        let words = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["zorble"])
        #expect(lemma("zorbles", "She zorbles the thing.", using: words) == Lemma(text: "zorble", basis: .inferred))
        #expect(lemma("Zorbles", "We met Zorbles at noon.", using: words).text == "zorbles")
        #expect(lemma("Zorbles", "Zorbles are here.", using: words).text == "zorbles", "a capital on the first word is a name too — the cheaper error")
        #expect(lemma("zorBles", "We met zorBles at noon.", using: words).text == "zorbles", "a capital inside is a brand")
    }

    @Test func aPhraseTakesTheTablesLemmaWordByWord() {
        #expect(lemma("zorbled up", "She zorbled up the thing.").text == "zorble up")
    }

    @Test func everyEntryPointReadsTheSameTable() {
        let sentence = "She zorbled the thing."
        #expect(Lemmatizer.lemmas(in: sentence, using: Self.table).map(\.lemma.text).contains("zorble"))
        #expect(Lemmatizer.forms(in: sentence, using: Self.table).first { $0.written == "zorbled" }?.candidates
                == ["zorbled", "zorble"])
        #expect(!Lemmatizer.forms(in: sentence, using: nil).contains { $0.candidates.contains("zorble") })
    }

    @Test func theDefaultIsTheProcessWideAuthority() {
        #expect(Lemmatizer.lemma(of: "running", in: "She was running late.")
                == Lemmatizer.lemma(of: "running", in: "She was running late.", at: nil, using: FormAuthority.shared.table))
    }

    /// **The hand corrections stay above the table.** They were measured one form at a time, and `broke` must
    /// still come back `break` whatever a table says about it.
    @Test func aHandCorrectionOutranksTheTable() {
        let hostile = FormTable(sources: [], forms: ["broke": [Reading(lemma: "brook", partOfSpeech: "verb")]], ownHeadwords: [])
        #expect(Lemmatizer.lemma(of: "broke", in: "He broke the glass.", at: nil, using: hostile).text == "break")
    }
}

/// **The phrase whose later words inflect** — *prepare mind* read as "prepared minds" — which marked
/// `prepared` and left `minds`.
struct PhrasePartsTests {
    private func marked(_ lemma: String, _ surface: String, in sentence: String) -> [String] {
        let anchor = (sentence as NSString).range(of: surface)
        return Lemmatizer.parts(of: lemma, surface: surface, in: sentence, at: anchor).map {
            (sentence as NSString).substring(with: $0)
        }
    }

    @Test func aLaterWordThatInflectsIsMarkedThroughItsLemma() {
        #expect(marked("prepare mind", "prepared", in: "Fortune favours the prepared minds of the world.") == ["prepared", "minds"])
    }

    @Test func aLaterWordThatMatchesAsWrittenStillNeedsNoLemma() {
        #expect(marked("take over", "took", in: "He took the whole thing over.") == ["took", "over"])
    }

    @Test func aWordPastTheLookaheadIsAnotherWord() {
        #expect(marked("prepare mind", "prepared", in: "She prepared the soup for her friends and relatives, minds elsewhere.") == ["prepared"])
    }

    @Test func aDifferentWordWithADifferentLemmaIsNotMarked() {
        #expect(marked("prepare mind", "prepared", in: "Fortune favours the prepared mines.") == ["prepared"])
    }

    /// **Every word of the phrase, whichever way it was found.**
    @Test func aThreeWordLemmaWithTwoInflectedWordsIsMarkedWhole() {
        #expect(marked("take step forward", "took", in: "She took steps forward.") == ["took", "steps", "forward"])
    }
}

/// **The tagger word that is the token, and no other.** A wider one holds the lemma of something else.
struct DictionaryFormAlignmentTests {
    private func word(_ lemma: String, _ location: Int, _ length: Int) -> LemmatizedWord {
        LemmatizedWord(lemma: Lemma(text: lemma, basis: .tagger), range: NSRange(location: location, length: length))
    }

    @Test func onlyAnEqualRangeAnswersForTheToken() {
        let sentence = "a well-known fact"
        let known = sentence.range(of: "known")!
        // The tagger merged `well-known`: its range covers the token and more.
        let merged = [word("a", 0, 1), word("well-known", 2, 10), word("fact", 13, 4)]
        #expect(Lemmatizer.dictionaryForm(of: known, among: merged, in: sentence) == nil)
        let split = [word("a", 0, 1), word("well", 2, 4), word("know", 7, 5), word("fact", 13, 4)]
        #expect(Lemmatizer.dictionaryForm(of: known, among: split, in: sentence) == "know")
        #expect(Lemmatizer.dictionaryForm(of: sentence.range(of: "fact")!, among: split, in: sentence) == "fact")
        #expect(Lemmatizer.dictionaryForm(of: known, among: [], in: sentence) == nil)
    }
}
