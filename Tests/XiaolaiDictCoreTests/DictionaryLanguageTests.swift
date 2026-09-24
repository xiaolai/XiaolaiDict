import Testing

@testable import XiaolaiDictCore

/// Reading a dictionary's declared languages, and the script probe that covers the bundles which
/// declare none.
struct DictionaryLanguageTests {
    /// 牛津英汉汉英词典's second pair, as read off the bundle on 2026-09-22.
    private let oxfordChinese = DictionaryLanguages(index: "en", explains: "zh_CN")

    @Test func theEnglishHalfOfABilingualIsWhatAChineseReaderWants() {
        #expect(oxfordChinese.indexesEnglish(explainedIn: "zh_CN"))
    }

    /// Apple writes `zh_CN`; `Locale.preferredLanguages` answers `zh-Hans-CN`. A reader's list
    /// carries a script and a region their dictionary never mentions, so the comparison is on the
    /// primary subtag or it never matches at all.
    @Test func aReadersOwnTagMatchesTheBundlesShorterOne() {
        #expect(oxfordChinese.indexesEnglish(explainedIn: "zh-Hans-CN"))
        #expect(oxfordChinese.indexesEnglish(explainedIn: "zh"))
    }

    /// NOAD is `en_US → en_US`, which is English explained in English — the right answer for an
    /// English reader and the wrong one for everybody else.
    @Test func noADIndexesEnglishAndExplainsInIt() {
        let noad = DictionaryLanguages(index: "en_US", explains: "en_US")
        #expect(noad.indexesEnglish(explainedIn: "en"))
        #expect(!noad.indexesEnglish(explainedIn: "zh_CN"))
    }

    /// The Chinese-into-Chinese half of the same bundle. It explains in the right language and
    /// indexes the wrong one, which is exactly the pair a reader studying English does not want.
    @Test func theChineseHalfIsNotTheOneForStudyingEnglish() {
        let intoChinese = DictionaryLanguages(index: "zh_CN", explains: "zh_CN")
        #expect(!intoChinese.indexesEnglish(explainedIn: "zh_CN"))
    }

    /// Simplified and Traditional are different dictionaries, and Foundation is what tells them
    /// apart: it resolves `zh_CN` to Hans and `zh_TW` to Hant although neither writes the script
    /// down. Both are enabled on the development Mac, so without this a Simplified reader would be
    /// offered 譯典通 as an equally good candidate and the proposal would be a coin toss.
    @Test func traditionalIsNotOfferedToASimplifiedReader() {
        let traditional = DictionaryLanguages(index: "en", explains: "zh_TW")
        #expect(!traditional.indexesEnglish(explainedIn: "zh-Hans-CN"))
        #expect(traditional.indexesEnglish(explainedIn: "zh-Hant-TW"))
    }

    /// Region is not compared: `en_US` and `en_GB` are one reader's language, and a Singapore
    /// reader writing `zh-Hans-SG` still wants the `zh_CN` dictionary.
    @Test func regionDoesNotSeparateAReaderFromTheirDictionary() {
        #expect(oxfordChinese.indexesEnglish(explainedIn: "zh-Hans-SG"))
        let noad = DictionaryLanguages(index: "en_US", explains: "en_US")
        #expect(noad.indexesEnglish(explainedIn: "en_GB"))
    }

    @Test func everyProbeWordHasAScript() {
        // Mirrors `DictionaryBridge.probeWords`. A word with no script would be probed and its
        // answer silently dropped.
        for word in ["fine", "hold", "water", "水", "人", "하다", "する"] {
            #expect(ProbeScript.of(word) != nil, "no script for \(word)")
        }
    }

    @Test func theProbeWordsCoverTheScriptsThatSeparateTheLanguages() {
        #expect(ProbeScript.of("fine") == .latin)
        #expect(ProbeScript.of("水") == .han)
        #expect(ProbeScript.of("하다") == .hangul)
        // Kana, not han: 水 and する together are Japanese where 水 alone is Chinese, and that is
        // the only reason both are asked.
        #expect(ProbeScript.of("する") == .kana)
    }

    /// **`of` reads the first scalar, and that is right for a probe word and wrong for a captured
    /// one.** The probe words are single-script by construction — `DictionaryBridge.probeWords`
    /// chooses them that way — so the first character settles it. A word the reader rested on is
    /// whatever was on their screen: it can open with a quotation mark, a digit, or an opening
    /// bracket, and it can mix scripts. Reusing `of` there would have silently extended its job.
    @Test func theFirstScalarClassifierIsNotEnoughForCapturedText() {
        #expect(ProbeScript.of("“hold”") == nil, "the first scalar is punctuation, not a script")
        #expect(ProbeScript.dominant(in: "“hold”") == .latin)
        #expect(ProbeScript.of("3D") == nil)
        #expect(ProbeScript.dominant(in: "3D") == .latin)
    }

    /// Letters decide; everything else is ignored rather than counted as a script of its own.
    @Test func punctuationDigitsAndSpacesDoNotVote() {
        #expect(ProbeScript.dominant(in: "well-being") == .latin)
        #expect(ProbeScript.dominant(in: "第 3 章") == .han)
        #expect(ProbeScript.dominant(in: "") == nil)
        #expect(ProbeScript.dominant(in: "…—·") == nil, "nothing but punctuation names no script")
        #expect(ProbeScript.dominant(in: "42") == nil, "a number is not written in a script")
    }

    /// **Any kana makes it Japanese, whatever the count of han.** This is the same fact the probe
    /// words exist for, applied the other way round: 水 alone is Chinese, and 水 beside する is
    /// Japanese. A majority vote would call 日本語を話す han, because the kanji outnumber nothing —
    /// here they do not, but `勉強する` is 3 han to 2 kana and would come out Chinese.
    @Test func anyKanaMakesItJapaneseHoweverManyHanThereAre() {
        #expect(ProbeScript.dominant(in: "勉強する") == .kana)
        #expect(ProbeScript.dominant(in: "水") == .han)
        #expect(ProbeScript.dominant(in: "日本語") == .han, "kanji with no kana is indistinguishable from Chinese")
    }

    /// **Latin is not ASCII**, and a range that stopped at `z` would leave the European words this
    /// filter exists to let through unclassified — which reads to the reader as the filter being
    /// broken rather than as a gap in a range. The two division signs inside that block are
    /// symbols and must not vote.
    /// **The fixture has to be letters the ASCII range cannot reach.** Written with *naïve* and
    /// *café* this passed with the Latin-1 range deleted — four ASCII letters outvote one accented
    /// one, so it answered `.latin` either way and could not fail for the reason it is named
    /// after. Verified by deleting the range and watching it stay green.
    @Test func latinReachesPastAscii() {
        #expect(ProbeScript.dominant(in: "çà") == .latin, "every letter here is past ASCII")
        #expect(ProbeScript.dominant(in: "ÀÉÎÕÜ") == .latin)
        // These two only prove the accented letters do not *break* an otherwise ASCII word; they
        // are kept as the realistic case, not as the check.
        #expect(ProbeScript.dominant(in: "naïve") == .latin)
        #expect(ProbeScript.dominant(in: "Grüße") == .latin)
        #expect(ProbeScript.dominant(in: "×÷") == nil, "a division sign is a symbol, not a letter")
    }

    /// **Punctuation inside a script's block is not that script.** `U+30FB ・` sits in the
    /// Katakana block and is a separator, so a range-only classifier counted it as kana — and
    /// because any kana absorbs han, `水・` came back Japanese. A reader studying Chinese would
    /// have had it refused and filed under a script they had not ticked. Letterhood is asked of
    /// Unicode now, not inferred from a block.
    @Test func punctuationInsideAScriptsBlockDoesNotVote() {
        #expect(ProbeScript.dominant(in: "水・") == .han)
        #expect(ProbeScript.dominant(in: "・") == nil)
        #expect(ProbeScript.dominant(in: "。、「」") == nil)
        // The prolonged sound mark *is* a letter and stays kana: ラーメン is one word.
        #expect(ProbeScript.dominant(in: "ラーメン") == .kana)
    }

    /// **A script this cannot name is a word that escapes the filter**, because unclassified text
    /// is deliberately looked up. So the coverage gaps were not cosmetic: halfwidth katakana, the
    /// han beyond the basic plane, and Latin past `0x024F` all answered nil and walked straight
    /// through a filter set to exclude them.
    @Test func theScriptsAreRecognisedWhereverUnicodePutsThem() {
        #expect(ProbeScript.dominant(in: "ｶﾀｶﾅ") == .kana, "halfwidth katakana")
        #expect(ProbeScript.dominant(in: "𠮷") == .han, "han beyond the basic plane")
        #expect(ProbeScript.dominant(in: "ế") == .latin, "Latin Extended Additional")
        #expect(ProbeScript.dominant(in: "Ɓ") == .latin, "Latin Extended-B")
        #expect(ProbeScript.dominant(in: "ﾊﾝｸﾞﾙ") == .kana)
        #expect(ProbeScript.dominant(in: "한글") == .hangul)
    }

    /// **One word must not classify two ways depending on how it was typed.** Composed `ế` is a
    /// single scalar and decomposed `ế` is `e` plus two combining marks; before normalising, the
    /// first answered nil and the second Latin. A capture from the screen can be either.
    @Test func composedAndDecomposedTextAgree() {
        let composed = "ế"
        let decomposed = "e\u{0302}\u{0301}"
        // **Compared as scalars, not as strings.** Swift's `String` equality is canonical, so the
        // two compare equal and `composed != decomposed` is false — the premise has to be stated
        // at the level the classifier actually reads.
        #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars),
                "the fixture must actually differ, or this proves nothing")
        #expect(ProbeScript.dominant(in: composed) == ProbeScript.dominant(in: decomposed))
        #expect(ProbeScript.dominant(in: composed) == .latin)
    }

    /// `of` and `dominant` differ in how they *traverse*, never in what a scalar is. They shared a
    /// switch by copy at first, and the copies had already drifted — `of` was missing every range
    /// the other had gained.
    @Test func bothClassifiersAgreeAboutWhatAScalarIs() {
        for word in ["fine", "水", "하다", "する", "ế", "𠮷"] {
            #expect(ProbeScript.of(word) == ProbeScript.dominant(in: word), "disagreed about \(word)")
        }
    }

    /// **A block named for a script still holds other scripts' letters.** `U+AB65 ꭥ` is GREEK
    /// LETTER SMALL CAPITAL OMEGA and it lives in *Latin* Extended-E — so widening the Latin
    /// ranges to cover `ế` swept it in, and a Latin-only reader would have had Greek looked up and
    /// filed under Latin. Verified against the character's own Unicode name. The lesson is the one
    /// that made `・` kana: a block is a range of code points, not a statement about script.
    @Test func aBlockNamedForOneScriptCanHoldAnother() {
        #expect(ProbeScript.dominant(in: "\u{AB65}") == nil, "Greek inside Latin Extended-E")
    }

    /// **Compatibility normalisation is what stops the block list growing for ever.** Ligatures,
    /// halfwidth kana and fullwidth Latin are the same letters wearing presentation forms, and
    /// folding them first removes three whole families of gaps instead of chasing them one block
    /// at a time — which is what the first two rounds of this classifier did.
    @Test func presentationFormsFoldToTheLettersTheyAre() {
        #expect(ProbeScript.dominant(in: "ﬀ") == .latin, "the ff ligature is two Latin letters")
        #expect(ProbeScript.dominant(in: "ｶﾀｶﾅ") == .kana, "halfwidth katakana")
        #expect(ProbeScript.dominant(in: "ＡＢＣ") == .latin, "fullwidth Latin")
        #expect(ProbeScript.dominant(in: "㌍") == .kana, "a squared katakana word")
    }

    /// Kana past the original blocks. These do not decompose, so normalisation cannot reach them
    /// and the blocks have to be named.
    @Test func kanaBeyondTheOriginalBlocksIsStillKana() {
        #expect(ProbeScript.dominant(in: "\u{1B001}") == .kana, "Kana Supplement")
        #expect(ProbeScript.dominant(in: "\u{1B150}") == .kana, "Small Kana Extension")
    }

    /// A mixed capture takes the script most of its letters are in. The case this is for is a word
    /// picked up with a stray neighbour — OCR returning `the 水` — where refusing to classify at
    /// all would be worse than naming the majority.
    @Test func amongLettersTheMajorityScriptWins() {
        #expect(ProbeScript.dominant(in: "the 水") == .latin)
        #expect(ProbeScript.dominant(in: "水水 a") == .han)
        #expect(ProbeScript.dominant(in: "하다 a") == .hangul)
    }

    @Test func aDictionaryDeclaringNothingTeachesNobodyByMetadata() {
        let sideloaded = DictionaryCapability(
            identity: DictionaryIdentity(name: "Longman"), senseKeyKind: .position, probed: true,
            languages: [], indexes: [.latin])
        // It does index English. What it explains in is unknowable from a records probe, and
        // guessing "English" would make every sideloaded bilingual a monolingual.
        #expect(!sideloaded.teachesEnglish(to: "en"))
        #expect(!sideloaded.teachesEnglish(to: "zh_CN"))
    }
}
