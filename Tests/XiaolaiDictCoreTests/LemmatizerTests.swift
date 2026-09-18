import Foundation
@testable import XiaolaiDictCore
import Testing

/// Lemmas are what collapse running / ran / runs into one ledger row (design note §9).
struct LemmatizerTests {
    private func lemma(_ word: String, _ sentence: String?, at range: NSRange? = nil) -> String {
        Lemmatizer.lemma(of: word, in: sentence, at: range).text
    }

    @Test(arguments: [
        ("running", "She was running late."),
        ("ran", "He ran all the way home."),
        ("runs", "The river runs dry in August."),
    ])
    func inflectionsOfAVerbShareALemma(word: String, sentence: String) {
        #expect(lemma(word, sentence) == "run")
    }

    @Test func anIrregularPluralFindsItsSingular() {
        #expect(lemma("mice", "The mice ran away.") == "mouse")
    }

    @Test func capitalisationIsNotPartOfTheLemma() {
        #expect(lemma("Ephemeral", "Ephemeral things fade.") == "ephemeral")
    }

    /// Without context the word is still lemmatized on its own.
    @Test func noContextStillLemmatizes() {
        #expect(lemma("running", nil) == "run")
    }

    /// A word the tagger has no lemma for is its own lemma, lowercased — never dropped — and says so.
    @Test func anUnknownWordIsItsOwnLemma() {
        #expect(Lemmatizer.lemma(of: "Qzxqzx", in: "The Qzxqzx appeared.") == Lemma(text: "qzxqzx", basis: .surface))
    }

    @Test func aTaggedLemmaSaysItCameFromTheTagger() {
        #expect(Lemmatizer.lemma(of: "running", in: "She was running late.").basis == .tagger)
    }

    @Test func chineseWordsAreTheirOwnLemma() {
        #expect(lemma("学习", "我们今天学习英语语法。") == "学习")
    }

    /// The sentence decides between readings: "leaves" is "leaf" as a noun and "leave" as a verb,
    /// and the bare word reads as the verb. A lemmatizer that ignored the sentence would get the
    /// noun wrong.
    @Test(arguments: [
        ("leaves", "The leaves turned red.", "leaf"),
        ("leaves", "She leaves at noon.", "leave"),
        ("meeting", "The meeting ran late.", "meeting"),
        ("meeting", "We are meeting at noon.", "meet"),
    ])
    func theSentenceDecidesBetweenReadings(word: String, sentence: String, lemma expected: String) {
        #expect(lemma(word, sentence) == expected)
    }

    @Test(arguments: [("went", "We went out.", "go"), ("thought", "I thought so.", "think"),
                      ("wrote", "She wrote a letter.", "write"), ("sought", "They sought refuge.", "seek")])
    func irregularPastFormsFindTheirVerb(word: String, sentence: String, lemma expected: String) {
        #expect(lemma(word, sentence) == expected)
    }

    /// A selected phrase is lemmatized word by word, so the forms of a phrasal verb meet in one
    /// ledger entry. Found live: "prepared mind" came back as "prepare", its first word alone.
    @Test(arguments: [
        ("gave up", "He gave up smoking last year.", "give up"),
        ("giving up", "She is giving up sugar.", "give up"),
        ("looked up", "I looked up the word.", "look up"),
        ("prepared mind", "Serendipity favours the prepared mind.", "prepare mind"),
    ])
    func aPhraseIsLemmatizedWordByWord(phrase: String, sentence: String, lemma expected: String) {
        #expect(lemma(phrase, sentence) == expected)
    }

    @Test func aPhraseMissingFromItsSentenceIsStillLemmatized() {
        #expect(lemma("gave up", "An unrelated sentence.") == "give up")
    }

    // MARK: - Placing the word

    /// Found by audit: a case-insensitive search found "he" inside "When", the tagger answered for
    /// the whole of "When", and slicing by that range trapped — a crash in the app, on a pronoun.
    @Test(arguments: [
        ("he", "When he left, it rained.", "he"),
        ("run", "Stop running before the run.", "run"),
        ("art", "Start the art class.", "art"),
    ])
    func aWordInsideALongerWordIsNotMistakenForIt(word: String, sentence: String, lemma expected: String) {
        #expect(lemma(word, sentence) == expected)
    }

    /// Only the capture knows which of two occurrences was selected. Given its range, the selected
    /// one decides; without it, neither is guessed.
    @Test func theSelectedOccurrenceDecidesNotTheFirst() {
        let sentence = "The meeting ended after we stopped meeting."
        let second = (sentence as NSString).range(of: "meeting", options: .backwards)
        let first = (sentence as NSString).range(of: "meeting")
        #expect(lemma("meeting", sentence, at: second) == "meet")
        #expect(lemma("meeting", sentence, at: first) == "meeting")
        #expect(Lemmatizer.occurrence(of: "meeting", in: sentence, at: nil) == nil, "a repeated word was guessed")
    }

    /// A range that does not hold the word, or cuts through one, is not trusted; nor is one from
    /// another process that overflows.
    @Test(arguments: [
        NSRange(location: 0, length: 3), NSRange(location: 5, length: 2), NSRange(location: NSNotFound, length: 2),
        NSRange(location: 2, length: Int.max), NSRange(location: -4, length: 2),
    ])
    func aRangeThatDoesNotHoldTheWordIsIgnored(range: NSRange) {
        #expect(lemma("he", "When he left.", at: range) == "he")
    }

    // MARK: - One spelling per entry

    /// The ledger groups by the lemma's exact text, so every spelling of the same selection must
    /// come out the same: spacing, a line break, curly quotes, surrounding punctuation.
    @Test(arguments: ["gave up", "gave  up", "gave\nup", "“gave up,”", "(gave up)"])
    func spacingAndSurroundingPunctuationAreNotPartOfTheLemma(phrase: String) {
        #expect(lemma(phrase, nil) == "give up")
    }

    /// Found live in Safari: a selection across a sentence end came back as "here.second".
    /// Punctuation with a space beside it separates words; only punctuation inside a phrase stays.
    @Test func sentencePunctuationBetweenWordsIsASpace() {
        #expect(lemma("here. Second", nil) == "here second")
        #expect(lemma("rock-and-roll", nil) == "rock-and-roll")
    }

    @Test func aCurlyApostropheIsWrittenStraight() {
        #expect(lemma("don’t", nil) == lemma("don't", nil))
    }

    @Test func composedAndDecomposedFormsAreOneLemma() {
        #expect(lemma("cafe\u{301}", nil) == lemma("caf\u{e9}", nil))
    }

    // MARK: - Irregular forms NLTagger leaves unchanged

    /// NLTagger returns saw, found, felt, fell, rose, lay, bore and wound unchanged — even tagged
    /// as verbs (measured on macOS 27, 2026-09-18). The grammar around them decides instead.
    @Test(arguments: [
        ("saw", "I saw the film yesterday.", "see"),
        ("found", "He found the keys.", "find"),
        ("felt", "She felt tired.", "feel"),
        ("fell", "He fell down.", "fall"),
        ("rose", "The sun rose early.", "rise"),
        ("lay", "He lay on the bed.", "lie"),
        ("bore", "She bore the pain.", "bear"),
        ("wound", "He wound the clock.", "wind"),
        ("saw", "She never saw him again.", "see"),
    ])
    func aPastFormIsReadAsThePast(word: String, sentence: String, lemma expected: String) {
        #expect(Lemmatizer.lemma(of: word, in: sentence) == Lemma(text: expected, basis: .inferred))
    }

    /// After a modal, "to" or "do", the form is a base form: its own verb.
    @Test(arguments: [
        ("found", "They will found a company.", "found"),
        ("lay", "Remember to lay the table.", "lay"),
        ("wound", "Words can wound.", "wound"),
    ])
    func aBaseFormKeepsItsOwnVerb(word: String, sentence: String, lemma expected: String) {
        #expect(lemma(word, sentence) == expected)
    }

    @Test(arguments: [
        ("found", "He had found it.", "find"),
        ("felt", "I have felt that.", "feel"),
        ("found", "It was found in the attic.", "find"),
    ])
    func aParticipleFindsItsVerb(word: String, sentence: String, lemma expected: String) {
        #expect(lemma(word, sentence) == expected)
    }

    /// The same words as nouns stay nouns — including where NLTagger tags them as verbs, as it does
    /// "rose" and "felt" in the object phrases here.
    @Test(arguments: [
        ("saw", "The saw is sharp."),
        ("saw", "He cut it with a saw."),
        ("rose", "She gave me a red rose."),
        ("felt", "She wore a felt hat."),
        ("rose", "He picked a rose from the garden."),
        ("wound", "The wound healed."),
        ("wound", "His wound healed."),
    ])
    func aNounStaysItself(word: String, sentence: String) {
        #expect(lemma(word, sentence) == word)
    }

    /// A noun phrase opening a sentence has the shape of a subject and its verb: "A red rose" reads
    /// like "The sun rose", and nothing in the grammar tells them apart. Pinned: the verb reading,
    /// right for the second and wrong for the first.
    @Test func aSentenceOpeningNounPhraseReadsAsSubjectAndVerb() {
        #expect(lemma("rose", "The sun rose early.") == "rise")
        #expect(lemma("rose", "A red rose.") == "rise")
    }

    /// Where the grammar is silent and both readings are common, the word is kept and marked
    /// ambiguous rather than guessed: "they lay" may be lying down or laying bricks.
    @Test func anUnsettledFormIsKeptAndMarkedAmbiguous() {
        #expect(Lemmatizer.lemma(of: "lay", in: "They lay there.") == Lemma(text: "lay", basis: .ambiguous))
    }

    /// The accepted cost of reading "saw" as "see" when the grammar is silent: sawing wood is read
    /// as seeing it. Pinned so the trade is visible, and a better model shows up as a change here.
    @Test func theEverydayReadingWinsWhenTheGrammarIsSilent() {
        #expect(lemma("saw", "They saw wood every day.") == "see")
    }

    /// A phrase is as certain as its least certain word.
    @Test func aPhraseTakesItsLeastCertainBasis() {
        #expect(Lemmatizer.lemma(of: "saw it", in: "I saw it coming.") == Lemma(text: "see it", basis: .inferred))
    }
}
