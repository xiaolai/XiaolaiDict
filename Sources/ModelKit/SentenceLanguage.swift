import Foundation
import NaturalLanguage

/// What a sentence's language is, and whether two names mean the same one.
///
/// **Its own type because `TranslationCheck` needs it and `SentenceTranslator` does not own the
/// question.** These were `static` members on `SentenceTranslator`, which the module split cannot
/// move: the translator runs the ladder and belongs with the app, while the check that an answer is a
/// translation at all is decoded beside the request. Two `NLLanguageRecognizer` call sites in two
/// targets would be one question answered twice — the defect `ScreenRecordingAccess` was written to
/// end for permissions, and the reason `Permission.probe` is the only place that asks about a grant.
///
/// `SentenceTranslator`, `TranslationCheck` and `LookupCardView` all call through here, so there is
/// exactly one spelling of "same language" in the app.
public enum SentenceLanguage {
    /// The sentence's language as a BCP-47 identifier, where the recogniser commits. Chinese comes
    /// back as `zh-Hans` or `zh-Hant`, which is what the framework's pairs are named by.
    public static func dominant(_ sentence: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: sentence).map(\.rawValue)
    }

    /// "en" and "en-GB" are one language to a reader; "zh-Hans" and "zh-Hant" are not.
    ///
    /// **A missing script is filled in, not waved through.** Bare `zh` against `zh-Hant` used to
    /// count as the same language, and a reader of Traditional Chinese would have been told their
    /// Simplified sentence was already in their language. `maximalIdentifier` is what the system
    /// would assume for an unqualified tag, which is the same assumption the translator makes.
    ///
    /// Called at the moment a control is drawn rather than cached with the detection: the detection
    /// is what costs, and it is cached; the comparison is free, and a reader who changes their
    /// language would otherwise keep a hidden button.
    public static func same(_ source: String, _ target: String) -> Bool {
        let a = Locale.Language(identifier: source), b = Locale.Language(identifier: target)
        guard a.languageCode == b.languageCode else { return false }
        return script(of: a) == script(of: b)
    }

    /// Moved with `same(_:_:)` rather than left behind — it is the whole of what "same" means for a
    /// tag that names no script, and the two apart do not compile.
    private static func script(of language: Locale.Language) -> Locale.Script? {
        language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
    }
}
