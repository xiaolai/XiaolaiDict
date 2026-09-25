import Foundation

/// Whether a translator's output is a translation at all, rather than one of the two failures
/// that look like one.
///
/// **An echo is the failure that reads as success.** A translator that hands the input back — or
/// returns nothing — produces an answer indistinguishable from a working one, and a pane would
/// render it with full confidence. Measured for both engines here: Qwen3.5-9B once returned its
/// English untranslated, and Apple's framework fed a pair in the wrong language can only echo.
public enum TranslationCheck {
    /// `into` is the language asked for, where the caller knows it. An answer still in the *source's*
    /// language is refused even when it is not word-for-word the input: a model that restates the
    /// sentence, or hands back an English paraphrase of English, has not translated it. The target is
    /// not required to match — a proper noun or a short answer can read as any language — so only the
    /// clear failure is caught.
    public static func isTranslation(_ output: String, of source: String, into target: String? = nil) -> Bool {
        let trimmed = unwrapped(output)
        guard !trimmed.isEmpty else { return false }
        // **Both sides, the same way.** Unwrapping only the answer let a quoted sentence echoed back
        // verbatim pass: the captured source keeps its own quotation marks, so the two normalised
        // differently and the comparison that exists to catch an echo did not.
        guard normalised(trimmed) != normalised(unwrapped(source)) else { return false }
        guard let target, let sourceLanguage = SentenceLanguage.dominant(source),
              !SentenceLanguage.same(sourceLanguage, target),
              let answered = SentenceLanguage.dominant(trimmed)
        else { return true }
        return !SentenceLanguage.same(answered, sourceLanguage)
    }

    /// Case and whitespace are not a translation.
    private static func normalised(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Nor are quotation marks around the sentence it was given.
    private static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = CharacterSet(charactersIn: "\"'“”„«»‘’「」『』")
        return trimmed.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
