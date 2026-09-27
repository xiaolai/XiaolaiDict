/// Japanese. **Not Oxford.** ウィズダム is © Sanseido and 大辞林 © Sanseido, both under licence to
/// Oxford University Press — Apple's arrangement, not authorship.
///
/// ウィズダム carries publisher ids; 大辞林 and the Crown Chinese-Japanese pair carry none, so their
/// senses are keyed by content. The Crown pair is listed here because Apple ships it to both JP and CN,
/// which means a reader can have it without having either monolingual.
public enum Japanese: LanguageAdapter {
    public static let language = "ja"
    public static let dictionaries: [DictionaryDescriptor] = [
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.ja-en.WISDOM",
            title: "ウィズダム英和辞典 / ウィズダム和英辞典",
            kind: .bilingual, author: "Sanseido", senseIDAttribute: "id"),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.ja.Daijirin",
            title: "スーパー大辞林",
            kind: .monolingual, author: "Sanseido", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.zhs-ja.Crown",
            title: "超級クラウン中日辞典 / クラウン日中辞典",
            kind: .bilingual, author: "Sanseido", senseIDAttribute: nil),
    ]
}
