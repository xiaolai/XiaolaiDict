import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The matcher, on invented senses where the right answer is known by construction.
///
/// Every case below is a defect the real run produced first. The aggregate moved by two or three points each
/// time while the pairs for a polysemous word went from all wrong to all right, which is why these are
/// written as named cases rather than as a coverage figure.
@Suite struct SenseAlignerTests {
    /// A weighting in which every term is equally rare, so a test is about the rule under test and not about
    /// the corpus.
    static func flat(_ terms: [String]) -> SenseAligner.Weighting {
        SenseAligner.Weighting(documents: terms.map { [$0] })
    }

    static func aligner(_ documents: [Set<String>]) -> SenseAligner {
        SenseAligner(weighting: SenseAligner.Weighting(documents: documents))
    }

    static func candidate(_ key: String, _ pos: String?, _ words: String) -> SenseAligner.Candidate {
        SenseAligner.Candidate(senseKey: key, partOfSpeech: pos, terms: SenseAligner.terms(words))
    }

    /// One candidate sharing distinctive vocabulary wins.
    @Test func aCandidateThatSharesDistinctiveWordsIsChosen() {
        // A corpus in which each word is rare, so any single shared word clears the score floor.
        let corpus = (0 ..< 400).map { Set(["filler\($0)"]) }
        let aligner = Self.aligner(corpus + [["penalty", "court"], ["weather", "bright"]])
        let verdict = aligner.match(
            spoke: SenseAligner.terms("a heavy penalty imposed by the court"),
            partOfSpeech: "noun",
            against: [Self.candidate("k1", "noun", "a sum of money exacted as a penalty by a court of law"),
                      Self.candidate("k2", "adjective", "of the weather bright and clear")])
        guard case .matched(let key, let confidence, let sharedTerms) = verdict else {
            Issue.record("expected a match, got \(verdict)"); return
        }
        #expect(key == "k1")
        #expect(confidence > 0.5)
        #expect(sharedTerms == 2, "`penalty` and `court` are what it rests on")
    }

    /// **Two candidates within the margin are refused, not resolved by a hair.**
    @Test func twoCandidatesTooCloseTogetherAreRefused() {
        let corpus = (0 ..< 400).map { Set(["filler\($0)"]) }
        let aligner = Self.aligner(corpus)
        // Each candidate shares a *different* distinctive word, so the two scores are equal and neither is
        // evidence over the other. A first attempt at this fixture had both candidates share the same word,
        // which the within-entry weighting correctly reduces to nothing — the refusal was then
        // `nothingShared`, which is the right answer to a different question.
        // Two distinct shared words each, so each score clears the floor on its own and the two are equal.
        // One word each does not: the within-entry factor for a term in one of two candidates is log(3/2),
        // and a single term cannot reach `requiredScore` through it.
        let verdict = aligner.match(
            spoke: SenseAligner.terms("embankment reservoir culvert aqueduct"), partOfSpeech: nil,
            against: [Self.candidate("k1", nil, "a steep embankment above the culvert"),
                      Self.candidate("k2", nil, "a deep reservoir behind the aqueduct")])
        guard case .tooClose(let contenders) = verdict else {
            Issue.record("expected a refusal, got \(verdict)"); return
        }
        #expect(contenders >= 2)
    }

    /// **A margin alone is not evidence.** Where only one candidate shares anything, the runner-up is zero
    /// and the margin infinite — three senses of 牛津英汉汉英's `hold` were claimed that way, on one common
    /// verb form, and all three were wrong.
    @Test func aSingleCommonWordIsNotAMatch() {
        // A corpus where `thing` is in almost every document, so its weight is near zero.
        let common = (0 ..< 300).map { Set(["thing", "other\($0)"]) }
        let aligner = Self.aligner(common)
        let verdict = aligner.match(
            spoke: SenseAligner.terms("some thing"), partOfSpeech: nil,
            against: [Self.candidate("k1", nil, "a thing of one kind"),
                      Self.candidate("k2", nil, "quite unrelated words here")])
        #expect(verdict == .nothingShared, "a near-worthless shared word was treated as a finding")
    }

    /// **A term most candidates share cannot choose between them.** This is what catches a headword's
    /// inflection when the exclusion list misses it: `held` was rare across the dictionary and common inside
    /// the entry.
    @Test func aTermCommonToEveryCandidateDoesNotDecide() {
        let corpus = (0 ..< 400).map { Set(["filler\($0)"]) }
        let aligner = Self.aligner(corpus)
        // `held` is in every candidate; only `meeting` distinguishes one.
        let verdict = aligner.match(
            spoke: SenseAligner.terms("held the rope"), partOfSpeech: nil,
            against: [Self.candidate("k1", nil, "a meeting was held"),
                      Self.candidate("k2", nil, "she held the door"),
                      Self.candidate("k3", nil, "he held his breath")])
        // Nothing but the shared-by-all term matches, so there is nothing to choose on.
        #expect(verdict == .nothingShared || verdict == .tooClose(contenders: 3),
                "a term every candidate shares decided the match: \(verdict)")
    }

    /// A sense with no text this method can read is reported as such, not as a failure to match.
    ///
    /// The distinction is most of the story for a bilingual: 54,243 of 牛津英汉汉英's senses print no example,
    /// and calling those "shared nothing" blamed the matcher for senses it was given nothing to work with.
    @Test func aSenseWithNoMaterialIsReportedSeparately() {
        let aligner = Self.aligner([["anything"]])
        #expect(aligner.match(spoke: [], partOfSpeech: "noun",
                              against: [Self.candidate("k1", "noun", "a sum of money")]) == .noMaterial)
    }

    /// The part-of-speech filter runs before anything else, and only where both sides declare one.
    @Test func partOfSpeechFiltersCandidatesAndAbsenceDoesNot() {
        let corpus = (0 ..< 400).map { Set(["filler\($0)"]) }
        let aligner = Self.aligner(corpus)
        // The only vocabulary match is a verb; the spoke sense is a noun.
        let verdict = aligner.match(
            spoke: SenseAligner.terms("penalty court money"), partOfSpeech: "noun",
            against: [Self.candidate("k1", "verb", "to impose a penalty in court for money")])
        #expect(verdict == .noCandidate, "a verb was offered to a noun: \(verdict)")

        // With no part of speech on the candidate, it is eligible — 27 of 84 dictionaries mark none, and
        // treating absence as a mismatch would reject every pair in them.
        let unlabelled = aligner.match(
            spoke: SenseAligner.terms("penalty court money"), partOfSpeech: "noun",
            against: [Self.candidate("k1", nil, "to impose a penalty in court for money")])
        guard case .matched = unlabelled else {
            Issue.record("an unlabelled candidate was rejected: \(unlabelled)"); return
        }
    }

    /// `transitive verb` and `verb` are the same part of speech. 牛津英汉汉英 writes the first where NOAD
    /// writes the second, so comparing the strings rejects a pair that agrees.
    @Test func partOfSpeechFamiliesAreCompared() {
        #expect(SenseAligner.family(of: "transitive verb") == "verb")
        #expect(SenseAligner.family(of: "intransitive verb") == "verb")
        #expect(SenseAligner.family(of: "noun") == "noun")
        #expect(SenseAligner.family(of: "plural noun") == "noun")
        #expect(SenseAligner.family(of: nil) == nil)
        #expect(SenseAligner.family(of: "particle") == nil, "an unknown label is not forced into a family")
    }

    /// The headword and its inflections are removed from the matchable text, because they are the one thing
    /// guaranteed to be shared and say nothing about which sense is meant.
    @Test func theWordAnEntryIsAboutIsNotMatchableText() {
        let terms = SenseAligner.terms("she held the rope and would hold it again",
                                       about: ["hold", "held", "holding", "holds"])
        #expect(!terms.contains("held"))
        #expect(!terms.contains("hold"))
        #expect(terms.contains("rope"))
    }

    /// Short words and the few structural ones are not content. `sb` and `sth` are how a bilingual writes
    /// its placeholders, and they appear in almost every example it prints.
    @Test func placeholdersAndShortWordsAreNotTerms() {
        let terms = SenseAligner.terms("to hold sb by the sleeve and give sth to us")
        #expect(!terms.contains("sb"))
        #expect(!terms.contains("sth"))
        #expect(!terms.contains("to"))
        #expect(terms.contains("sleeve"))
    }

    /// **And in the other dictionary's spelling of the same placeholder.** NOAD writes `someone` and `one's`
    /// where 牛津英汉汉英 writes `sb`; ignoring only the abbreviations left "empty (one's bowels)" paired with
    /// 移动 *to move*, on `bowels` and `one's` — two shared terms, which is what the term floor asks for.
    @Test func theEnglishSpellingsOfThePlaceholdersAreNotTermsEither() {
        let terms = SenseAligner.terms("empty (one's bowels) for someone or something of one's own")
        #expect(terms == ["empty", "bowels"], "got \(terms.sorted())")
    }

    /// A possessive is the same word wearing a marker, and a contraction is not two words.
    @Test func aTrailingPossessiveIsNotADifferentWord() {
        #expect(SenseAligner.terms("the reader's copy") == ["reader", "copy"])
        #expect(SenseAligner.terms("she doesn't mind") == ["doesn't", "mind"])
    }

    /// **One shared word is a collocation, not a meaning — however rare the word is.**
    ///
    /// The score floor does not catch this on its own: a term rare enough carries the whole floor by itself.
    /// Two of four wrong pairs in a 30-pair sample were this shape — 礼堂 "a school hall" took NOAD's "the
    /// room used for meals in a college, university, or *school*" over "a large room for meetings", on
    /// `school` alone.
    @Test func onePairOfSharedWordsIsRequiredHoweverRareTheWordIs() {
        // 20,000 documents, one containing `school`: weight log(20000/2) = 9.2, and the within-entry factor
        // for a term in one of two candidates is log(3/2) = 0.405. 9.2 × 0.405 = 3.7, which clears the 3.0
        // score floor — so the rejection below is the term rule and nothing else.
        let corpus = (0 ..< 19_999).map { Set(["filler\($0)"]) } + [["school"]]
        let aligner = Self.aligner(corpus)
        let onlyOne = aligner.match(
            spoke: SenseAligner.terms("a school hall"), partOfSpeech: "noun",
            against: [Self.candidate("meals", "noun", "the room used for meals in a school"),
                      Self.candidate("meetings", "noun", "a large room for concerts")])
        #expect(onlyOne == .nothingShared, "a single shared word decided a pair: \(onlyOne)")

        // Two distinct words, each in one candidate, and the count is reported so a caller can see what a
        // pair rests on.
        let two = aligner.match(
            spoke: SenseAligner.terms("a hall for meetings and concerts"), partOfSpeech: "noun",
            against: [Self.candidate("meals", "noun", "the room used for meals in a school"),
                      Self.candidate("meetings", "noun", "a large room for meetings or concerts")])
        guard case .matched(let key, _, let sharedTerms) = two else {
            Issue.record("expected a match, got \(two)"); return
        }
        #expect(key == "meetings")
        #expect(sharedTerms == 2)
    }
}
