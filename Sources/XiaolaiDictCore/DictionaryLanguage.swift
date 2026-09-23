import Foundation

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
    /// Compared through `Locale.Language`, which normalises Apple's underscores and supplies the
    /// script subtag neither side writes down. That matters here more than it looks: the two
    /// Chinese dictionaries enabled on the development Mac are `zh_CN` and `zh_TW`, and Foundation
    /// resolves those to **Hans and Hant** — so a Simplified reader is proposed 牛津英汉汉英词典 and
    /// not 譯典通. Reducing both to a bare `zh` would have made them equally good candidates and
    /// turned a correct proposal into a coin toss.
    ///
    /// Region is deliberately not compared. `en_US` and `en_GB` are the same reader's language, and
    /// a reader in Singapore whose list says `zh-Hans-SG` still wants the `zh_CN` dictionary.
    public func indexesEnglish(explainedIn language: String) -> Bool {
        Self.tag(index)?.languageCode?.identifier == "en" && Self.same(explains, language)
    }

    /// Whether two tags name the same language *and* script.
    static func same(_ a: String, _ b: String) -> Bool {
        guard let x = tag(a), let y = tag(b) else { return false }
        return x.languageCode == y.languageCode && x.script == y.script
    }

    /// Apple writes `zh_CN`; `Locale.preferredLanguages` answers `zh-Hans-CN`. One shape, or the
    /// comparison is between spellings rather than languages.
    static func tag(_ identifier: String) -> Locale.Language? {
        let normalised = identifier.replacingOccurrences(of: "_", with: "-")
        guard !normalised.isEmpty else { return nil }
        return Locale.Language(identifier: normalised)
    }
}

/// Which writing systems a dictionary actually answers in, measured rather than declared.
///
/// **No sideloaded conversion declares a language at all** — `DCSDictionaryLanguages` is absent
/// from all six installed on the development Mac, measured 2026-09-22 across Cambridge, Collins
/// COBUILD, both Longmans, Merriam-Webster and Oxford Collocation; three of those six are among
/// the seven enabled. Apple's own assets do declare — the bridge's
/// `appleAssetsDeclareTheirLanguagesAndSideloadedOnesDoNot` reads NOAD's and 牛津英汉汉英's off the
/// live bundles. So metadata alone leaves part of a reader's list unclassified, while what a
/// dictionary *answers* is a fact about it that no bundle can omit.
///
/// The count above is the *installed* sideloaded one. Among the **seven enabled**, the number that
/// declare nothing is **three, and they are the same three that are sideloaded** — measured
/// 2026-09-24 by reading `DCSDictionaryLanguages` out of each of the seven bundles named in
/// `AGENTS.md`: all four Apple assets declare (NOAD and the Writer's Thesaurus `en_US`,
/// 牛津英汉汉英 `zh_CN` and `zh_CN`→`en`, 譯典通 `zh_TW` and `zh_TW`→`en`), and none of Collins
/// COBUILD, Longman or Oxford Collocation does.
///
/// **"Six of the seven declare no language" stood here and in three other files, and was false**:
/// it was the installed sideloaded six wearing the enabled seven's denominator. Both halves of the
/// original sentence are one number on this Mac, which is exactly why they were easy to conflate —
/// but the way to tell two counts apart is to measure the second one, not to assert that they
/// differ. The bridge's `appleAssetsDeclareTheirLanguagesAndSideloadedOnesDoNot` was already
/// enough to refute "six", since it requires two Apple assets to declare.
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
