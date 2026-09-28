import Foundation
import Testing

@testable import AppleDictionaryFormat

/// **The phrase a reader did not know to look up.**
///
/// A reader meets *purple passage* and sees two words they know, so they never look it up — the failure
/// ADR-0009 calls the highest-value thing this app can uniquely do. There is no baseline to beat: without
/// detection the reader gets nothing.
///
/// `DictionaryBridge` already holds every phrase's content, keyed under the phrase itself — *purple
/// passage* is `m_en_gbus0830950`, *kick the bucket* has 7 senses. So this type supplies only the missing
/// half: **which span of a sentence is a phrase the dictionary knows.** No senses, no entries, no
/// identity, and therefore no orphaning and no sense-key question.
///
/// Measured: NOAD's `KeyText.data` yields **90,391** multi-word keys in **1.30 MB**, read in **0.2 s** —
/// against 319 MB and 317 s for the full index. The phrase feature needs no index at all.
struct PhraseSpanTests {
    /// Keys as a dictionary stores them: **lemma form**. `give up` is a key; `gave up` is not, which is
    /// why the span is normalised before matching.
    private let known: Set<String> = [
        "purple passage", "purple prose", "give up", "give in", "take off", "take on",
        "kick the bucket", "red herring", "beat around the bush", "hold out", "hold up",
        // **A real competition, which the first version of these tests lacked.** `give up` and
        // `give up the ghost` are both phrases NOAD carries, so a sentence holding the longer one has
        // two valid answers and only the longer is right. Without a pair like this the longest-wins
        // test passed with the rule inverted — caught by neutralising it, not by reading it.
        "give up the ghost",
        // **Slot forms, as the publisher writes them.** These are the shapes measured in NOAD — 1,401 of
        // its multi-word keys and 1,659 of its sub-entry labels name the object's position explicitly, so
        // separability is read off the label rather than inferred.
        "give something up", "take something into account", "account for something",
        "look something up", "bear something in mind",
        // **What NOAD actually files for a plain phrasal verb: no slot at all.** Measured 2026-09-29 —
        // `turn down`, `give away`, `look after` are all bare, so separability there is a fact about
        // English rather than about the dictionary, and it is the only thing this type infers.
        "turn down", "give away", "look after",
    ]

    private func index() -> PhraseSpans { PhraseSpans(phrases: known) }

    /// The reader hovers one word; the phrase around it is what they needed.
    @Test(arguments: [
        ("the review was full of purple passage nobody could follow", 5, "purple passage"),
        ("that argument is a red herring", 5, "red herring"),
        ("the plane will take off shortly", 3, "take off"),
    ])
    func thePhraseAroundTheHoveredWordIsFound(sentence: String, word: Int, expected: String) {
        #expect(index().phrase(in: sentence.components(separatedBy: " "), containing: word) == expected)
    }

    /// **The longest wins**, and this is the only test here that can tell: `give up` and
    /// `give up the ghost` both contain the hovered word, and only the longer is what the reader met.
    /// Verified by inverting the search order, which turns this red and nothing else.
    @Test func theLongestKnownSpanWins() {
        let words = ["they", "give", "up", "the", "ghost", "eventually"]
        #expect(index().phrase(in: words, containing: 1) == "give up the ghost")
        #expect(index().phrase(in: words, containing: 4) == "give up the ghost",
                "and from the far end of the phrase too")
    }

    /// The shorter phrase is still right where the longer one is not present.
    @Test func theShorterPhraseWinsWhenTheLongerIsAbsent() {
        #expect(index().phrase(in: ["they", "give", "up", "easily"], containing: 1) == "give up")
    }

    /// A word that is not in any phrase must answer nothing rather than the nearest guess — this is the
    /// common case, and a false phrase is worse than none because the reader cannot see it is wrong.
    @Test func anOrdinaryWordFindsNoPhrase() {
        #expect(index().phrase(in: ["i", "read", "a", "long", "passage", "aloud"], containing: 4) == nil)
    }

    /// The span must contain the hovered word. `give up` sits in the sentence, but the reader hovered a
    /// word outside it.
    @Test func aPhraseElsewhereInTheSentenceIsNotTheAnswer() {
        let words = ["she", "gave", "up", "on", "the", "difficult", "idea"]
        #expect(index().phrase(in: words, containing: 5) == nil)
    }

    /// Two phrases share a word and only one is present: `give in` must not match "give up".
    @Test func theRightPhraseAmongNeighboursThatShareAWord() {
        #expect(index().phrase(in: ["they", "give", "in", "easily"], containing: 1) == "give in")
        #expect(index().phrase(in: ["they", "give", "up", "easily"], containing: 1) == "give up")
    }

    /// Bounds, because an off-by-one here reads a word that is not there.
    @Test func theFirstAndLastWordAreReachable() {
        #expect(index().phrase(in: ["take", "off", "now"], containing: 0) == "take off")
        #expect(index().phrase(in: ["now", "take", "off"], containing: 2) == "take off")
        #expect(index().phrase(in: [], containing: 0) == nil)
        #expect(index().phrase(in: ["take"], containing: 5) == nil, "an index past the end is not a crash")
    }

    /// A single word is never the answer, however well known: the bridge already looks that up, and
    /// returning it here would make every lookup claim to be a phrase.
    @Test func aSingleWordIsNotAPhrase() {
        #expect(PhraseSpans(phrases: ["take"]).phrase(in: ["take", "it"], containing: 0) == nil)
    }

    /// **The sentence that raised the question.** Nine words sit in the slot, and the object contains
    /// "and", so nothing structural separates this from two unrelated clauses — only the publisher's own
    /// `something` says the gap belongs there.
    @Test func aPhrasalVerbSplitByALongObjectIsStillTheSamePhrase() {
        let words = "take what people think and other possible edge cases all into account"
            .components(separatedBy: " ")
        let found = index().match(in: words, containing: 0)
        #expect(found?.phrase == "take something into account")
        #expect(found?.words == 0 ... 11, "the span reaches from the verb to the end of the phrase")
        #expect(found?.gap == 9, "and says how far it reached, so the selector can weigh it")
        #expect(index().match(in: words, containing: 11)?.phrase == "take something into account",
                "and is found from the far end as well as from the verb")
    }

    /// A word that merely fell inside somebody else's slot is not part of the phrase. Hovering *people*
    /// in that sentence is hovering *people* — this is the guard that keeps a long gap from swallowing
    /// every word between the two halves.
    @Test func aWordInsideTheSlotIsNotPartOfThePhrase() {
        let words = "take what people think and other possible edge cases all into account"
            .components(separatedBy: " ")
        #expect(index().match(in: words, containing: 2) == nil)
        #expect(index().match(in: words, containing: 8) == nil)
    }

    /// The everyday separable case, which a contiguous matcher misses entirely.
    ///
    /// Sentences arrive in lemma form — `look`, not `looked` — because that is how a dictionary files its
    /// keys, and the hovered index is always a literal word of the phrase rather than one of the reader's
    /// own words filling the slot.
    @Test(arguments: [
        ("they give the plan up eventually", 1, "give something up"),
        ("she look the unfamiliar word up", 5, "look something up"),
        ("bear the deadline in mind", 0, "bear something in mind"),
        ("bear the deadline in mind", 4, "bear something in mind"),
    ])
    func aSeparatedPhrasalVerbIsFound(sentence: String, word: Int, expected: String) {
        #expect(index().phrase(in: sentence.components(separatedBy: " "), containing: word) == expected)
    }

    /// **The nearest filling of the slot wins**, because a narrow gap is better evidence than a wide one.
    /// Both placements are valid here and only the tighter is what the reader met. Verified by inverting
    /// the gap comparison, which turns this red and nothing else.
    @Test func theNearestFillingOfTheSlotWins() {
        let words = ["we", "take", "care", "to", "take", "everything", "into", "account"]
        let found = index().match(in: words, containing: 7)
        #expect(found?.words == 4 ... 7)
        #expect(found?.gap == 1)
    }

    /// A trailing slot names no gap inside the phrase, so the template matches adjacent words like any
    /// other — and answers with the dictionary's spelling, which is the string that has the entry.
    @Test func aTrailingSlotIsAnOrdinaryContiguousPhrase() {
        let found = index().match(in: ["we", "account", "for", "the", "difference"], containing: 1)
        #expect(found?.phrase == "account for something")
        #expect(found?.words == 1 ... 2)
        #expect(found?.gap == 0)
    }

    /// **More of the phrase written out wins over a wider guess.** `give up the ghost` has four literal
    /// words against `give something up`'s two, and both are keys, so length settles it before the gap
    /// is even compared.
    @Test func theMoreLiteralPhraseBeatsTheSlottedOne() {
        #expect(index().phrase(in: ["they", "give", "up", "the", "ghost"], containing: 1)
            == "give up the ghost")
    }

    /// The gap is bounded, and the bound is the caller's to set — a narrow one refuses the long object
    /// rather than reporting it with a large `gap`.
    @Test func aGapWiderThanAllowedIsNotAMatch() {
        let words = "take what people think and other possible edge cases all into account"
            .components(separatedBy: " ")
        #expect(index().match(in: words, containing: 0, widestGap: 3) == nil)
        #expect(index().match(in: words, containing: 0, widestGap: 9)?.gap == 9,
                "and the boundary itself is inclusive")
    }

    /// A slot is filled by at least one word, so a template never matches the unslotted spelling — those
    /// are different keys with different entries, and `take into account` is not a key at all.
    @Test func aSlotIsNotAllowedToMatchNothing() {
        #expect(PhraseSpans(phrases: ["give something up"])
            .phrase(in: ["they", "give", "up"], containing: 1) == nil)
    }

    /// Slots around one literal word leave no phrase, so nothing is claimed.
    @Test func aTemplateOfOneLiteralWordIsNotAPhrase() {
        #expect(PhraseSpans(phrases: ["take something"])
            .phrase(in: ["take", "it", "along"], containing: 0) == nil)
    }

    /// **The class the dictionary does not mark.** NOAD files `turn down` bare, so *turn the offer down*
    /// is only findable by inferring that `down` is a particle a reader may move — and the answer says so,
    /// because a guess and a publisher's slot are not the same evidence.
    @Test func aBarePhrasalVerbIsBrokenOnlyByInference() {
        let found = index().match(in: ["they", "turn", "the", "offer", "down"], containing: 1)
        #expect(found?.phrase == "turn down")
        #expect(found?.words == 1 ... 4)
        #expect(found?.separation == .inferred(2))
    }

    /// Written unbroken, nothing is inferred, and the answer says that too.
    @Test func anUnbrokenPhrasalVerbIsNotAnInference() {
        let found = index().match(in: ["they", "turn", "down", "the", "offer"], containing: 1)
        #expect(found?.separation == PhraseSpans.Separation.none)
        #expect(found?.gap == 0)
    }

    /// A publisher's slot is trusted far; an inference is not. The same nine-word gap that
    /// `take something into account` is allowed would be refused here.
    @Test func anInferredGapIsHeldTighterThanAMarkedOne() {
        let split = "turn what people think and every other possibility down".components(separatedBy: " ")
        #expect(index().match(in: split, containing: 0) == nil,
                "seven words is past the inferred cap, though a marked slot would allow it")
        let marked = "take what people think and other possible edge cases all into account"
            .components(separatedBy: " ")
        #expect(index().match(in: marked, containing: 0)?.separation == .marked(9))
    }

    /// **A prepositional particle is not separable, and is left out of the set on purpose.** `look after`
    /// must not match *look* at the child *after* lunch — the single likeliest false positive of the whole
    /// inference, which is why `after` is absent from `particles`.
    @Test func aPrepositionalPhrasalVerbIsNotBrokenApart() {
        let words = ["look", "at", "the", "child", "after", "lunch"]
        #expect(index().match(in: words, containing: 0) == nil)
        #expect(index().match(in: ["look", "after", "the", "child"], containing: 0)?.phrase
            == "look after", "while the unbroken phrase is still found")
    }

    /// A phrase readable unbroken is never reported as a guessed split — **enforced by the gap ordering,
    /// not by the short-circuit**: a zero gap is the smallest there is, so the contiguous reading wins the
    /// ranking whether or not the inferred pass also ran. Skipping that pass is an optimisation, and this
    /// test deliberately does not claim to check it.
    @Test func anUnbrokenReadingIsNeverGivenUpForAnInferredOne() {
        let words = ["give", "away", "the", "prize", "and", "give", "away", "again"]
        #expect(index().match(in: words, containing: 1)?.separation == PhraseSpans.Separation.none)
    }

    /// Only a two-word verb is inferred apart. Breaking a longer phrase the publisher wrote whole is a
    /// guess too far, and the set of things it could match is too large to be worth a candidate.
    @Test func aLongerContiguousPhraseIsNeverInferredApart() {
        #expect(PhraseSpans(phrases: ["give up the ghost"])
            .match(in: ["they", "give", "the", "thing", "up", "the", "ghost"], containing: 1) == nil)
    }
}
