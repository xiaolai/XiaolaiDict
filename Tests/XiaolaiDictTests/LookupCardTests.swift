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

/// **How tall the card is allowed to get, measured rather than reasoned about.**
///
/// This project has twice been wrong predicting SwiftUI's sizing from the documentation — the
/// settings window ("every pane at 450") and the setup board ("933 points of content in a window
/// ending at 800"), both found only in the running app. The specific risk here is the rule
/// `CardPile` records: *a frame with only an upper bound can grow but never shrink*, and a
/// `ScrollView` is greedy. If that applied, a two-line answer would sit in a card the full
/// `cardMaxHeight` tall with the rest empty.
///
/// So both directions are asserted, and the short case is the one that matters.
@MainActor
struct CardHeightTests {
    private let scale = Scale.standard

    /// Lays the card out for real — `fittingSize` is AppKit asking the hosted SwiftUI view what it
    /// wants, which is the number the window then takes because the scene is `.contentSize`.
    private func height(sentence: String) -> CGFloat {
        let entry = sampleEntry("New Oxford American Dictionary")
        let card = LookupCard(
            presentation: EntryPresentation(entry: entry, mark: nil, met: []),
            term: "fine", sentence: sentence, mark: nil)
        let view = NSHostingView(
            rootView: LookupCardView(card: card).environment(\.scale, scale))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }

    /// The cap is real: nothing may render taller than it, whatever the card holds. The sentence
    /// is the part that grows without bound here — `SelectionReader` falls back to the whole
    /// captured value where it finds no sentence boundary, so a card really can be handed text the
    /// size of the document it came from.
    @Test func noCardIsTallerThanTheCap() {
        let long = String(repeating: "It was a fine piece of filmmaking. ", count: 60)
        let tall = height(sentence: long)
        #expect(
            tall <= scale.space.cardMaxHeight,
            "a long card was not capped: \(tall) against \(scale.space.cardMaxHeight)")
    }

    /// **And the cap is not a floor.** A card with little to say must not be padded out to it —
    /// that is the `ScrollView`-is-greedy failure, and it would look like a bug rather than a
    /// design, because the panel would open the same size for every word.
    @Test func aShortCardIsShorterThanTheCap() {
        let short = height(sentence: "It was a fine piece of filmmaking.")
        #expect(short > 0, "the card laid out to nothing, so this measures nothing")
        #expect(
            short < scale.space.cardMaxHeight,
            "a short card was padded out to the cap: \(short) of \(scale.space.cardMaxHeight)")
    }
}
