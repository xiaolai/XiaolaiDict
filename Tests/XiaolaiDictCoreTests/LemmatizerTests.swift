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

/// How a word is being used in the sentence it was read in.
///
/// The same answers whether asked one at a time or in a pass — the pass exists only to reuse the
/// tagger, and a pass that answered differently would be a second implementation wearing the
/// first one's name.
struct LemmatizerPartOfSpeechTests {
    private let pass = Lemmatizer.Pass()

    private func tag(_ word: String, in sentence: String) -> String? {
        let one = Lemmatizer.partOfSpeech(of: word, in: sentence, at: nil)
        let batched = pass.partOfSpeech(of: word, in: sentence, at: nil)
        #expect(one == batched, "the pass and the one-shot disagree about \(word)")
        return batched
    }

    /// The reason to tag the *sentence* rather than the word: "tempered" alone could be an
    /// adjective, and only *Justice tempered with mercy* settles it.
    @Test func theSentenceSettlesWhatTheWordIsDoing() {
        #expect(tag("tempered", in: "Justice tempered with mercy.") == "verb")
        #expect(tag("hold", in: "The ship's hold was full.") == "noun")
        #expect(tag("hold", in: "Hold the line.") == "verb")
    }

    /// An older row's context is the selection itself, so there is no sentence to read. The word
    /// on its own is less evidence and still an answer.
    @Test func aWordWithNoSentenceIsStillTagged() {
        #expect(tag("running", in: "running") != nil)
    }

    /// Only the four classes a dictionary blocks its senses by, in the dictionaries' own words so
    /// they compare against `d:pos` without a mapping table. Everything else is nil: "determiner"
    /// on a card would be noise, and a guessed part of speech rules out the right sense as
    /// confidently as the wrong ones.
    @Test func onlyTheClassesADictionaryUsesComeBack() {
        #expect(tag("the", in: "the ship was full") == nil)
        #expect(tag("7", in: "there were 7 of them") == nil)
        #expect(Lemmatizer.partOfSpeech(of: "", in: "a sentence", at: nil) == nil)
        #expect(Lemmatizer.partOfSpeech(of: "   ", in: "a sentence", at: nil) == nil)
    }

    /// The word as it was on screen is capitalised at the start of a sentence, and the stored
    /// surface keeps that. It must still find itself.
    @Test func capitalisationDoesNotHideTheWordFromTheTagger() {
        #expect(tag("Justice", in: "Justice tempered with mercy.") == "noun")
        #expect(tag("justice", in: "Justice tempered with mercy.") == "noun")
    }

    /// One pass covers a whole drawer's worth of cards, so it has to keep answering.
    @Test func onePassAnswersForEveryCardInTheDrawer() {
        for _ in 0..<5 {
            #expect(pass.partOfSpeech(of: "hold", in: "The ship's hold was full.", at: nil) == "noun")
        }
    }
}

/// Which parts of a sentence are the looked-up term.
///
/// Against `Lemmatizer.parts` directly rather than through a `ReadingEntry`: this is string work,
/// and building a whole ledger row with an id, a place and a capture quality to test it would say
/// the test was about a card when it is about a phrase.
struct LemmaPartsTests {
    /// `anchor` is what the capture found on screen; `lemma` is the dictionary form, which for a
    /// phrasal verb is the whole phrase even when only part of it was under the pointer.
    private func marked(_ anchor: String, in sentence: String, lemma: String? = nil) -> [String] {
        let found = (sentence as NSString).range(of: anchor)
        let ranges = Lemmatizer.parts(
            of: lemma ?? anchor, surface: anchor, in: sentence,
            at: found.location == NSNotFound ? nil : found)
        return ranges.map { (sentence as NSString).substring(with: $0) }
    }

    /// The defect this exists for: the captured range covers `temper`, and the card drew the word
    /// broken in half.
    @Test func anInflectedWordIsMarkedWhole() {
        #expect(marked("temper", in: "Justice tempered with mercy.") == ["tempered"])
        #expect(marked("hold", in: "The ship's holds were full.") == ["holds"])
        #expect(marked("run", in: "She was running late.") == ["running"])
    }

    /// Growing backwards matters too: a captured range can start mid-word.
    @Test func aRangeThatStartsInsideAWordGrowsBothWays() {
        #expect(marked("emper", in: "Justice tempered with mercy.") == ["tempered"])
    }

    /// Where the word ends is the system's answer, not a rule invented here. English word
    /// breaking keeps a possessive together and splits a hyphenated pair — both are what a reader
    /// would do, and neither is something this code should be deciding on its own.
    @Test func theWordEndsWhereTheSystemSaysItDoes() {
        #expect(marked("ship", in: "The ship's hold was full.") == ["ship's"])
        #expect(marked("known", in: "a well-known problem") == ["known"])
    }

    @Test func aWholeWordIsLeftAloneAndAMissingRangeMarksNothing() {
        #expect(marked("hold", in: "The hold was full.") == ["hold"])
        #expect(marked("absent", in: "No such word here.").isEmpty)
    }

    /// The word can sit at either end of the sentence without walking off it.
    @Test func aWordAtTheEdgeOfTheSentenceDoesNotRunPastIt() {
        #expect(marked("Hold", in: "Hold the line") == ["Hold"])
        #expect(marked("line", in: "Hold the line") == ["line"])
    }

    /// Chinese has no letter boundaries of the kind this grows through — it must not swallow the
    /// rest of the sentence.
    @Test func aWordInAScriptWithoutInflectionIsLeftAsItIs() {
        let sentence = "他屹立在山顶上。"
        #expect(marked("屹立", in: sentence) == ["屹立"])
    }

    // MARK: - Phrases

    /// The case one range cannot express: a phrasal verb split around its object. Marking the
    /// span would swallow the pronoun; marking the anchor alone would say the lookup was *take*.
    @Test func aPhrasalVerbIsMarkedInBothOfItsParts() {
        // The anchor is what was on screen — "took" — and the lemma is the phrase it belongs to.
        #expect(marked("took", in: "He took it over.", lemma: "take over") == ["took", "over"])
        #expect(marked("put", in: "She put the meeting off.", lemma: "put off") == ["put", "off"])
    }

    /// The same phrase said together. Two ranges rather than one, which the card draws identically
    /// — and which keeps the rule one rule instead of two.
    @Test func aPhraseSaidTogetherIsStillMarkedPartByPart() {
        #expect(marked("took", in: "He took over the company.", lemma: "take over")
                == ["took", "over"])
    }

    /// Beyond a short window a matching word is more likely to be a different word that happens to
    /// spell the same. The anchor is marked and the search stops — a partly marked phrase is
    /// honest, a wrongly marked one is not.
    @Test func aParticleTooFarAwayIsNotClaimed() {
        #expect(marked("took", in: "He took the whole entire wretched thing over.", lemma: "take over")
                == ["took"])
    }

    @Test func aParticleThatIsNotThereIsNotInvented() {
        #expect(marked("took", in: "He took it.", lemma: "take over") == ["took"])
    }

    /// Where the lemma is one word but what was captured is several — a selection rather than a
    /// hover — the surface is what the phrase is made of.
    @Test func aMultiWordSelectionIsMarkedFromTheSurface() {
        let sentence = "He took it over."
        let parts = Lemmatizer.parts(
            of: "take", surface: "took it over", in: sentence,
            at: (sentence as NSString).range(of: "took"))
        #expect(parts.map { (sentence as NSString).substring(with: $0) } == ["took", "it", "over"])
    }

    /// `ReadingEntry.markedRanges` is an adapter and nothing more. This is what says so.
    @Test func aCardAsksTheLemmatizerRatherThanRepeatingIt() {
        let sentence = "He took it over."
        let entry = ReadingEntry(
            id: 1, lemma: "take over", surface: "took", sentence: sentence,
            sentenceRange: (sentence as NSString).range(of: "took"),
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found, quality: nil)
        #expect(entry.markedRanges == Lemmatizer.parts(
            of: "take over", surface: "took", in: sentence,
            at: (sentence as NSString).range(of: "took")))
    }

    /// One word looked up in a sentence that happens to contain a phrase is still one word.
    @Test func aSingleWordLookupDoesNotGrowIntoAPhrase() {
        #expect(marked("took", in: "He took it over.", lemma: "take") == ["took"])
    }

    /// **A mark never swallows the space beside the word**, and this is the one place the rule is
    /// visible.
    ///
    /// Word boundaries came from two implementations in one module: `TextSegmenter.wordRanges`,
    /// which trims each token and drops the empties, and a private copy here that did neither — so
    /// the hover and OCR paths agreed about where a word ends and the lemma path, which is what
    /// marks the reader's own sentence in the drawer, did not. The copy is gone and this is what
    /// keeps it gone.
    ///
    /// The fixture is an en quad rather than a plain space because that is where the two answers
    /// actually differ: measured 2026-09-24, `NLTokenizer(unit: .word)` puts U+2000 and U+2001 —
    /// and only those — inside the token when one sits at either end of the string. A plain space
    /// it excludes by itself, which is why this went unnoticed for as long as it did. Both are
    /// ordinary in text set for print and copied out of a PDF.
    @Test func aMarkStopsAtTheWordAndNotAtTheSpaceAfterIt() {
        #expect(marked("over", in: "He took it over\u{2000}") == ["over"])
        #expect(marked("He", in: "\u{2000}He took it over") == ["He"])
    }

}

/// What NLTagger does not do for us, measured rather than assumed.
///
/// Probed on macOS 27 across 63 irregular English forms on 2026-09-24: 52 lemmatise correctly, one
/// comes back a *different word*, and ten come back unchanged — and those ten are **exactly** the
/// forms that are also words in their own right. That is a strong result for the table's design:
/// the criterion it was built on is the one the tagger actually follows. It is not a result for the
/// table's contents, which were two short.
struct IrregularFormCoverageTests {
    /// **`ground` and `bound` were missing, and missing is worse than absent here.** Not being in
    /// the table does not mean "no lemma"; it means `resolve` falls through to
    /// `Lemma(text: tagged, basis: .tagger)` — the inflected form recorded as the dictionary form,
    /// under the *most* confident basis there is. A reader grinding coffee got a study item for the
    /// earth under their feet, and nothing in the row said it was a guess.
    @Test func theFormsTheTaggerLeavesAloneAreAllInTheTable() {
        // Verb readings, where the table applies at all.
        #expect(Lemmatizer.lemma(of: "ground", in: "They ground the coffee beans.").text == "grind")
        #expect(Lemmatizer.lemma(of: "bound", in: "They had bound the papers together.").text == "bind")
    }

    /// The noun readings are untouched: the table is consulted only where NLTagger says verb, and
    /// `endsNounPhrase` holds the rest. Sitting on the ground is not grinding.
    @Test func theNounReadingsOfThoseFormsAreLeftAlone() {
        #expect(Lemmatizer.lemma(of: "ground", in: "He sat on the ground.").text == "ground")
    }

    /// **The one the table cannot catch, because the tagger changed the word.** `broke` comes back
    /// as `brake` — a different verb, in all five sentences probed — and `resolve` only consults the
    /// table when the tagger returned the word unchanged. So this arrived as a confident lemma for
    /// a word the reader never read. Corrections are a separate table for that reason: one is about
    /// a form the tagger declines to resolve, the other about one it resolves wrongly.
    @Test func aLemmaTheTaggerGetsWrongIsCorrected() {
        for sentence in ["They broke it yesterday.", "He broke the window.", "The vase broke."] {
            #expect(Lemmatizer.lemma(of: "broke", in: sentence).text == "break",
                    "broke was lemmatised wrongly in: \(sentence)")
        }
    }
}
