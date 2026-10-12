import Testing
import XiaolaiDictCore

/// **Which English the checker is asked in** (plan-spelling-suggestion §2, conclusion 3): `modernisation` is a typo to
/// an American checker and a word to a British one, so the reader's own English decides — where it is known.
struct SpellingLanguageTests {
    /// The languages `NSSpellChecker` listed on the development Mac, 2026-10-09: no `en_US`, which is plain `en`.
    private static let available = ["en", "en_CA", "en_PH", "en_GB", "en_AU", "en_IN", "en_SG", "en_ZA", "en_NZ", "en_JP",
                                    "fr", "de"]

    /// **The first English the reader lists, as they list it** — a Chinese reader who reads British English is asked in
    /// British English — and nil where they list none, which is plain English.
    @Test func theReadersEnglishIsTheFirstEnglishTheyList() {
        #expect(SpellingLanguage.readers(["zh-Hans-CN", "en-GB", "en-US"]) == "en-GB")
        #expect(SpellingLanguage.readers(["en-US", "en-GB"]) == "en-US")
        #expect(SpellingLanguage.readers(["en"]) == "en")
        #expect(SpellingLanguage.readers(["zh-Hans-CN", "ja-JP"]) == nil)
        #expect(SpellingLanguage.readers([]) == nil)
    }

    /// **The reader's variant where the checker has it; plain English where it does not.** `en-US` is not a checker
    /// language of its own here — plain `en` is American — and a region the checker does not carry is plain English too.
    @Test func theCheckerIsAskedInTheVariantItHasOrInPlainEnglish() {
        #expect(SpellingLanguage.checker(for: "en-GB", available: Self.available) == "en_GB")
        #expect(SpellingLanguage.checker(for: "en_AU", available: Self.available) == "en_AU", "either spelling of the tag")
        #expect(SpellingLanguage.checker(for: "en-US", available: Self.available) == "en")
        #expect(SpellingLanguage.checker(for: "en-IE", available: Self.available) == "en")
        #expect(SpellingLanguage.checker(for: "en", available: Self.available) == "en")
        #expect(SpellingLanguage.checker(for: nil, available: Self.available) == "en")
        // A language that is not English asks English: the checker is asked in English or not at all.
        #expect(SpellingLanguage.checker(for: "fr-FR", available: Self.available) == "en")
    }

    /// **American English is asked as plain `en`, even where the checker lists `en_US`.** Measured 2026-10-09 on the
    /// E2E Mac: inside the running app the checker listed 45 languages, `en_US` among them, and asked in `en_US` it
    /// answered nothing for `recieve`, `teh` or any typo; every other process listed 44, no `en_US`, asked plain `en` and
    /// answered `receive`. `en` is the checker's American English — the same answers wherever both could be asked — and
    /// `en_GB` inside the app answered as it should.
    @Test func americanEnglishIsAskedAsPlainEnglish() {
        let listed = ["en", "en_US", "en_GB", "fr"]
        #expect(SpellingLanguage.checker(for: "en-US", available: listed) == "en")
        #expect(SpellingLanguage.checker(for: "en_US", available: listed) == "en")
        #expect(SpellingLanguage.checker(for: "en-GB", available: listed) == "en_GB", "another variant is still asked")
        // A checker whose only English is `en_US` is still asked in it: nothing else would answer at all.
        #expect(SpellingLanguage.checker(for: "en-US", available: ["en_US"]) == "en_US")
    }

    /// **A checker with no English is not asked**, and one with only a variant is asked in that variant rather than in
    /// a language it does not have.
    @Test func aCheckerWithNoEnglishIsNotAsked() {
        #expect(SpellingLanguage.checker(for: nil, available: ["fr", "de"]) == nil)
        #expect(SpellingLanguage.checker(for: "en-GB", available: []) == nil)
        #expect(SpellingLanguage.checker(for: nil, available: ["fr", "en_GB"]) == "en_GB")
        #expect(SpellingLanguage.checker(for: "en-US", available: ["en_GB"]) == "en_GB")
    }
}
