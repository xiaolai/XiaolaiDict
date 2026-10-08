import Foundation

/// **Reads a sense number out of a provider's prose, the way the measurement read it.**
///
/// A hosted model or a CLI answers in text, with no grammar holding it to a number, and ADR-0053's 270-case
/// measurement scored those answers with the lab's `answer_number`. A reader that differed would make the measured
/// error rates describe another parser, so this is that function's rule: **the first non-empty line, that line up to
/// its first full stop, the first run of digits in it.**
///
/// **One deliberate difference, and it refuses rather than reads.** The lab's `\d` matched any decimal digit, so
/// `٣` was 3 there. Here a first run holding a digit outside ASCII is no answer: nothing in a sense prompt asks for
/// another script's digits, and reading one would make a model's slip a confident position in the list.
public enum SenseAnswer {
    /// The number `text` answers with, against a list of `count` senses: `0` where the model abstained, a position
    /// in `1...count`, or nil where there is no such number — none at all, one past the list, or one too long to be
    /// an integer. Never traps, whatever `count` is.
    public static func parse(_ text: String, count: Int) -> Int? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let sentence = line.prefix { $0 != "." }
        // Scalars, not characters: a keycap `3️⃣` is one character whose first scalar is the digit 3.
        let scalars = sentence.unicodeScalars
        guard let start = scalars.firstIndex(where: isDecimalDigit) else { return nil }
        let run = scalars[start...].prefix(while: isDecimalDigit)
        guard run.allSatisfy(\.isASCII), let number = Int(String(String.UnicodeScalarView(run))) else { return nil }
        if number == 0 { return 0 }
        return number >= 1 && number <= count ? number : nil
    }

    /// A decimal digit in any script — what the lab's `\d` matched — so a run is found where the lab found it.
    private static func isDecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .decimalNumber
    }
}
