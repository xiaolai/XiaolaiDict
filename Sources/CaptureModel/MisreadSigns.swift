import Foundation

/// **Signs in a sentence's own text that it was read wrongly off the screen.**
///
/// Vision's confidence cannot say it: it is per observation and quantised to 0.3, 0.5 and 1.0, and
/// `comfortable（你用的）` came back as `comfortable (1TÆ฿J)` at 1.0. Measured over the 94 optical
/// reads in the owner's ledger (2026-10-11), these two shapes flag 7 rows, each a real misread, and
/// no correctly read sentence. They do not see a misread made only of plausible Latin letters —
/// `AI` read as `Al`, or word salad — which needs a lexicon. Both shapes are judged per word, so a
/// sentence that merely mixes languages, as Chinese with English does, carries no sign.
public enum MisreadSigns: Sendable, Equatable {
    /// Letters of two alphabets — Latin, Cyrillic, Greek — inside one word: a homoglyph standing in
    /// for the letter that was on screen (`Лlhat`, `XiaolaiDict.аpp`).
    case mixedAlphabets
    /// A symbol outside ASCII inside a run of letters (`1TÆ฿J`). ASCII symbols are excluded: `$PWD`
    /// and `^C` are what a terminal shows.
    case symbolInsideAWord

    /// The first sign found in `sentence`, or nil.
    public static func found(in sentence: String) -> MisreadSigns? {
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            let scalars = word.unicodeScalars
            guard scalars.contains(where: \.properties.isAlphabetic) else { continue }
            let alphabets = Set(scalars.compactMap(Alphabet.init))
            if alphabets.count > 1 { return .mixedAlphabets }
            if scalars.contains(where: { !$0.isASCII && $0.properties.generalCategory.isSymbol }) {
                return .symbolInsideAWord
            }
        }
        return nil
    }

    /// The alphabets whose letters stand in for one another. Han, kana and Hangul are not here: they
    /// are written without spaces beside Latin, so a "word" holding both is ordinary text.
    private enum Alphabet {
        case latin, cyrillic, greek

        init?(_ scalar: Unicode.Scalar) {
            guard scalar.properties.isAlphabetic else { return nil }
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: self = .latin
            case 0x400...0x52F: self = .cyrillic
            case 0x370...0x3FF, 0x1F00...0x1FFF: self = .greek
            default: return nil
            }
        }
    }
}

private extension Unicode.GeneralCategory {
    var isSymbol: Bool {
        switch self {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }
}

extension CaptureQuality {
    /// **Whether `sentence`, captured with this quality, should not be taken as the reader's own.**
    /// Only an optical read can be wrong rather than absent, so only one is doubted. Derived from
    /// what the ledger already stores — the source and the sentence — and never stored itself.
    public func doubts(sentence: String?) -> Bool {
        guard source == .opticalRecognition, let sentence else { return false }
        return MisreadSigns.found(in: sentence) != nil
    }
}
