import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import XiaolaiDictBase

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// What the panel says when a reader points at a word.
struct LookupCardTests {
    private let entry = sampleEntry("New Oxford American Dictionary")
    private let sentence = "It was a fine piece of filmmaking, and the weather held."

    private func card(_ mark: SenseMark?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: sentence, mark: mark)
    }

    /// The whole point: one sense, the one read here.
    @Test func aChosenSenseIsTheAnswer() throws {
        let chosen = card(.chosen(key: "m_en_gbus0362750.005", by: .reader))
        guard case .sense(let sense) = chosen.answer else {
            Issue.record("the card did not lead with a sense")
            return
        }
        #expect(sense.key == "m_en_gbus0362750.005")
        #expect(chosen.isHypothesis == false, "the reader's own tap is a fact")
    }

    /// **Never only one.** The measured confidently-wrong rate is 17% with the fallback selector,
    /// so every other sense has to remain reachable or one reader in six is stuck with a wrong
    /// answer and no way to notice.
    @Test func everyOtherSenseIsStillThere() {
        let chosen = card(.chosen(key: "m_en_gbus0362750.005", by: .reader))
        #expect(chosen.otherSenseCount == entry.senseCount - 1)
        #expect(chosen.alternatives.allSatisfy { $0.key != "m_en_gbus0362750.005" })
    }

    /// XiaolaiDict's guess is drawn as a guess. This is `chosen_by` reaching the surface, and it is the
    /// difference between a card the reader can check and one they can only believe.
    @Test func theAppsGuessIsMarkedAsAHypothesis() {
        #expect(card(.chosen(key: "m_en_gbus0362750.020", by: .model)).isHypothesis)
        #expect(card(.chosen(key: "m_en_gbus0362750.020", by: .reader)).isHypothesis == false)
    }

    /// An abstention is the selector working, not failing. The card says so and shows no sense
    /// rather than promoting one nothing chose.
    @Test func anAbstentionIsAnAnswerAndNotAnError() throws {
        let undecided = card(.couldNot(.tooClose))
        guard case .undecided(let reason) = undecided.answer else {
            Issue.record("an abstention was turned into a sense")
            return
        }
        #expect(reason?.isEmpty == false, "the card does not say why")
        // And every sense is offered, because none was ruled out.
        #expect(undecided.otherSenseCount == entry.senseCount)
        #expect(undecided.isHypothesis == false, "nothing was claimed, so nothing is a hypothesis")
    }

    /// Nothing marked at all — the selector has not answered yet, or there was nothing to key.
    @Test func noMarkLeavesTheCardUndecidedRatherThanGuessing() {
        guard case .undecided = card(nil).answer else {
            Issue.record("the card invented an answer")
            return
        }
    }

    /// The reader's own sentence travels with the card. It is what makes a wrong answer visible:
    /// the claim sits directly above the text it was made from.
    @Test func theEvidenceIsTheReadersOwnSentence() {
        #expect(card(nil).sentence == sentence)
    }

    /// The part of speech shown is the *chosen sense's*, not the entry's list of everything it
    /// covers — "adjective · adverb · noun" says less than the one the reader is actually in.
    @Test func thePartOfSpeechIsTheOneTheReaderIsIn() throws {
        let chosen = card(.chosen(key: "m_en_gbus0362750.030", by: .reader))
        guard case .sense(let sense) = chosen.answer else {
            Issue.record("no sense")
            return
        }
        #expect(chosen.partOfSpeech == sense.partOfSpeech)
    }
}

/// The count of earlier lookups, as a number rather than a remark.
struct LookupMemoryTests {
    private func memory(_ times: Int) -> MemoryStrip? {
        MemoryStrip(PriorEncounters(occasions: (0..<times - 1).map {
            PriorEncounter(
                at: .now.addingTimeInterval(TimeInterval(-3600 * ($0 + 1))),
                where: "Safari", title: "A page")
        }))
    }

    private func card(times: Int) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(
                entry: sampleEntry("NOAD"),
                mark: .chosen(key: "m_en_gbus0362750.005", by: .reader), met: []),
            term: "fine", sentence: "A fine day.",
            mark: .chosen(key: "m_en_gbus0362750.005", by: .reader), memory: memory(times))
    }

    /// The badge shows the count and nothing else. The prose it replaced — "3rd lookup" across the
    /// top of the panel — told the reader they had failed to learn this word twice already.
    @Test func theCountTravelsWithTheCard() throws {
        let third = try #require(card(times: 3).memory)
        #expect(third.occasion == 3)
    }

    /// Below two occasions there is nothing worth saying, and the badge stays away entirely —
    /// a "1" on a first lookup would be noise on every card the reader ever sees.
    @Test func aFirstLookupHasNoBadge() {
        #expect(memory(1) == nil)
        #expect(card(times: 1).memory == nil)
    }

    /// **Where and when, never what.** An earlier encounter says *you should know this*; an
    /// earlier gloss answers the question and destroys the retrieval. `PriorEncounter` has no
    /// field for one, so the detail cannot leak a meaning however it is drawn.
    @Test func theDetailSaysWhereAndWhenAndNeverWhatItMeant() throws {
        let third = try #require(card(times: 3).memory)
        #expect(third.lines.isEmpty == false)
        for line in third.lines {
            #expect(line.localizedCaseInsensitiveContains("high quality") == false)
        }
    }
}

/// **How tall the panel is allowed to get, measured rather than reasoned about.**
///
/// This project has twice been wrong predicting SwiftUI's sizing from the documentation — the
/// settings window ("every pane at 450") and the setup board ("933 points of content in a window
/// ending at 800"), both found only in the running app. So this measures a real layout.
///
/// **It measures `LookupPanelContent`, not `LookupCardView`, and that is the finding.** The cap
/// was on the card first; the translation and explanation panes are the card's *siblings*, so a
/// long generated answer grew the window past the cap with no scrolling path to its own end. The
/// bound has to sit on everything the window is sized from.
@MainActor
struct PanelHeightTests {
    private let scale = Scale.standard

    /// `fittingSize` is AppKit asking the hosted SwiftUI view what it wants — the number the window
    /// then takes, since the scene is `.windowResizability(.contentSize)`.
    private func height(sentence: String) -> CGFloat {
        var presentation = LookupPresentation(
            request: 1, term: "fine", lemma: Lemma(text: "fine", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil)
        presentation.sentence = sentence
        presentation.outcome = .entries(
            NonEmpty([sampleEntry("New Oxford American Dictionary")])!, unreadable: [])
        let view = NSHostingView(
            rootView: LookupPanelContent(presentation: presentation).environment(\.scale, scale))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    private var short: String { "It was a fine piece of filmmaking." }
    private var long: String { String(repeating: "It was a fine piece of filmmaking. ", count: 60) }

    /// **The measurement responds to content at all.** Without this the two tests below are
    /// satisfied by a panel of constant height — which is exactly what a broken cap produces, and
    /// what the first version of this suite accepted.
    @Test func aLongerSentenceMakesATallerPanel() {
        let a = height(sentence: short), b = height(sentence: long)
        #expect(a > 0, "the panel laid out to nothing, so nothing below measures anything")
        #expect(b > a, "height does not track content: \(a) then \(b)")
    }

    /// **The cap is real, and the assertion is that growth *stops* — not a number.**
    ///
    /// Measured at `standard`: 267 pt for a one-line sentence, 405 for a sixty-fold one, and 405
    /// again for a six-hundred-fold one. Content stops moving the height, which is the invariant.
    ///
    /// It is not `<= cardMaxHeight` because it cannot be: the cap bounds the **scrolling region**,
    /// and the panel's own chrome — surface, border, shadow — is applied outside that frame and
    /// adds 21 pt on top. Asserting against the raw token failed here, and the first reading of
    /// that failure was that the cap did not work. Tripling the content settled it in one run:
    /// a cap that does not work grows, and this did not.
    @Test func theHeightStopsGrowingOnceTheCapIsReached() {
        let long = height(sentence: long)
        let tenfold = height(sentence: String(repeating: self.long, count: 10))
        #expect(long > 0)
        #expect(
            tenfold == long,
            "content still moves the height past the cap: \(long) then \(tenfold)")
        // **And the plateau is at the cap, not merely somewhere.** Equality alone is satisfied by a
        // panel that stops growing at any height at all, including one far past the cap. The
        // allowance is the panel's own chrome — surface, border, shadow — applied outside the
        // bounded frame, measured at 21 pt; 32 is that rounded up rather than fitted to it.
        #expect(
            long <= scale.space.cardMaxHeight + 32,
            "the panel plateaus well above the cap: \(long) against \(scale.space.cardMaxHeight)")
    }

    /// **And the cap is not a floor.** A panel with little to say must not be padded out to it —
    /// that is the `ScrollView`-is-greedy failure, and it would open every word at the same size.
    @Test func aShortPanelIsShorterThanTheCap() {
        let value = height(sentence: short)
        #expect(value > 0)
        #expect(
            value < scale.space.cardMaxHeight,
            "a short panel was padded out to the cap: \(value) of \(scale.space.cardMaxHeight)")
    }
}

/// What a card says about a dictionary that structures no senses.
struct SenselessEntryTests {
    /// **Three of the seven dictionaries enabled on this Mac are in this state** — Collins COBUILD,
    /// Longman and the Oxford Collocation Dictionary all report `senseKeyKind == .none`, so their
    /// entries arrive with an empty sense list. The card told the reader "the sense you read could
    /// not be identified", which reads as the selector failing on an entry it was never asked
    /// about.
    @Test func anEntryWithNoSensesSaysSoRatherThanBlamingTheSelector() throws {
        // Markup with no sense structure at all — no `x_xd1`, no `d:def` — which is the shape the
        // three sideloaded dictionaries here actually return.
        let markup = """
            <d:entry xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rfc" id="x" d:title="fine">
            <span class="hw">fine</span><span class="body">of very high quality</span>
            </d:entry>
            """
        let entry = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "Collins COBUILD", identifier: "collins", version: "1"),
            headword: "fine", lookedUp: "fine", html: markup,
            document: EntryDocument.parse(markup))
        let presentation = EntryPresentation(entry: entry, mark: nil, met: [])
        try #require(presentation.senses.isEmpty, "the fixture parsed senses, so it tests nothing")
        let card = LookupCard(
            presentation: presentation, term: "fine", sentence: nil, mark: nil)
        guard case .undecided(let reason) = card.answer else {
            Issue.record("a senseless entry did not produce an undecided answer")
            return
        }
        let text = try #require(reason, "the reader was given no reason at all")
        #expect(
            !text.contains("could not be identified"),
            "a dictionary that marks no senses was reported as a failure to identify one")
        #expect(text.contains("does not mark senses"))
    }
}

/// A word keeps one colour wherever it appears.
struct AccentConsistencyTests {
    /// **The panel hashed the surface and the drawer hashes the lemma**, so one encounter changed
    /// colour between the two: *tempered* lands on a different palette entry from *temper*. The
    /// card carries the lemma now and both hash it.
    @Test func thePanelAndTheDrawerColourOneWordTheSame() {
        let card = LookupCard(
            term: "tempered", lemma: "temper", heading: "temper", partOfSpeech: nil,
            pronunciation: nil, answer: .undecided(reason: nil), sentence: nil,
            alternatives: [], memory: nil)
        #expect(card.lemma == "temper")
        #expect(
            ReadingPalette.accent(for: card.lemma) == ReadingPalette.accent(for: "temper"),
            "the panel would colour this word differently from its own history row")
        #expect(
            ReadingPalette.accent(for: card.lemma) != ReadingPalette.accent(for: card.term),
            "the fixture picked a surface and lemma that hash alike, so it proves nothing")
    }

    /// With no lemma worked out the surface is the fallback — which is what the ledger stores too,
    /// so the two still agree.
    @Test func withNoLemmaTheSurfaceIsUsed() {
        let card = LookupCard(
            term: "fine", heading: "fine", partOfSpeech: nil, pronunciation: nil,
            answer: .undecided(reason: nil), sentence: nil, alternatives: [], memory: nil)
        #expect(card.lemma == "fine")
    }
}

/// **What the two buttons that outlive the panel are allowed to act on.**
///
/// `copyButton` and `pinButton` each carried their own `switch` over the answer and each ended in a
/// silent `default`, so on a card leading with no sense they were drawn enabled, took the click, and
/// left the pasteboard and the notes untouched. That is the project's own rule — a control that
/// refuses a click is a broken switch — at the two controls whose result the reader keeps.
struct SenseToKeepTests {
    private let entry = sampleEntry("New Oxford American Dictionary")

    private func card(_ mark: SenseMark?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: "It was a fine piece of filmmaking.", mark: mark)
    }

    private func cardWithout(_ answer: LookupCard.Answer) -> LookupCard {
        LookupCard(
            term: "fine", heading: "fine", partOfSpeech: nil, pronunciation: nil,
            answer: answer, sentence: nil, alternatives: [])
    }

    /// The reader's own tap and the entry's only sense are facts, and are kept as facts.
    @Test func aSenseTheCardLeadsWithCanBeCopiedAndKept() throws {
        let keep = try #require(card(.chosen(key: "m_en_gbus0362750.005", by: .reader)).senseToKeep)
        #expect(keep.sense.key == "m_en_gbus0362750.005")
        #expect(keep.standing == .confirmed)
    }

    /// **A guess kept is kept as a guess.** The panel's caveat does not travel with a note, so the
    /// standing has to.
    @Test func aGuessIsKeptAsAGuess() throws {
        let keep = try #require(card(.chosen(key: "m_en_gbus0362750.020", by: .model)).senseToKeep)
        #expect(keep.standing == .proposed)
    }

    /// The near miss the ambiguous card leads with is offered, and says it was one of several.
    @Test func aNearMissIsKeptAsOneOfSeveral() throws {
        let nearest = NearMiss(key: "m_en_gbus0362750.024", margin: 0.01, among: 3)
        let keep = try #require(card(.couldNot(.tooClose, nearest: nearest)).senseToKeep)
        #expect(keep.sense.key == "m_en_gbus0362750.024")
        #expect(keep.standing == .ambiguous)
    }

    /// **The case both buttons got wrong.** An abstention with no near miss, an entry whose
    /// dictionary marks no senses, a prose answer and a miss all lead with no sense — and three of
    /// the seven dictionaries enabled here mark none at all, so this is the ordinary card for a
    /// reader studying from one of them rather than an edge case.
    @Test func aCardWithNoSenseOffersNothingToCopyOrKeep() {
        #expect(card(.couldNot(.nothingFits)).senseToKeep == nil)
        #expect(card(nil).senseToKeep == nil, "a card nothing has marked yet promised a sense")
        #expect(cardWithout(.undecided(reason: nil)).senseToKeep == nil)
        #expect(cardWithout(.prose("of very high quality")).senseToKeep == nil)
        #expect(cardWithout(.absent).senseToKeep == nil)
    }
}

/// **A card that is claiming a guess has to say so, whether or not a sentence was captured.**
///
/// `standing` — "A guess — not confirmed", drawn in orange — was rendered from inside
/// `evidence(_:)`, which the card draws only `if let sentence = card.sentence, !sentence.isEmpty`.
/// So on a card with no sentence the caveat did not exist, and the selector's hypothesis rendered
/// exactly as confidently as the reader's own tap. That is "a failure must never render as
/// confidently as a success" and D2's *a wrong mark is visible and recoverable*, both broken in the
/// one state where the reader has least to check the claim against.
///
/// **The state is reachable, and not by an exotic path.** `SenseSelector.preflight` answers
/// `.chose` as soon as the part-of-speech filter leaves one candidate — *before* it checks for a
/// sentence — and `SenseResolver` files that as `by: .model` on purpose ("`.model` covers a choice
/// no model made"). `LookupRunner` passes no sentence whenever the capture's context is not
/// `.complete`, which is the ordinary hover and optical case. So: a degraded capture, a tagger that
/// answers, one sense of that part of speech, and the card claims a sense with nothing saying it
/// is a guess.
///
/// Read in pixels because the defect is *absence* in the view while every value behind it was
/// right — `isHypothesis` was true throughout. Orange is the signal: on a `.sense` card nothing
/// else is orange (the ambiguity badge is, and that is a different answer), so "is there any orange
/// in this card" is exactly the question.
@MainActor
struct StandingIsAlwaysShownTests {
    private let width: CGFloat = 400
    private let entry = sampleEntry("New Oxford American Dictionary")

    private func card(_ mark: SenseMark?, sentence: String?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: sentence, mark: mark)
    }

    /// How much of the card is orange, as a count of pixels that are clearly warmer than they are
    /// cool. A text colour antialiases, so this counts pixels rather than looking for one value.
    private func orangePixels(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(
            content: view.frame(width: width, alignment: .topLeading).background(Color.white))
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "the card did not rasterise")
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var orange = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            // Orange text on white: red well ahead of blue, and green between them. A grey has all
            // three within a few points of each other, so the gap is what separates them.
            if red - blue > 60, green > blue, red > 120 { orange += 1 }
        }
        return orange
    }

    /// The control case: with a sentence, the caveat has always been drawn.
    @Test func aGuessWithASentenceSaysSo() throws {
        let guess = card(.chosen(key: "m_en_gbus0362750.020", by: .model),
                         sentence: "It was a fine piece of filmmaking.")
        try #require(guess.isHypothesis, "the fixture is not a guess, so it tests nothing")
        #expect(try orangePixels(LookupCardView(card: guess)) > 0)
    }

    /// The defect: the same guess, with nothing captured around the word.
    @Test func aGuessWithNoSentenceStillSaysSo() throws {
        let guess = card(.chosen(key: "m_en_gbus0362750.020", by: .model), sentence: nil)
        try #require(guess.isHypothesis, "the fixture is not a guess, so it tests nothing")
        #expect(
            try orangePixels(LookupCardView(card: guess)) > 0,
            "a sense the selector guessed was drawn with nothing saying it is a guess")
    }

    /// And the other direction, so the check above cannot be satisfied by painting every card
    /// orange: the reader's own tap is a fact and is not caveated.
    @Test func theReadersOwnTapIsNotCaveated() throws {
        let chosen = card(.chosen(key: "m_en_gbus0362750.005", by: .reader), sentence: nil)
        try #require(chosen.isHypothesis == false)
        #expect(try orangePixels(LookupCardView(card: chosen)) == 0)
    }
}

/// **What confirming the card's own guess may and may not take away.**
///
/// A tap on an *alternative* sense clears the translation and the explanation, because promoting a
/// different sense makes everything said about the old one wrong. Confirming the sense already on
/// screen is not that: the reader agreed, and clearing their translation as the reward for agreeing
/// would be the worst possible answer to the most valuable thing they can do here.
///
/// So the rule is per-pane and not per-sense: **a pane survives exactly as long as its own inputs
/// are unchanged.** These tests are the inputs, compared across each transition — which is checkable,
/// where "did the pane disappear" inside a view's `@State` is not.
struct ConfirmingASenseTests {
    private let entry = sampleEntry("New Oxford American Dictionary")
    private let sentence = "It was a fine piece of filmmaking, and the weather held."
    private let key = "m_en_gbus0362750.020"

    private func card(_ mark: SenseMark?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: sentence, mark: mark)
    }

    private func translationKey(_ card: LookupCard) -> TranslationPane.Key {
        TranslationPane.Key(
            sentence: sentence, target: "zh-Hans", dictionary: entry.dictionary.key,
            sense: TranslationQuestion.metSense(of: card)?.sense)
    }

    /// The ordinary confirmation: the selector proposed a sense, the reader agreed. Nothing about
    /// either question changed, so nothing on screen may be taken away.
    @Test func confirmingAProposedSenseChangesNeitherQuestion() {
        let proposed = card(.chosen(key: key, by: .model))
        let confirmed = card(.chosen(key: key, by: .reader))
        try? #require(proposed.isHypothesis && !confirmed.isHypothesis)
        #expect(translationKey(proposed) == translationKey(confirmed),
                "a translation asked before confirming would be discarded")
        #expect(SentenceQuestion.reading(proposed, sentence: sentence)
                == SentenceQuestion.reading(confirmed, sentence: sentence),
                "an explanation asked before confirming would be about a different question")
    }

    /// **And the case that makes the rule per-pane rather than per-sense.** An ambiguous card leads
    /// with a favourite it has *not* claimed, so neither question is told the sense. Confirming it
    /// tells them both — so both answers are about a question nobody asked, and both must go.
    @Test func confirmingAnAmbiguousFavouriteChangesBothQuestions() throws {
        let nearest = NearMiss(key: key, margin: 0.01, among: 3)
        let ambiguous = card(.couldNot(.tooClose, nearest: nearest))
        let confirmed = card(.chosen(key: key, by: .reader))
        guard case .ambiguous = ambiguous.answer else {
            Issue.record("the fixture is not an ambiguous card, so it tests nothing")
            return
        }
        #expect(TranslationQuestion.metSense(of: ambiguous) == nil,
                "an ambiguous card handed its favourite to the translator")
        #expect(translationKey(ambiguous) != translationKey(confirmed))
        #expect(SentenceQuestion.reading(ambiguous, sentence: sentence)
                != SentenceQuestion.reading(confirmed, sentence: sentence),
                "the explanation has no key of its own, so this is the only thing that can notice")
    }

    /// The sense a card *leads with as an answer* — never the ambiguous favourite, which is the
    /// distinction both questions above rest on, and which was written out three times before it
    /// was a property.
    @Test func onlyAnAnsweredSenseLeadsTheCard() {
        #expect(card(.chosen(key: key, by: .model)).leadingSense?.key == key)
        #expect(card(.couldNot(.tooClose, nearest: NearMiss(key: key, margin: 0.01, among: 3))).leadingSense == nil)
        #expect(card(.couldNot(.nothingFits)).leadingSense == nil)
    }
}

/// **What the copy button puts on the pasteboard, as a value rather than as a string built inside a
/// button's action.**
///
/// It was assembled at the call site, so nothing could ask what a paste would say — and a paste has
/// no badge beside it, which is the whole reason the caveat is in the text.
///
/// It also answers WI-6. A public-fallback definition is prose: the card shows it, the panel draws no
/// footer for it, `senseToKeep` is nil because prose is not a sense and a note made from it would have
/// no standing — and the lookup window cannot become key (`.plain` gives a borderless window,
/// measured), so `textSelection` could not give the reader the text either. Copy can, and needs no
/// key window.
struct CopyableTextTests {
    private let entry = sampleEntry("New Oxford American Dictionary")

    private func card(_ mark: SenseMark?) -> LookupCard {
        LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: []),
            term: "fine", sentence: nil, mark: mark)
    }

    private func cardWithout(_ answer: LookupCard.Answer) -> LookupCard {
        LookupCard(
            term: "fine", heading: "fine", partOfSpeech: nil, pronunciation: nil,
            answer: answer, sentence: nil, alternatives: [])
    }

    /// The reader's own tap copies cleanly: it is a fact, and a fact needs no disclaimer.
    @Test func aConfirmedSenseCopiesWithoutACaveat() throws {
        let card = card(.chosen(key: "m_en_gbus0362750.005", by: .reader))
        let text = try #require(card.copyableText)
        // The *heading*, not the term: NOAD prints "fine¹" for the first homograph, and what the card
        // shows is what a paste should say.
        #expect(text.hasPrefix("\(card.heading) — "), "the copied text does not lead with the headword")
        #expect(text.contains("of high quality"))
        #expect(!text.contains("guess"))
    }

    /// **A guess says so in the copied text.** The panel's orange does not travel with a paste.
    @Test func aGuessCarriesItsCaveatIntoThePasteboard() throws {
        let text = try #require(card(.chosen(key: "m_en_gbus0362750.020", by: .model)).copyableText)
        #expect(text.contains("a guess — not confirmed"))
    }

    /// And so does the near miss the ambiguous card leads with.
    @Test func anAmbiguousFavouriteCarriesOneToo() throws {
        let nearest = NearMiss(key: "m_en_gbus0362750.024", margin: 0.01, among: 3)
        let text = try #require(card(.couldNot(.tooClose, nearest: nearest)).copyableText)
        #expect(text.contains("a guess — not confirmed"))
    }

    /// **Prose is copyable and un-pinnable, and that is the distinction.** A dictionary that answered
    /// in prose gave the reader something to take away; it did not give them a sense, so it cannot
    /// become a note.
    @Test func proseCanBeCopiedButNotKept() throws {
        let prose = cardWithout(.prose("of very high quality"))
        let text = try #require(prose.copyableText, "a prose answer could not be copied")
        #expect(text.contains("of very high quality"))
        #expect(prose.senseToKeep == nil, "prose became a note with no standing")
    }

    /// Nothing to copy where there is nothing: an abstention, and a word that is not there.
    @Test func thereIsNothingToCopyWhereTheCardNamesNothing() {
        #expect(card(.couldNot(.nothingFits)).copyableText == nil)
        #expect(cardWithout(.absent).copyableText == nil)
        #expect(cardWithout(.undecided(reason: nil)).copyableText == nil)
    }
}

/// **The card ends one `padDown` under its last control, and no further.**
///
/// Reported from a real screen: 70 pt of empty card under the footer, against the 15 pt the token
/// asks for. This is what told the two apart — the view's own layout leaves exactly
/// `padDown + glowAfter` (the second being the transparent margin the shadow falls in, outside the
/// card), so the view was never at fault and the window fit was overshooting, stretching the card's
/// surface past its own content.
///
/// Asserted as a **composition of the tokens** rather than against a number: the padding may be
/// retuned, and this must keep meaning "one padDown, exactly" after it is.
@MainActor
struct PanelBottomPaddingTests {
    @Test func theCardEndsJustUnderItsLastControl() throws {
        var presentation = LookupPresentation(
            request: 1, term: "fine", lemma: Lemma(text: "fine", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil)
        presentation.sentence = "It was a fine piece of filmmaking."
        presentation.outcome = .entries(
            NonEmpty([sampleEntry("New Oxford American Dictionary")])!, unreadable: [])
        let view = NSHostingView(
            rootView: LookupPanelContent(presentation: presentation).environment(\.scale, Scale.standard))
        view.layoutSubtreeIfNeeded()
        let wanted = view.fittingSize
        view.frame = NSRect(origin: .zero, size: wanted)
        view.layoutSubtreeIfNeeded()

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Walk up from the bottom for the last row holding any ink at all.
        var lastInk: Int?
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            var found = false
            for x in stride(from: 8, to: rep.pixelsWide - 8, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.brightnessComponent < 0.72, colour.alphaComponent > 0.5 { found = true; break }
            }
            if found { lastInk = y; break }
        }
        let ink = try #require(lastInk, "the panel drew nothing")
        let perPoint = CGFloat(rep.pixelsHigh) / wanted.height
        let gap = (CGFloat(rep.pixelsHigh - ink)) / perPoint
        let scale = Scale.standard
        // **Measured to the last *ink*, which is not the last control.** An icon button is a 28 pt
        // target around a glyph of about 15, so roughly 6 pt of its own frame sits under the mark —
        // real, deliberate, and not padding. So the bound is a band rather than an equality: at least
        // the card's own bottom padding plus the transparent margin the shadow falls in, and at most
        // that plus one whole target's height. Anything past that is dead space.
        let floor = scale.space.padDown + scale.shadow.glowAfter
        let ceiling = floor + Token.Target.minimum
        #expect(
            gap >= floor - 1 && gap <= ceiling,
            """
            the card leaves \(gap) pt under its last control, outside \(floor)…\(ceiling) — \
            padDown \(scale.space.padDown), shadow margin \(scale.shadow.glowAfter), \
            target \(Token.Target.minimum)
            """)
        // **And the padding itself is at least an em**, which is the reading that prompted this: a
        // control sitting on the card's edge looks like a mistake whatever the arithmetic says.
        #expect(scale.space.padDown >= scale.em, "the card's bottom padding is under one em")
    }
}
