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

    /// Simplified and Traditional both reduce to `zh`, deliberately. 譯典通 is `zh_TW` and
    /// 牛津英汉汉英词典 is `zh_CN`, and treating a second Chinese dictionary as a genuine rival is what
    /// sends the question to the reader instead of settling it with a coin toss.
    @Test func theScriptIsNotUsedToSeparateTwoChineseDictionaries() {
        let traditional = DictionaryLanguages(index: "en", explains: "zh_TW")
        #expect(traditional.indexesEnglish(explainedIn: "zh_CN"))
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
