/// Simplified Chinese. **The only one of the five with a genuinely Oxford-authored bilingual.**
///
/// 牛津英汉汉英词典 is © Oxford University Press *and* Foreign Language Teaching and Research
/// Publishing — Oxford as author, not merely as Apple's licensor. It is also the richest of the five
/// for this tool's purpose, and the only one of the five languages whose senses carry `lexid`. It is
/// not the only CJK dictionary with a publisher id — 牛津粵英雙語詞典 carries `id`; see `Cantonese`.
///
/// **136,288 entry records** in the installed bundle, measured by reading it. An earlier version of
/// this note said 68,123 entries and 104,734 senses; those came from a different project's database of
/// the same dictionary, not from the bundle, and did not match it.
///
/// Its package name is the generic `Simplified Chinese - English.dictionary`, which is exactly why
/// nothing here keys off a file name.
public enum SimplifiedChinese: LanguageAdapter {
    public static let language = "zh-Hans"
    public static let dictionaries: [DictionaryDescriptor] = [
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_CN-en.OCD",
            title: "牛津英汉汉英词典 / Oxford Chinese Dictionary",
            kind: .bilingual,
            author: "Oxford University Press and Foreign Language Teaching and Research Publishing",
            senseIDAttribute: "lexid"),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_CN.SDCC",
            title: "现代汉语规范词典",
            kind: .monolingual, author: "外语教学与研究出版社", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_CN.thes",
            title: "现代汉语同义词典",
            kind: .thesaurus, author: "商务印书馆", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zh_CN.idioms",
            title: "汉语成语词典",
            kind: .idioms, author: "商务印书馆", senseIDAttribute: nil),
    ]
}
