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
    ///
    /// **The first scalar, deliberately.** A probe word is single-script by construction, so its
    /// opening letter settles it. Captured text is not; that is `dominant(in:)`. The two differ in
    /// how they traverse and never in what a scalar *is* — they share `letterScript`, because the
    /// copy they started as had already drifted, `of` missing every block the other had gained.
    public static func of(_ word: String) -> ProbeScript? {
        guard let first = word.unicodeScalars.first else { return nil }
        return letterScript(of: first)
    }

    /// The script `text` is mostly written in, or nil where it is written in none.
    ///
    /// **`of` is not this, and the difference is the input.** A probe word is single-script by
    /// construction — `DictionaryBridge.probeWords` picks them that way — so its first scalar
    /// settles it. Text the reader rested on is whatever was on their screen: it opens with a
    /// quotation mark, carries a digit, or mixes scripts where OCR took in a neighbour. Reusing
    /// the first-scalar classifier there would have answered nil for `"hold"` in quotation marks
    /// and han for `the 水`.
    ///
    /// Letters vote and nothing else does. Punctuation, digits and spaces are skipped rather than
    /// counted, so a string with no letters at all answers nil — a number is not written in a
    /// script, and naming one for it would put every `42` in the reader's history under Latin.
    ///
    /// **Kana absorbs han rather than merely outvoting it.** The two are probed separately for one
    /// reason, recorded in `probeWords`: 水 alone is Chinese and 水 beside する is Japanese. So any
    /// kana makes the han beside it Japanese too — otherwise `勉強する` is 2 han against 2 kana and
    /// comes out a tie, and `漢字を勉強する` comes out Chinese on a majority of kanji.
    ///
    /// **Compatibility-normalised first** (NFKC), which does two jobs. It settles composed against
    /// decomposed — `ế` as one scalar and as `e` plus two combining marks answered nil and Latin
    /// respectively, and a screen capture can be either. And it folds the presentation forms —
    /// ligatures, halfwidth kana, fullwidth Latin, squared words — into the letters they stand for,
    /// which is what stops the block list below growing every time a new corner of Unicode turns
    /// up. Two rounds of this classifier were spent adding blocks one at a time; `ﬀ` and `ｶ` are
    /// not new scripts, they are `ff` and `カ` in costume. The text is normalised for the reading
    /// only — nothing normalised is stored or shown.
    ///
    /// A tie among the rest goes to whichever appeared first, so the answer does not depend on the
    /// order a dictionary happens to enumerate.
    public static func dominant(in text: String) -> ProbeScript? {
        var counts: [ProbeScript: Int] = [:]
        var order: [ProbeScript] = []
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            guard let script = letterScript(of: scalar) else { continue }
            if counts[script] == nil { order.append(script) }
            counts[script, default: 0] += 1
        }
        if let kana = counts[.kana], let han = counts.removeValue(forKey: .han) {
            counts[.kana] = kana + han
            order.removeAll { $0 == .han }
        }
        guard let best = counts.values.max() else { return nil }
        return order.first { counts[$0] == best }
    }

    /// The script one scalar is a letter of. Nil for punctuation, digits, spaces and symbols.
    ///
    /// **Letterhood is asked of Unicode, never inferred from the block.** A block holds a script's
    /// punctuation too: `U+30FB ・` is a separator sitting inside Katakana, and counting it as kana
    /// made `水・` Japanese — which, through the han-absorption rule, refused a Chinese word for a
    /// reader who studies Chinese. `isAlphabetic` is what separates the letters from the furniture,
    /// and it keeps `U+30FC ー`, a modifier letter, where it belongs: ラーメン is one word.
    ///
    /// **The blocks are listed in full rather than approximately.** Text a scalar classifier cannot
    /// name is looked up — unknown is permissive on purpose — so every block left out is a hole in
    /// the reader's filter rather than a missing nicety. The first pass covered ASCII, one Latin
    /// range, the basic CJK planes and the main kana blocks, and let halfwidth katakana `ｶﾀｶﾅ`,
    /// supplementary han `𠮷` and `ế` through a filter set to exclude them.
    static func letterScript(of scalar: Unicode.Scalar) -> ProbeScript? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        // Hiragana, Katakana, their phonetic extensions, and the supplements past the basic
        // plane. The halfwidth forms are not listed: NFKC has already folded them to fullwidth.
        case 0x3040...0x30FF, 0x31F0...0x31FF,
             0x1B000...0x1B0FF, 0x1B100...0x1B12F, 0x1B130...0x1B16F:
            return .kana
        // Jamo, compatibility jamo, the syllable block, both jamo extensions, halfwidth jamo.
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xFFA0...0xFFDC:
            return .hangul
        // CJK unified ideographs, extensions A through H, and both compatibility blocks. The
        // extensions past B live in the supplementary planes, which a `UInt32` range reaches and
        // a `UInt16`-shaped assumption does not.
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x2F800...0x2FA1F,
             0x30000...0x323AF:
            return .han
        // **Greek, sitting inside Latin Extended-E.** `U+AB65` is GREEK LETTER SMALL CAPITAL
        // OMEGA and it does not decompose, so nothing upstream removes it: covering the block
        // whole swept Greek into Latin and would have looked it up for a Latin-only reader. The
        // same lesson as `・` in the Katakana block — a block is a range of code points, never a
        // claim about script — and the reason each range below is bounded rather than rounded off.
        case 0xAB65:
            return nil
        // Basic Latin, Latin-1 Supplement, Extended-A and -B, IPA, Extended Additional,
        // Extended-C, -D and -E. The fullwidth forms and the ligatures are not listed: NFKC has
        // already folded them to plain letters.
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x0250...0x02AF,
             0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F:
            return .latin
        default:
            return nil
        }
    }
}
