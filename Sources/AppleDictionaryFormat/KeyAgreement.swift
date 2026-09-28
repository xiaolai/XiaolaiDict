import Foundation

/// Whether a search key and the headword it resolved to plausibly belong together.
///
/// **This is the oracle the confidence gate rests on, and the obvious version of it does not work.**
/// Asking whether the headword *contains* the key fails systematically, in two ways that have nothing to
/// do with a wrong mapping:
///
/// - **Inflection.** Russian `вое`, `вои`, `воя` all belong to `вой`, and none is a substring of it. Under
///   containment `ru.oup` scored 7.9% — a number that says more about Russian morphology than about the
///   mapping.
/// - **Interleaved pronunciation.** `zh_TW.wn` writes its headword as `三ㄙㄢ言ㄧㄢˊ`, with Bopomofo
///   between every character, so the key `三言` cannot be a substring of its own headword. It scored 6.9%.
///
/// Both were resolving *correctly*. So the test is not containment but **a shared opening after the
/// pronunciation is taken out**: a derived or inflected form almost always begins like the form it belongs
/// to, and an unrelated word almost never does. `сок` against `во́лос` — a real mis-resolution found while
/// checking this — shares nothing and still fails, which is the behaviour that matters.
///
/// It remains a **floor and not a proof.** A dictionary whose morphology is prefixing rather than
/// suffixing would score low while being right, and nothing here would notice.
enum KeyAgreement {
    /// The headword without its pronunciation.
    ///
    /// Apple delimits a pronunciation with `|`, so everything from the first one is dropped. Bopomofo and
    /// combining marks are then removed, because `zh_TW.wn` interleaves them *inside* the word rather than
    /// after it — there is no delimiter to cut at.
    static func base(_ text: String) -> String {
        let cut = text.prefix { $0 != "|" }
        var out = String.UnicodeScalarView()
        for scalar in cut.unicodeScalars where !isPhonetic(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// Bopomofo, its extensions, and combining diacriticals — pronunciation written into the word itself.
    static func isPhonetic(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3100...0x312F).contains(v)   // Bopomofo
            || (0x31A0...0x31BF).contains(v)   // Bopomofo extended
            || (0x0300...0x036F).contains(v)   // combining diacriticals (Russian stress marks)
            || (0x02B0...0x02FF).contains(v)   // spacing modifier letters
    }

    /// Case-folded, stripped of everything that is not a letter or a digit.
    ///
    /// Hyphens and spaces go because a key and its headword disagree about them routinely — Danish
    /// `a aktier` against the headword `A-aktier` is the same word written two ways.
    static func fold(_ text: String) -> String {
        String(base(text).lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// How many leading characters must match for the two to count as related.
    ///
    /// Proportional to the shorter of the two, with a floor of 2: `вое`/`вой` share two of three, which is
    /// enough, while two unrelated words sharing one opening letter is not.
    static func requiredPrefix(_ a: String, _ b: String) -> Int {
        max(2, Int((0.6 * Double(min(a.count, b.count))).rounded(.up)))
    }

    static func agrees(key: String, headword: String) -> Bool {
        let k = fold(key), h = fold(headword)
        guard !k.isEmpty, !h.isEmpty else { return false }
        if h.hasPrefix(k) || k.hasPrefix(h) { return true }
        let shared = zip(k, h).prefix { $0.0 == $0.1 }.count
        return shared >= requiredPrefix(k, h)
    }
}
