import Foundation
import ModelKit
import NaturalLanguage


/// Which engine translated a sentence — the fact the pane must never hide.
public enum TranslationEngine: String, Sendable, Codable, CaseIterable {
    /// Qwen, on this Mac, told which sense the reader met — or a provider the reader chose that runs on this Mac (a
    /// loopback endpoint), which may be told it too.
    case localModel
    /// **A provider that is not on this Mac** (ADR-0053): the reader's CLI or a hosted endpoint, sent the reader's
    /// sentence and never the sense. `SentenceTranslator` cannot tell where its first engine ran, so the app sets this
    /// from where the question was sent — a translation sent away must never be labelled as the local model's.
    case remoteModel
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
                language: @escaping @Sendable (String) -> String? = SentenceLanguage.dominant) {
        self.local = local
        self.apple = apple
        self.language = language
    }

    /// **The sentence's own language, as this translator reads it.**
    ///
    /// Exposed so a control can ask the same question `translate` asks on its first line, through the
    /// same injected recogniser. A view reaching for `SentenceLanguage.dominant` instead would be a
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
        return SentenceLanguage.same(source, target)
    }

    public func translate(_ question: TranslationQuestion) async -> TranslationOutcome {
        // **One reading of the sentence's language** for both questions below: whether it is already the reader's —
        // the rule the control above reads, so the two cannot disagree — and which pair Apple's framework is asked for.
        let source = language(question.sentence)
        if let source, SentenceLanguage.same(source, question.target) { return .sameLanguage }
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
}
