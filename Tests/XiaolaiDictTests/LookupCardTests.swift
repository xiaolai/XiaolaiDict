import Foundation
import SwiftUI
import Testing

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
