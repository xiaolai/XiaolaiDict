import AppKit
import DictionaryModel
import Foundation
import StudyKit
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **The phrase, on the card.**
///
/// The reader met *purple passage*, saw two words they knew, and felt no doubt. The detector found the span
/// and the service answered it; this is the half that puts it in front of them — and the half that has to
/// keep a guess looking like a guess.
struct PhraseNoticeTests {
    /// The shape all nine of Apple's dictionaries share: `x_xd0` the part-of-speech block, `x_xd1` a sense,
    /// `d:def` its definition. Without `class="df"` on the definition span nothing is captured, which this
    /// fixture got wrong first and the test caught.
    private static func entry(_ definition: String?, headword: String = "take") -> DictionaryEntry {
        let marked = definition.map { "<span d:def=\"1\" class=\"df\">\($0)</span>" } ?? ""
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="x" d:title="\(headword)">
            <span class="hg x_xh0"><span class="hw">\(headword)</span></span>
            <span id="x.001" class="se1 x_xd0"><span id="x.002" class="se2 x_xd1 hasSn">\(marked)</span></span>
            </d:entry>
            """
        return DictionaryEntry(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad", version: "1"),
            headword: headword, lookedUp: headword, html: markup,
            document: EntryDocument.parse(markup))
    }

    /// **A list, because the wire carries every phrase covering the word.** The card draws the leading one;
    /// nothing on the lookup path deletes a candidate, so the selector sees them all.
    private static func hit(_ phrase: String = "take something into account",
                            location: Int = 0, length: Int = 12,
                            separation: PhraseSeparation = .marked(2),
                            meaning: PhraseMeaning = PhraseMeaning()) -> [PhraseHit] {
        [PhraseHit(phrase: phrase, location: location, length: length,
                   separation: separation, meaning: meaning)]
    }

    // MARK: - What the card is allowed to claim

    /// **`.notReady` draws nothing rather than "no phrase here."** A reader whose service is still reading
    /// its inventory is told nothing, which is true; claiming the absence would be a failure rendering as
    /// confidently as a success.
    @Test(arguments: [PhraseAnswer.notReady, .none, .notAsked])
    func nothingIsDrawnForAnAnswerThatFoundNoPhrase(answer: PhraseAnswer) {
        #expect(PhrasePresentation(answer, sentence: "they take it into account") == nil)
    }

    /// Without the card's own sentence there is no span to mark, so there is nothing to explain either.
    @Test func nothingIsDrawnWithoutTheSentenceTheSpanWasMeasuredIn() {
        #expect(PhrasePresentation(.found(Self.hit()), sentence: nil) == nil)
    }

    /// **The range is checked against the sentence the card holds.** The hit was measured against the
    /// sentence that was *sent*, and the presentation drops that sentence for an incomplete capture — so an
    /// unchecked span would bracket whatever sits at that offset, which is the defect `sentenceRange`
    /// already documents for the word.
    @Test(arguments: [(0, 99), (-1, 4), (0, 0), (20, 4)])
    func aSpanThatCannotBeInTheSentenceIsRefused(location: Int, length: Int) {
        let answer = PhraseAnswer.found(Self.hit(location: location, length: length))
        #expect(PhrasePresentation(answer, sentence: "take it in") == nil)
    }

    /// A span that fits is kept, spelling and all.
    @Test func aSpanInsideTheSentenceIsKept() {
        let sentence = "take it into account today"
        let found = PhrasePresentation(
            .found(Self.hit(location: 0, length: 20, separation: .marked(1))), sentence: sentence)
        #expect(found?.phrase == "take something into account",
                "the dictionary's own spelling, not the words the reader wrote")
        #expect(found?.range == NSRange(location: 0, length: 20))
        #expect(found?.separation == .marked(1))
    }

    // MARK: - A guess must look like one

    /// **Only an inference is hedged.** A nine-word marked gap is still the publisher saying an object goes
    /// there; hedging it would teach the reader to discount the mark that is actually reliable.
    @Test func onlyAnInferredSplitIsAGuess() {
        #expect(PhrasePresentation(phrase: "p", range: NSRange(location: 0, length: 1),
                                   separation: .inferred(2), definition: nil).isGuess)
        #expect(PhrasePresentation(phrase: "p", range: NSRange(location: 0, length: 1),
                                   separation: .marked(9), definition: nil).isGuess == false)
        #expect(PhrasePresentation(phrase: "p", range: NSRange(location: 0, length: 1),
                                   separation: .none, definition: nil).isGuess == false)
    }

    /// **Dashed for a guess, solid for the publisher's mark**, and the underline is what a reader comparing
    /// the claim against their own sentence actually sees. Asserted on the attribute rather than by eye,
    /// because a view body is not something a test can ask.
    @Test func theUnderlineSaysWhoAllowedTheGap() throws {
        let sentence = "they turn the offer down"
        func style(_ separation: PhraseSeparation) -> Text.LineStyle? {
            let phrase = PhrasePresentation(
                phrase: "turn down", range: (sentence as NSString).range(of: "turn the offer down"),
                separation: separation, definition: nil)
            let text = MarkedSentence.text(sentence, marking: [], phrase: phrase,
                                           size: Scale.standard.text.body,
                                           emphasis: .bold, accent: .red)
            return text.runs.compactMap(\.underlineStyle).first
        }
        #expect(style(.marked(2)) == Text.LineStyle(pattern: .solid))
        #expect(style(.none) == Text.LineStyle(pattern: .solid))
        #expect(style(.inferred(2)) == Text.LineStyle(pattern: .dash))
    }

    /// **The word's own marking survives the phrase's underline**, because a phrase written unbroken
    /// contains the word and the two spans overlap in the commonest case. Applied the other way round the
    /// underline overwrote the colour and the reader lost the word inside the phrase.
    @Test func theWordIsStillMarkedInsideThePhrase() throws {
        let sentence = "a purple passage nobody could follow"
        let text = sentence as NSString
        let phrase = PhrasePresentation(
            phrase: "purple passage", range: text.range(of: "purple passage"),
            separation: .none, definition: nil)
        let marked = MarkedSentence.text(
            sentence, marking: [text.range(of: "passage")], phrase: phrase,
            size: Scale.standard.text.body, emphasis: .bold, accent: .red)
        let word = try #require(marked.runs.first { $0.foregroundColor != nil })
        #expect(String(marked[word.range].characters) == "passage")
        #expect(word.underlineStyle != nil, "the word inside the phrase keeps both markings")
    }

    /// No phrase, no underline — the common case, and the one a stray default would spoil silently.
    @Test func anOrdinarySentenceCarriesNoUnderline() {
        let text = MarkedSentence.text("i read a long passage aloud", marking: [], phrase: nil,
                                       size: Scale.standard.text.body, emphasis: .bold, accent: .red)
        #expect(text.runs.compactMap(\.underlineStyle).isEmpty)
    }

    // MARK: - What it says the phrase means

    /// The first definition any entry marks, in the reader's own dictionary order — not a judgement this
    /// type is in a position to make.
    @Test func theLeadingDefinitionIsTheFirstOneMarked() {
        #expect(PhrasePresentation.definition(in: [Self.entry(nil), Self.entry("consider or include")])
            == "consider or include")
    }

    /// No definition is an ordinary answer: the span is in the dictionary's keys and its entry may still
    /// mark none a parser can reach. The notice then shows the phrase alone rather than nothing.
    @Test func anEntryWithNoMarkedDefinitionGivesNone() {
        #expect(PhrasePresentation.definition(in: [Self.entry(nil)]) == nil)
        #expect(PhrasePresentation.definition(in: []) == nil)
    }

    // MARK: - The wrong meaning under the right words

    /// **A phrase filed inside another word's entry shows its own meaning, from the body walk.**
    ///
    /// One dictionary's filing of a phrase, as the service builds it from the body walk.
    static func filing(_ definitions: [String], dictionary: String = "NOAD",
                       parent: String = "m_en_gbus0005190") -> PhraseFiling {
        PhraseFiling(dictionary: DictionaryIdentity(name: dictionary, identifier: "test.\(dictionary)"),
                     parentEntryID: parent, blockID: "\(parent).081", definitions: definitions,
                     contentVersion: "v1", formatVersion: "phrases/6")
    }

    /// Measured on NOAD: `take something into account` is answered with `m_en_gbus0005190`, which is
    /// `account`'s entry, and printing *that* entry's first sense would put *a report or description of an
    /// event* under the phrase — the wrong meaning under the right words. The phrase inventory reads the
    /// sub-entry's own definition instead, so the reader gets a true one rather than being sent elsewhere.
    @Test func aPhraseFiledUnderAnotherWordShowsItsOwnMeaning() {
        let found = PhrasePresentation(
            .found(Self.hit(location: 0, length: 10,
                            meaning: PhraseMeaning(
                                filings: [Self.filing(["consider something along with other factors"])]))),
            sentence: "take it into account")
        #expect(found?.definition == "consider something along with other factors")
    }

    /// A sub-entry no dictionary explains carries nothing rather than an empty line — which would read as a
    /// phrase that means nothing at all.
    @Test func asubEntryWithNoMeaningShowsNone() {
        let found = PhrasePresentation(
            .found(Self.hit(location: 0, length: 10, meaning: PhraseMeaning())),
            sentence: "take it into account")
        #expect(found?.definition == nil)
    }

    /// A phrase with an entry of its own shows that entry's meaning, which really is the phrase's.
    @Test func aPhraseWithItsOwnEntryShowsItsOwnMeaning() {
        let entry = Self.entry("an elaborate or excessively ornate passage", headword: "purple passage")
        let found = PhrasePresentation(
            .found(Self.hit("purple passage", location: 2, length: 14, separation: .none,
                            meaning: PhraseMeaning(ownEntries: [entry]))),
            sentence: "a purple passage nobody could follow")
        #expect(found?.definition == "an elaborate or excessively ornate passage")
    }

    /// **Only an own entry's senses are candidates for the ladder.** `entries` is the accessor the resolver
    /// reads, and for a sub-entry it must be empty — otherwise the selector is handed the parent's senses
    /// and can confidently pick one of them as the meaning of the phrase.
    @Test func aSubEntryOffersNoCandidatesToTheLadder() {
        let entry = Self.entry("a report or description of an event", headword: "account")
        #expect(PhraseHit(phrase: "take something into account", location: 0, length: 10,
                          separation: .marked(2),
                          meaning: PhraseMeaning(filings: [Self.filing(["consider"])])).entries.isEmpty)
        #expect(PhraseHit(phrase: "purple passage", location: 0, length: 14,
                          separation: .none,
                          meaning: PhraseMeaning(ownEntries: [entry])).entries.count == 1)
    }

    // MARK: - It has to reach the card

    /// **Assert the wire.** A presentation nothing reads is not a feature, so the phrase must arrive on the
    /// card the panel actually builds — including the card for a word that was never found, which is
    /// exactly the reader who most needs telling their sentence held a phrase.
    @Test func thePhraseReachesBothKindsOfCard() {
        let phrase = PhrasePresentation(phrase: "purple passage",
                                        range: NSRange(location: 2, length: 14),
                                        separation: .none, definition: "overwritten prose")
        let withEntry = LookupCard(
            presentation: EntryPresentation(entry: Self.entry("of high quality"), mark: nil, met: []),
            term: "passage", sentence: "a purple passage", mark: nil, phrase: phrase)
        #expect(withEntry.phrase == phrase)
        let withoutEntry = LookupCard(
            term: "passage", heading: "passage", partOfSpeech: nil, pronunciation: nil,
            answer: .absent, sentence: "a purple passage", alternatives: [], phrase: phrase)
        #expect(withoutEntry.phrase == phrase)
    }
}

/// **The card hears that a phrase could not be read** (audit round 3, #2), rather than drawing it as
/// though every dictionary had answered.
struct PhraseRetrievalPresentationTests {
    @Test func aFailedPhraseLookupReachesTheCard() throws {
        let hit = PhraseHit(phrase: "give up", location: 5, length: 7, separation: .none,
                            meaning: PhraseMeaning(ownEntries: []), retrieval: .failed)
        let shown = try #require(PhrasePresentation(.found([hit]), sentence: "They give up."))
        #expect(shown.retrieval == .failed)
        let clean = PhraseHit(phrase: "give up", location: 5, length: 7, separation: .none,
                              meaning: PhraseMeaning(ownEntries: []))
        #expect(try #require(PhrasePresentation(.found([clean]), sentence: "They give up.")).retrieval == .complete)
    }
}

/// **Saving the phrase on the card as a study card** — the owner's request of 2026-10-05, ADR-0049.
///
/// What the card offers to save has to be exactly what it shows: the dictionary's own spelling, and the
/// meaning on the notice — the study dictionary's, or none. A meaning from another dictionary saved under
/// this one's name would be signed by a dictionary that never said it.
struct PhraseCollectingTests {
    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")
    private static let thesaurus = DictionaryIdentity(
        name: "Oxford Thesaurus", identifier: "com.apple.dictionary.OT", version: "1.0")
    private static let spelling = "take something into account"
    private static let sentence = "they took it into account"
    private static let consider = "consider something along with other factors before reaching a decision"

    private static func filing(_ definition: String, in dictionary: DictionaryIdentity) -> PhraseFiling {
        PhraseFiling(dictionary: dictionary, parentEntryID: "m_en_gbus0005190",
                     blockID: "m_en_gbus0005190.081", definitions: [definition],
                     contentVersion: "2.6:aa:bb", formatVersion: "phrases/6")
    }

    /// An entry of the phrase's own, in `dictionary`, whose one sense may or may not mark a definition.
    private static func ownEntry(_ definition: String?, in dictionary: DictionaryIdentity) -> DictionaryEntry {
        let marked = definition.map { "<span d:def=\"1\" class=\"df\">\($0)</span>" } ?? ""
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng" id="own" d:title="phrase">
            <span class="hg x_xh0"><span class="hw">\(spelling)</span></span>
            <span id="own.001" class="se1 x_xd0"><span id="own.002" class="se2 x_xd1 hasSn">\(marked)</span></span>
            </d:entry>
            """
        return DictionaryEntry(dictionary: dictionary, headword: spelling, lookedUp: spelling, html: markup,
                               document: EntryDocument.parse(markup))
    }

    private static func presentation(
        _ meaning: PhraseMeaning, separation: PhraseSeparation = .marked(1), study: String? = noad.key
    ) throws -> PhrasePresentation {
        try #require(PhrasePresentation(
            .found([PhraseHit(phrase: spelling, location: 5, length: 20, separation: separation,
                              meaning: meaning)]),
            sentence: sentence, studyDictionary: study))
    }

    // MARK: - What the notice shows

    /// **The study dictionary's meaning leads the notice**, as its entry leads the card (D7). Before, the
    /// first own entry in any dictionary won, so the notice could show one dictionary's meaning and a saved
    /// card reveal another's.
    @Test func theStudyDictionarysMeaningLeadsTheNotice() throws {
        let meaning = PhraseMeaning(ownEntries: [Self.ownEntry("deliberate", in: Self.thesaurus)],
                                    filings: [Self.filing(Self.consider, in: Self.noad)])
        #expect(try Self.presentation(meaning).definition == Self.consider)
        #expect(try Self.presentation(meaning, study: nil).definition == "deliberate",
                "with no study dictionary the order is the service's, as it was")
    }

    // MARK: - What saving it would save

    /// **A phrase the study dictionary files is offered, under its own spelling and with the meaning on
    /// the notice.** The spelling is the inventory's — `take something into account`, never the reader's
    /// `took it into account` — and the filing goes with it as evidence.
    @Test func aPhraseTheStudyDictionaryFilesIsOffered() throws {
        let filing = Self.filing(Self.consider, in: Self.noad)
        let shown = try Self.presentation(PhraseMeaning(filings: [filing]))
        #expect(shown.collecting == .offered(PhraseCollection(
            dictionary: Self.noad, spelling: Self.spelling, answer: Self.consider, filings: [filing],
            ownEntryKeys: [], isProposal: false)))
    }

    /// **A phrase with its own entry is answered from that entry**, which is where the reader sees its
    /// meaning: the inventory explains only what is filed inside another word.
    @Test func aPhraseWithItsOwnEntryIsAnsweredFromIt() throws {
        let shown = try Self.presentation(PhraseMeaning(ownEntries: [Self.ownEntry("an ornate passage", in: Self.noad)]))
        guard case .offered(let phrase) = shown.collecting else {
            Issue.record("an own-entry phrase was not offered: \(shown.collecting)")
            return
        }
        #expect(phrase.answer == "an ornate passage")
        #expect(phrase.filings.isEmpty, "an own entry is not a filing, and has no block to record")
        #expect(phrase.spelling == Self.spelling)
        // **Its entry goes with it**, by key: what lets the save see a meaning of it already a card (ADR-0049).
        #expect(phrase.ownEntryKeys == ["own"])
    }

    /// **The answer is the meaning the notice shows** — a sense the selector proposed for the phrase, when
    /// it proposed one, and saved as the proposal it is.
    @Test func theAnswerIsTheMeaningTheNoticeShows() throws {
        var shown = try Self.presentation(PhraseMeaning(ownEntries: [Self.ownEntry("an ornate passage", in: Self.noad)]))
        shown.met = PhrasePresentation.SenseMet(definition: "a passage of florid prose", isHypothesis: true,
                                                dictionary: Self.noad.key)
        guard case .offered(let guessed) = shown.collecting else {
            Issue.record("not offered: \(shown.collecting)")
            return
        }
        #expect(guessed.answer == "a passage of florid prose")
        #expect(guessed.isProposal, "a meaning the selector guessed was saved as the reader's")
        shown.met = PhrasePresentation.SenseMet(definition: "a passage of florid prose", isHypothesis: false,
                                                dictionary: Self.noad.key)
        let tapped = try #require(shown.collecting.offeredSave, "a meaning the reader tapped was not offered")
        #expect(!tapped.isProposal)
    }

    /// **Another dictionary's meaning is never saved as this one's.** Where the notice shows a meaning
    /// the study dictionary did not give, the card is saved with no answer and waits for the reader's own.
    @Test func anotherDictionarysMeaningIsNeverSavedAsTheStudyDictionarys() throws {
        let meaning = PhraseMeaning(ownEntries: [Self.ownEntry(nil, in: Self.noad)],
                                    filings: [Self.filing("deliberate", in: Self.thesaurus)])
        var shown = try Self.presentation(meaning)
        #expect(shown.definition == "deliberate", "premise: the notice shows the thesaurus's meaning")
        guard case .offered(let phrase) = shown.collecting else {
            Issue.record("not offered: \(shown.collecting)")
            return
        }
        #expect(phrase.answer == nil, "the thesaurus's meaning was saved under NOAD's name")
        #expect(phrase.dictionary == Self.noad)
        shown.met = PhrasePresentation.SenseMet(definition: "weigh", isHypothesis: true,
                                                dictionary: Self.thesaurus.key)
        let met = try #require(shown.collecting.offeredSave, "a phrase the study dictionary holds was not offered")
        #expect(met.answer == nil && !met.isProposal, "another dictionary's guess became this card's answer")
    }

    /// **An inferred split is the app's guess about English** and is saved as a proposal, as it is drawn.
    @Test func anInferredSplitIsSavedAsAProposal() throws {
        let shown = try Self.presentation(PhraseMeaning(filings: [Self.filing(Self.consider, in: Self.noad)]),
                                          separation: .inferred(1))
        // **Required, never a silent return**: refused, this test used to pass with nothing asserted.
        let phrase = try #require(shown.collecting.offeredSave, "an inferred split was not offered")
        #expect(phrase.isProposal)
    }

    /// **Refused with a reason, never offered and then silent**: the study dictionary does not hold the
    /// phrase, or no study dictionary answered at all.
    @Test func aPhraseTheStudyDictionaryDoesNotHoldIsRefusedWithAReason() throws {
        let meaning = PhraseMeaning(filings: [Self.filing(Self.consider, in: Self.noad)])
        #expect(try Self.presentation(meaning, study: Self.thesaurus.key).collecting == .refused(.notInStudyDictionary))
        #expect(try Self.presentation(meaning, study: nil).collecting == .refused(.noStudyDictionary))
        for refusal in PhraseCollectRefusal.allCases {
            #expect(!String(localized: refusal.reason).isEmpty, "\(refusal) says nothing")
        }
    }

    // MARK: - The control

    /// **Save, saving, saved** — the control follows what the ledger answered, and a failure offers the
    /// same save again rather than a dead control.
    @Test func theControlFollowsTheSave() throws {
        let shown = try Self.presentation(PhraseMeaning(filings: [Self.filing(Self.consider, in: Self.noad)]))
        let phrase = try #require(shown.collecting.offeredSave, "the phrase was not offered, so no state follows")
        #expect(PhraseCollectControl(shown, status: nil, keep: .kept) == .offered(phrase))
        #expect(PhraseCollectControl(shown, status: .collecting, keep: .kept) == .saving)
        #expect(PhraseCollectControl(shown, status: .collected, keep: .kept) == .saved)
        #expect(PhraseCollectControl(shown, status: .alreadyCollected, keep: .kept) == .alreadySaved)
        #expect(PhraseCollectControl(shown, status: .failed, keep: .kept) == .retry(phrase))
    }

    /// **A reading put away cannot be saved from, and the control says why** — disabled with its reason,
    /// never a switch that refuses a click. A phrase already saved stays saved.
    @Test func aPutAwayReadingDisablesTheControlAndSaysWhy() throws {
        let shown = try Self.presentation(PhraseMeaning(filings: [Self.filing(Self.consider, in: Self.noad)]))
        #expect(PhraseCollectControl(shown, status: nil, keep: .discarded) == .refused(.readingDiscarded))
        #expect(PhraseCollectControl(shown, status: nil, keep: .discardedExternally) == .refused(.readingDiscarded))
        #expect(PhraseCollectControl(shown, status: nil, keep: .deleted) == .refused(.readingDeleted))
        #expect(PhraseCollectControl(shown, status: .collected, keep: .discarded) == .saved)
        let elsewhere = try Self.presentation(PhraseMeaning(filings: [Self.filing(Self.consider, in: Self.noad)]),
                                              study: Self.thesaurus.key)
        #expect(PhraseCollectControl(elsewhere, status: nil, keep: .kept) == .refused(.notInStudyDictionary))
    }

    /// **An unwired save is loud and answers false** — the environment's default is a fault, not a
    /// button that takes a click and does nothing.
    @MainActor @Test func anUnwiredSaveAnswersFalse() {
        let phrase = PhraseCollection(dictionary: Self.noad, spelling: Self.spelling, answer: nil, filings: [],
                                      ownEntryKeys: [], isProposal: false)
        #expect(EnvironmentValues().collectPhrase(phrase) == false)
    }
}

private extension PhraseCollecting {
    /// The save offered, or nil where it was refused — read through `#require`, so a refusal fails the test
    /// instead of returning from it with nothing asserted (the final closing pass, finding 5).
    var offeredSave: PhraseCollection? {
        if case .offered(let phrase) = self { phrase } else { nil }
    }
}
