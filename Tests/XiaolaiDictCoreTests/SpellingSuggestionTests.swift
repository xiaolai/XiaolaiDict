import DictionaryModel
import Testing
import XiaolaiDictBase
import XiaolaiDictCore

/// **When a miss may be offered "Did you mean …?", and when an offer is believed** — the rules of
/// plan-spelling-suggestion §3, as values, decided before any checker or dictionary is asked.
///
/// The order a refusal is decided in is part of the rule: the outcome first, because a word that was found, or a
/// question the service never answered, is not a spelling problem whatever its shape.
struct SpellingEligibilityTests {
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    /// **The one case that is asked about**: the service's own miss, of one Latin word.
    @Test(arguments: ["teh", "recieve", "Clairvoyent", "o'clock", "well-knwon", "don’t", "café"])
    func aMissOfOneLatinWordIsEligible(term: String) {
        #expect(SpellingEligibility.of(term: term, outcome: Self.miss) == .eligible)
    }

    /// **A miss only because the service could not be asked is not a spelling problem** — the card already says the
    /// dictionaries could not all be asked, and a suggestion under it would read as a confirmed absence.
    @Test func aMissTheServiceDidNotAnswerIsRefused() {
        #expect(SpellingEligibility.of(term: "teh", outcome: .notFound(serviceFailure: "the service crashed"))
                == .refused(.serviceUnanswered))
        // An empty reason is still a reason: the service was not the one that answered.
        #expect(SpellingEligibility.of(term: "teh", outcome: .notFound(serviceFailure: ""))
                == .refused(.serviceUnanswered))
    }

    /// **Anything but a miss is refused**: a word found, prose from the public fallback, and a lookup still waiting.
    @Test func anythingButAMissIsRefused() throws {
        let entry = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"), headword: "teh", lookedUp: "teh",
            html: "<p/>", document: nil)
        let found = LookupOutcome.entries(try #require(NonEmpty([entry])), unreadable: [])
        for outcome in [found, .plainText("an article", serviceFailure: "crashed"), nil] as [LookupOutcome?] {
            #expect(SpellingEligibility.of(term: "teh", outcome: outcome)
                    == .refused(.notAMiss), "\(String(describing: outcome)) was offered a suggestion")
        }
    }

    /// **A phrase, or nothing at all, is not one word** — "Did you mean" for phrases is not in this plan (§6).
    @Test(arguments: ["take off", "teh cat", "", "   ", "a\tb", "line\nbreak"])
    func moreThanOneWordOrNoneIsRefused(term: String) {
        #expect(SpellingEligibility.of(term: term, outcome: Self.miss) == .refused(.notOneWord))
    }

    /// **Never CJK, and never anything that is not Latin letters** — a number, a symbol, a digit inside a word (`l0ve`
    /// is an OCR confusion the checker has no answer for), Hangul, kana, han, or Latin with another script mixed in.
    /// The study scripts are scripts (ADR-0001), and the checker is asked in English.
    @Test(arguments: ["水", "勉強する", "한국어", "1234", "l0ve", "%", "teh水", "'teh", "teh-", "—", "ｔｅｈ水"])
    func anythingButLatinLettersIsRefused(term: String) {
        #expect(SpellingEligibility.of(term: term, outcome: Self.miss)
                == .refused(.notLatinLetters))
    }

    /// **Fullwidth Latin is Latin** — compatibility-normalised before it is read, as `ProbeScript` reads a capture.
    @Test func fullwidthLatinIsLatin() {
        #expect(SpellingEligibility.of(term: "ｔｅｈ", outcome: Self.miss) == .eligible)
    }

    /// **The outcome is decided first.** A found phrase is "not a miss", never "not one word": a refusal names the
    /// reason that decided it, and the instrument prints that reason.
    @Test func theOutcomeIsDecidedBeforeTheShape() {
        #expect(SpellingEligibility.of(term: "take off", outcome: .notFound(serviceFailure: "x"))
                == .refused(.serviceUnanswered))
        #expect(SpellingEligibility.of(term: "水", outcome: nil) == .refused(.notAMiss))
    }
}

/// **What the checker said, and what the dictionaries said about it** — the two filters between a correction and a
/// line on the card.
struct SpellingCorrectionTests {
    /// **The checker's word, unless it is no word or the term again up to case** (§3).
    @Test func aCorrectionIsACandidateUnlessItIsTheTermAgain() {
        #expect(SpellingCorrection.candidate("the", for: "teh") == "the")
        #expect(SpellingCorrection.candidate("The", for: "Teh") == "The", "the checker's own capitalisation is kept")
        #expect(SpellingCorrection.candidate(" receive ", for: "recieve") == "receive")
        #expect(SpellingCorrection.candidate(nil, for: "teh") == nil)
        #expect(SpellingCorrection.candidate("", for: "teh") == nil)
        #expect(SpellingCorrection.candidate("  ", for: "teh") == nil)
        #expect(SpellingCorrection.candidate("Ephemeral", for: "ephemeral") == nil, "the term again, up to case")
        #expect(SpellingCorrection.candidate("ÉTÉ", for: "été") == nil, "case folds outside ASCII too")
        // Case only: an accent the reader left out is a correction.
        #expect(SpellingCorrection.candidate("café", for: "cafe") == "café")
    }

    private static func entry(_ headword: String?, lookedUp: String) -> DictionaryEntry {
        DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"), headword: headword,
                        lookedUp: lookedUp, html: "<p/>", document: nil)
    }

    private static func found(_ entries: DictionaryEntry...) throws -> LookupOutcome {
        .entries(try #require(NonEmpty(entries)), unreadable: [])
    }

    /// **Offered only where the reader's dictionaries have the word** (§2, conclusion 2): an entry headed by it, or by
    /// its dictionary form. The checker knowing a word says nothing about the dictionaries.
    @Test func aWordIsVerifiedByAnEntryHeadedByItOrItsDictionaryForm() throws {
        let exact = Self.entry("receive", lookedUp: "receive")
        #expect(exact.match == .exact, "the fixture must be the exact case")
        #expect(SpellingCorrection.isVerified(try Self.found(exact)))
        let form = Self.entry("receive", lookedUp: "received")
        #expect(form.match == .dictionaryForm, "the fixture must be the dictionary-form case")
        #expect(SpellingCorrection.isVerified(try Self.found(form)))
    }

    /// **Another headword is a near match, not the word**, and a dictionary that did not say which headword it answered
    /// with has said nothing about this one. Either alone verifies nothing; beside an exact entry, the exact one does.
    @Test func aNearMatchOrAnUnknownHeadwordVerifiesNothing() throws {
        let near = Self.entry("rice", lookedUp: "receive")
        #expect(near.match == .otherHeadword, "the fixture must be the near-match case")
        let unknown = Self.entry(nil, lookedUp: "receive")
        #expect(unknown.match == .headwordUnknown, "the fixture must be the unknown-headword case")
        #expect(!SpellingCorrection.isVerified(try Self.found(near)))
        #expect(!SpellingCorrection.isVerified(try Self.found(unknown)))
        #expect(!SpellingCorrection.isVerified(try Self.found(near, unknown)))
        #expect(SpellingCorrection.isVerified(try Self.found(near, Self.entry("receive", lookedUp: "receive"))))
    }

    /// **A miss, a fallback's prose, or a service that could not be asked verifies nothing**: no suggestion beats one
    /// nobody checked.
    @Test func noEntryVerifiesNothing() {
        #expect(!SpellingCorrection.isVerified(.notFound(serviceFailure: nil)))
        #expect(!SpellingCorrection.isVerified(.notFound(serviceFailure: "crashed")))
        #expect(!SpellingCorrection.isVerified(.plainText("to get something", serviceFailure: "crashed")))
    }
}
