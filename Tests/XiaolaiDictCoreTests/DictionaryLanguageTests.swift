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
