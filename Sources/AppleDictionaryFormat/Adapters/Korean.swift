/// Korean. **Not Oxford.** 뉴에이스 is © DIOTEK, under licence to Oxford University Press.
///
/// **Neither bundle carries a usable sense id**, meaning one on the sense block itself. A probe counting
/// elements at any depth that hold both an `id` and a definition says they do; an id on a deeper element
/// is not a name for the sense. Measured through the indexer: **0% of senses for the monolingual and 1%
/// for the bilingual** — not a categorical zero, and the residue is why the test asserts a threshold
/// rather than absence. Both are keyed by `SenseKey`'s content form.
///
/// The monolingual is the largest single dictionary in
/// Apple's catalogue by download size (83 MB) and holds 331,403 entries, so a rebuild over it is the
/// slowest of the five and worth reporting progress on.
public enum Korean: LanguageAdapter {
    public static let language = "ko"
    public static let dictionaries: [DictionaryDescriptor] = [
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.ko-en.NewAce",
            title: "뉴에이스 영한사전 / 뉴에이스 한영사전",
            kind: .bilingual, author: "DIOTEK", senseIDAttribute: nil),
        DictionaryDescriptor(
            identifier: "com.apple.dictionary.ko.NewAce",
            title: "뉴에이스 국어사전",
            kind: .monolingual, author: "DIOTEK", senseIDAttribute: nil),
    ]
}
