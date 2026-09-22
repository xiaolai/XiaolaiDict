/// Which language a dictionary indexes, and which it explains in.
///
/// Apple's bundles declare this as `DCSDictionaryLanguages`, one entry per direction. 牛津英汉汉英词典
/// carries `zh_CN → zh_CN` **and `en → zh_CN`**: it defines Chinese for a Chinese reader, and it
/// defines English for one. That second pair is what a reader studying English wants, and it is
/// what makes "the dictionary for a reader of language L" an exact question rather than a guess —
/// index `en`, explain in L.
public struct DictionaryLanguages: Codable, Sendable, Equatable, Hashable {
    /// The language of the headwords — what is looked *up*. `en` for the English half of a
    /// bilingual, `en_US` for NOAD.
    public let index: String
    /// The language the entry is written in — what is *read*. `zh_CN` for both halves of
    /// 牛津英汉汉英词典.
    ///
    /// Named `explains` rather than `description`, which on a Swift type means something else
    /// entirely and would read as the bundle's own summary.
    public let explains: String

    public init(index: String, explains: String) {
        self.index = index
        self.explains = explains
    }

    /// Whether this pair is the one a reader of `language` wants for studying English: English
    /// headwords, explained in their own language.
    ///
    /// Compared on the language subtag alone, so `en_US` matches `en` and `zh_CN` matches
    /// `zh-Hans-CN`. Apple writes these with an underscore and `Locale.preferredLanguages` with a
    /// hyphen, and a reader's list carries a region their dictionary never mentions.
    public func indexesEnglish(explainedIn language: String) -> Bool {
        Self.subtag(index) == "en" && Self.subtag(explains) == Self.subtag(language)
    }

    /// The primary subtag, lowercased: `zh_CN` and `zh-Hans-CN` both reduce to `zh`.
    ///
    /// **This deliberately loses the script.** Simplified and Traditional Chinese are different
    /// dictionaries — 譯典通 is `zh_TW` and 牛津英汉汉英词典 is `zh_CN` — and reducing both to `zh` makes
    /// them equally good matches for a Simplified reader. That is on purpose at this layer: the
    /// rule this feeds answers "exactly one, or several" and a second Chinese dictionary is a
    /// genuine *several*, which is a question for the reader rather than a coin toss.
    static func subtag(_ tag: String) -> String {
        let cut = tag.prefix { $0 != "_" && $0 != "-" }
        return cut.lowercased()
    }
}

/// Which writing systems a dictionary actually answers in, measured rather than declared.
///
/// **Six of the seven dictionaries enabled on the development Mac declare no language at all** —
/// `DCSDictionaryLanguages` is absent from every sideloaded conversion, measured 2026-09-22 across
/// Cambridge, Collins COBUILD, both Longmans, Merriam-Webster and Oxford Collocation. So metadata
/// alone leaves most of a reader's list unclassified, while what a dictionary *answers* is a fact
/// about it that no bundle can omit.
///
/// Han and kana are probed separately because together they are Japanese and han alone is Chinese.
/// That distinction is the only reason to ask two questions instead of one.
///
/// **This says what a dictionary indexes, never what it explains in.** A sideloaded English
/// monolingual and a sideloaded English-Chinese bilingual both answer `latin`, and nothing in a
/// records probe can separate them. The rule that consumes this treats an unknown explanation as
/// unknown rather than guessing at English.
public enum ProbeScript: String, Codable, Sendable, CaseIterable, Comparable {
    case latin
    case han
    case hangul
    case kana

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The script a probe word is written in. Every word in `DictionaryBridge.probeWords` must map
    /// to one, which `everyProbeWordHasAScript` holds.
    public static func of(_ word: String) -> ProbeScript? {
        guard let first = word.unicodeScalars.first else { return nil }
        switch first.value {
        case 0x3040...0x30FF: return .kana
        case 0x1100...0x11FF, 0xAC00...0xD7AF: return .hangul
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .han
        case 0x0041...0x005A, 0x0061...0x007A: return .latin
        default: return nil
        }
    }
}
