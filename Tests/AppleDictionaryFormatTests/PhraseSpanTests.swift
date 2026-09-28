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
}
