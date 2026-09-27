/// Cantonese. **Partly Oxford: one bundle, two works.**
///
/// 牛津粵英雙語詞典 carries both the ABC Cantonese-English Comprehensive Dictionary (© Wenlin
/// Institute, under licence to OUP) *and* the Oxford English-English-Cantonese Dictionary (© Oxford
/// University Press). So the Oxford half is genuinely Oxford and the other half is not.
///
/// The colloquialisms dictionary is 1 MB and is the one a learner reading real Cantonese wants; it
/// carries no sense ids. Both are gated to HK and MO, so a Mac outside those regions has neither
/// until its languages are changed.
public enum Cantonese: LanguageAdapter {
    public static let language = "yue"
    public static let dictionaries: [DictionaryDescriptor] = [
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.yue-en.oup",
            title: "牛津粵英雙語詞典 — ABC Cantonese-English + Oxford English-English-Cantonese",
            kind: .bilingual,
            author: "Wenlin Institute and Oxford University Press", senseIDAttribute: "id"),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.yue-en.cp",
            title: "英譯廣東口語詞典 / Cantonese Colloquialisms in English",
            kind: .bilingual, author: "商務印書館", senseIDAttribute: nil),
    ]
}
