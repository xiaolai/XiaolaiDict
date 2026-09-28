/// Traditional Chinese. **No Oxford-authored bilingual exists for it.**
///
/// 譯典通 is © INVENTEC / INVENTEC BESTA "under licence to Oxford University Press" — Apple's
/// distribution arrangement, not authorship. Worth stating plainly because the identifier suffix
/// (`.DrEye`) is the only place the real publisher shows, and a pitch built on "Oxford dictionaries"
/// would be wrong here.
///
/// **No Traditional Chinese dictionary carries a usable sense id** — one on the sense block itself. The
/// idiom dictionary has ids, but below the sense block, which is not a name for the sense. Measured
/// through the indexer at 0% of senses. Every sense here is keyed by `SenseKey`'s content form.
public enum TraditionalChinese: LanguageAdapter {
    public static let language = "zh-Hant"
    public static let dictionaries: [DictionaryDescriptor] = [
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_TW-en.DrEye",
            title: "譯典通英漢雙向字典 / Dr. Eye Chinese English Bilingual Dictionary",
            kind: .bilingual, author: "INVENTEC / INVENTEC BESTA", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_TW.wn",
            title: "五南國語活用辭典",
            kind: .monolingual, author: "五南圖書出版", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_HK.common",
            title: "商務新詞典（全新版）",
            kind: .thesaurus, author: "商務印書館", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_HK-en.idioms.cp",
            title: "漢英對照成語詞典",
            kind: .idioms, author: "商務印書館", senseIDAttribute: nil),
    ]
}
