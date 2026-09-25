import Foundation
import NaturalLanguage

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
        guard let target, let sourceLanguage = SentenceTranslator.dominantLanguage(source),
              !SentenceTranslator.sameLanguage(sourceLanguage, target),
              let answered = SentenceTranslator.dominantLanguage(trimmed)
        else { return true }
        return !SentenceTranslator.sameLanguage(answered, sourceLanguage)
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

/// Which engine translated a sentence — the fact the pane must never hide.
public enum TranslationEngine: String, Sendable, Codable, CaseIterable {
    /// Qwen, on this Mac, told which sense the reader met.
    case localModel
    /// Apple's Translation framework: no download, and **measured to be the weaker engine** — it
    /// takes no instructions, so it cannot be told the sense, and on eight hard sentences it got
    /// four right, rendering *table … until next month* as 提交, the opposite.
    case appleTranslation
}

/// What the translation pane can show.
public enum TranslationOutcome: Sendable, Equatable {
    case translated(String, by: TranslationEngine)
    /// Apple's framework could translate this pair but has no language pack for it. It reports
    /// `.supported` for exactly those pairs, so only `.installed` counts as able.
    case needsLanguagePack(source: String, target: String)
    /// The sentence is already in the reader's language.
    case sameLanguage
    /// Neither engine could. Said, never rendered as an empty translation.
    case unavailable
}

/// What Apple's framework said about one sentence.
public enum AppleTranslationResult: Sendable, Equatable {
    case translated(String)
    case notInstalled
    case unsupported
    case failed
}

/// Translates the reader's sentence: the local model first, Apple's framework where the model is
/// not there, and a plain "could not" where neither is.
///
/// Both engines are injected. The real ones are an XPC round trip and a system framework, and what
/// needs testing here is the order and the labelling, not either engine.
public struct SentenceTranslator: Sendable {
    /// The local model's answer, or nil where the service could not be reached at all.
    public typealias Local = @Sendable (TranslationQuestion) async -> ModelReply?
    public typealias Apple = @Sendable (_ sentence: String, _ source: String, _ target: String) async -> AppleTranslationResult

    private let local: Local
    private let apple: Apple
    private let language: @Sendable (String) -> String?

    public init(local: @escaping Local, apple: @escaping Apple,
                language: @escaping @Sendable (String) -> String? = SentenceTranslator.dominantLanguage) {
        self.local = local
        self.apple = apple
        self.language = language
    }

    /// **The sentence's own language, as this translator reads it.**
    ///
    /// Exposed so a control can ask the same question `translate` asks on its first line, through the
    /// same injected recogniser. A view reaching for the static `dominantLanguage` instead would be a
    /// second opinion that can disagree with the translator about to answer.
    public func sourceLanguage(of sentence: String) -> String? { language(sentence) }

    /// **Whether translating this sentence could tell the reader anything they do not already have.**
    ///
    /// `translate` answers `.sameLanguage` for exactly this, on its first line — so a translate
    /// control drawn live here is a guaranteed dead end, on every card with a sentence, for a reader
    /// whose own language is the one they are reading. An unknown source is **not** the reader's own:
    /// the local model may still answer, and only Apple's framework needs the source named.
    public func isAlreadyInTheReadersLanguage(_ sentence: String, target: String) -> Bool {
        guard let source = sourceLanguage(of: sentence) else { return false }
        return Self.sameLanguage(source, target)
    }

    public func translate(_ question: TranslationQuestion) async -> TranslationOutcome {
        let source = language(question.sentence)
        // The same predicate the control above reads, so the two can never disagree about whether
        // this sentence was worth asking about.
        if isAlreadyInTheReadersLanguage(question.sentence, target: question.target) { return .sameLanguage }
        guard !Task.isCancelled else { return .unavailable }
        let answer = await local(question)
        // Checked after the await as well as before it: a reader who has moved on is not shown a
        // translation that arrived afterwards, and is not waited on for a second engine either.
        guard !Task.isCancelled else { return .unavailable }
        if case .translation(let text)? = answer,
           TranslationCheck.isTranslation(text, of: question.sentence, into: question.target) {
            return .translated(text, by: .localModel)
        }
        // Apple's framework needs the source named: it is built per pair.
        guard let source else { return .unavailable }
        let fallback = await apple(question.sentence, source, question.target)
        guard !Task.isCancelled else { return .unavailable }
        switch fallback {
        case .translated(let text) where TranslationCheck.isTranslation(text, of: question.sentence, into: question.target):
            return .translated(text, by: .appleTranslation)
        case .notInstalled:
            return .needsLanguagePack(source: source, target: question.target)
        case .translated, .unsupported, .failed:
            return .unavailable
        }
    }

    /// The sentence's language as a BCP-47 identifier, where the recogniser commits. Chinese comes
    /// back as `zh-Hans` or `zh-Hant`, which is what the framework's pairs are named by.
    public static func dominantLanguage(_ sentence: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: sentence).map(\.rawValue)
    }

    /// "en" and "en-GB" are one language to a reader; "zh-Hans" and "zh-Hant" are not.
    ///
    /// **A missing script is filled in, not waved through.** Bare `zh` against `zh-Hant` used to
    /// count as the same language, and a reader of Traditional Chinese would have been told their
    /// Simplified sentence was already in their language. `maximalIdentifier` is what the system
    /// would assume for an unqualified tag, which is the same assumption the translator makes.
    /// Public because the panel compares a cached source against the reader's *current* target: the
    /// detection is what costs, and it is cached; the comparison is free and must be made at the
    /// moment the control is drawn, or a reader who changes their language keeps a hidden button.
    public static func sameLanguage(_ source: String, _ target: String) -> Bool {
        let a = Locale.Language(identifier: source), b = Locale.Language(identifier: target)
        guard a.languageCode == b.languageCode else { return false }
        return script(of: a) == script(of: b)
    }

    private static func script(of language: Locale.Language) -> Locale.Script? {
        language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
    }
}
