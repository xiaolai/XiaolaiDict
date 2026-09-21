import Foundation
import XiaolaiDictCore
import Testing

/// The structural narrowing every rung gets: a word used as a noun cannot mean a verb sense.
///
/// The labels are the ones the installed dictionaries actually print, measured 2026-09-21 across
/// twelve ambiguous words: NOAD and the Writer's Thesaurus print `noun`, `verb`, `adjective`,
/// `adverb`; 牛津英汉汉英 prints `transitive verb`, `intransitive verb`, `impersonal verb`,
/// `plural noun`, `adverb phrase` beside the plain ones; 譯典通 prints `n.`, `vt.`, `vi.`, `a.`,
/// `ad.` and nothing else.
///
/// **A subtype of a part of speech is that part of speech.** `plural noun` is where 牛津 files the
/// sense of *sanction* the reader most often meets — "sanctions against the regime" — and
/// *water*'s "the waters", *content*'s "contents", *rain*'s "the rains". Dropping those senses
/// because their label is two words long is the filter emptying the field of the right answer,
/// which is the one thing it is written not to do.
struct PartOfSpeechFilterTests {
    private func candidates(_ labels: [String?]) -> [SenseCandidate] {
        labels.enumerated().map { index, label in
            SenseCandidate(
                entryID: "e1", key: "1.\(index + 1)", keyKind: .position,
                text: "sense \(index + 1)", partOfSpeech: label)
        }
    }

    private func kept(_ labels: [String?], _ tagged: String?) -> [String?] {
        PartOfSpeechFilter.narrow(candidates(labels), to: tagged).map(\.partOfSpeech)
    }

    /// *sanction* in 牛津: `noun`, `plural noun`, `transitive verb`. The reader's word is a noun,
    /// and both noun blocks are noun blocks.
    @Test func aPluralNounIsANoun() {
        #expect(kept(["noun", "plural noun", "transitive verb"], "noun") == ["noun", "plural noun"])
    }

    /// The same shape in the other direction, and the one that would be missed by a rule matching
    /// only where *nothing* plain is present: *run* in 牛津 has a plain `noun` block, so the
    /// filter does find a match and has no reason to fall open.
    @Test func aTransitiveVerbIsAVerb() {
        #expect(kept(["verb", "transitive verb", "intransitive verb", "noun"], "verb")
            == ["verb", "transitive verb", "intransitive verb"])
    }

    /// **And the reason this is matched by word rather than by substring**: `adverb` contains
    /// `verb`, and an adverb sense is not a verb sense. This is the same rule the entry parser
    /// follows for `x_xd1sub` inside `x_xd1`.
    @Test func anAdverbIsNotAVerb() {
        #expect(kept(["verb", "adverb", "adverb phrase"], "verb") == ["verb"])
        #expect(kept(["verb", "adverb", "adverb phrase"], "adverb") == ["adverb", "adverb phrase"])
    }

    /// 譯典通 labels its blocks `n.` and `vt.`, which say the same thing in a vocabulary XiaolaiDict does
    /// not read. Nothing matches, so nothing is narrowed — the selector sees the whole entry and
    /// decides on the sentence alone. Inert rather than wrong, and this is what makes it inert.
    @Test func aVocabularyTheFilterCannotReadNarrowsNothing() {
        #expect(kept(["n.", "vt.", "vi."], "noun") == ["n.", "vt.", "vi."])
    }

    /// The tagger does not always commit, and a guessed part of speech would rule out the right
    /// sense as confidently as the wrong ones.
    @Test func noPartOfSpeechNarrowsNothing() {
        #expect(kept(["noun", "verb"], nil) == ["noun", "verb"])
        #expect(kept(["noun", "verb"], "") == ["noun", "verb"])
    }

    /// A sense whose block carried no label at all is not ruled out by a label it does not have.
    /// It is kept only when nothing matches — which is the existing fall-open, stated.
    @Test func anUnlabelledBlockIsKeptOnlyWhenNothingMatches() {
        #expect(kept(["noun", nil], "noun") == ["noun"])
        #expect(kept([nil, nil], "noun") == [nil, nil])
    }
}
