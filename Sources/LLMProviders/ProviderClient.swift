import Foundation
import ModelKit
import os
import XiaolaiDictBase

/// **Why a question is being asked**: because a lookup happened, or because the reader asked for it.
///
/// It matters for one question and one source. A lookup fires a sense question every time, unasked, and a remote
/// source spends the reader's subscription — whose limit is shared with every other app they use it in — so a remote
/// source is never asked a sense question a lookup fired, even once the dictionary's text may leave (plan §6, ADR-0053).
/// That question follows the reader's own tap. Everything a source on this Mac is asked, it is asked whatever the
/// origin.
public enum QuestionOrigin: Sendable, Equatable {
    /// Asked by every lookup, without the reader asking: the sense ladder's top rung.
    case lookup
    /// Asked because the reader asked: a pane's button, a tap on the card.
    case reader
}

/// **One provider, asked the questions the ladders ask the model service** — `ModelClient.ask`'s shape, so the three
/// ladders take it unchanged (plan §2): `nil` and every `ModelFailure` fall through to Apple's rung and the embedding
/// floor, as they always have.
///
/// - **What leaves the Mac is decided here, once** (plan §3): the prompt is built from `ModelPrompt` for the source's
///   tier, and a tier that may not carry the dictionary's text is never asked to pick a sense, is told no sense with a
///   translation, and is given the remote explanation prompt — `SentenceQuestion.prompt(for: .remote)`.
/// - **And asserted at the send.** Whatever was built, a request for such a tier is checked once more for the
///   publisher's text (`RemoteDisclosure.leaks`) over the very text about to be handed to the provider, and is not sent
///   where it carries any — logged as a fault, because it can only be a defect here.
/// - **Every question has its deadline**, the model service's own table (`ModelDeadline`).
/// - **A provider's failure is a `ModelFailure`** the ladders already read (`ProviderFailure.modelFailure`); a caller
///   that gave up is answered `nil`, as `ModelClient` answers it.
/// - **The answer is read the way the local model's is**: a sense number against its list (`SenseAnswer`), and a
///   translation or an explanation that hands back the sentence it was given is not one.
public struct ProviderClient: Sendable {
    /// Where the provider runs, which decides what it may be sent.
    public let tier: ProviderTier

    private let provider: any TextGenerating
    private let dictionaryTextMayLeave: Bool
    private let deadline: @Sendable (ModelRequest) -> Duration
    private let plan: @Sendable (ModelRequest, ProviderTier, QuestionOrigin, Bool) -> Plan

    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "providers")

    /// A client for `provider`, which runs at `tier`, under the owner's rule about the dictionary's text.
    public init(provider: any TextGenerating, tier: ProviderTier) {
        self.init(provider: provider, tier: tier, dictionaryTextMayLeave: RemoteDisclosure.dictionaryTextMayLeave)
    }

    /// The same, with the flip as an argument — so both of its arms are tested before anyone flips it — and, for the
    /// send-time assertion's own test, a builder of the test's: the one way to put the dictionary's text in a request
    /// for a remote tier is to build it wrong, and that is what the assertion is for.
    init(provider: any TextGenerating, tier: ProviderTier, dictionaryTextMayLeave: Bool,
         deadline: @escaping @Sendable (ModelRequest) -> Duration = ModelDeadline.of,
         plan: @escaping @Sendable (ModelRequest, ProviderTier, QuestionOrigin, Bool) -> Plan = ProviderClient.plan) {
        self.provider = provider
        self.tier = tier
        self.dictionaryTextMayLeave = dictionaryTextMayLeave
        self.deadline = deadline
        self.plan = plan
    }

    /// Asks the provider `request`, asked for `origin`. Nil where it was not asked — a sense question this tier may
    /// not be sent, a request that failed the send-time check — or where the caller gave up.
    public func ask(_ request: ModelRequest, origin: QuestionOrigin) async -> ModelReply? {
        let generation: GenerationRequest, reading: Reading
        switch plan(request, tier, origin, dictionaryTextMayLeave) {
        case .notAsked: return nil
        case .invalid(let why): return .failure(.invalidRequest(why))
        case .ask(let built, let read): (generation, reading) = (built, read)
        }
        // **The send-time assertion** (plan §3): whatever the plan built, the text about to be handed to a source that
        // may not carry the publisher's text is looked through for it once more. Only a defect here can trip it, so
        // nothing is sent, the fault is logged — never what the text was — and the ladder falls through as it would
        // for a source that did not answer. Not fatal: a guard on our own mistake never takes the lookup down with it.
        if !RemoteDisclosure.mayCarryDictionaryText(tier, dictionaryTextMayLeave: dictionaryTextMayLeave),
           RemoteDisclosure.leaks(generation.instructions + "\n" + generation.prompt, of: request) {
            Self.log.fault("a request for a remote source carried the dictionary's text; it was not sent")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let provider = provider
        do {
            let text = try await withDeadline(deadline(request)) { try await provider.generate(generation) }
            return reading.reply(to: text)
        } catch let failure as ProviderFailure {
            return failure == .cancelled ? nil : .failure(ProviderFailure.modelFailure(for: failure))
        } catch is DeadlineExceeded {
            return .failure(ProviderFailure.modelFailure(for: .timedOut))
        } catch {
            // `withDeadline`'s own cancellation: the caller gave up, which `ModelClient` answers nil too.
            return nil
        }
    }

    // MARK: - What is asked

    /// How the answer to a request is read.
    enum Reading: Sendable, Equatable {
        /// A position in a list of `count` senses, or 0.
        case sense(count: Int)
        /// A translation of `sentence` into `target`.
        case translation(sentence: String, target: String)
        /// An explanation of the word's use in `sentence`.
        case explanation(sentence: String)
    }

    /// What asking a request comes to.
    enum Plan: Sendable, Equatable {
        /// This tier is not asked this — nothing is sent.
        case notAsked
        /// A request no provider can answer, said as the model service says it: a defect in whoever built it.
        case invalid(String)
        /// Send this, and read the answer so.
        case ask(GenerationRequest, Reading)
    }

    /// **The rule, as one pure function**: what `request`, asked for `origin`, is sent to a source at `tier` — given
    /// whether the dictionary's text may leave the Mac.
    static func plan(_ request: ModelRequest, tier: ProviderTier, origin: QuestionOrigin,
                     dictionaryTextMayLeave: Bool) -> Plan {
        let mayCarry = RemoteDisclosure.mayCarryDictionaryText(tier, dictionaryTextMayLeave: dictionaryTextMayLeave)
        switch request {
        case .pickSense(let question):
            // **The question is the publisher's text**, a list of it — so it goes only where that text may, and to a
            // remote source only on the reader's tap: a lookup asks it every time, on the reader's shared quota.
            guard mayCarry, tier == .onThisMac || origin == .reader else { return .notAsked }
            guard !question.senses.isEmpty, !isBlank(question.sentence) else {
                return .invalid("a sense question needs a sentence and senses")
            }
            guard question.senses.count <= ModelPrompt.maximumSenses else {
                return .invalid("\(question.senses.count) senses; the answer can name at most \(ModelPrompt.maximumSenses)")
            }
            return .ask(GenerationRequest(instructions: ModelPrompt.senseInstructions, prompt: ModelPrompt.sense(question),
                                          maxTokens: senseAnswerTokens, temperature: 0),
                        .sense(count: question.senses.count))
        case .translate(let question):
            guard !isBlank(question.sentence), !isBlank(question.target) else {
                return .invalid("a translation needs a sentence and a language")
            }
            // The reader's sentence goes wherever they send it; the sense beside it only where the publisher's may.
            let sent = mayCarry ? question : TranslationQuestion(sentence: question.sentence, target: question.target)
            return .ask(GenerationRequest(instructions: ModelPrompt.translationInstructions(for: sent),
                                          prompt: ModelPrompt.translation(sent),
                                          maxTokens: ModelPrompt.translationTokens(for: sent), temperature: 0),
                        .translation(sentence: question.sentence, target: question.target))
        case .explain(let question):
            guard !isBlank(question.sentence), !isBlank(question.term) else {
                return .invalid("an explanation needs a sentence and a word")
            }
            // Dropped in `prompt(for:)`, the one place every rung builds this prompt — never assembled here.
            return .ask(GenerationRequest(instructions: ModelPrompt.explanationInstructions,
                                          prompt: question.prompt(for: mayCarry ? .onDevice : .remote),
                                          maxTokens: ModelPrompt.explanationTokens(for: question),
                                          temperature: explanationTemperature),
                        .explanation(sentence: question.sentence))
        case .prewarm, .status, .unload:
            return .invalid("only the model service answers this; a provider is asked questions")
        }
    }

    /// **A sense answer is a number**, and a hosted model may write a few words after it (measured: haiku did 6–12 times
    /// in 20). Enough for the number and its first words; the CLIs take no budget and ignore it.
    static let senseAnswerTokens = 16
    /// **An explanation is sampled** (AGENTS.md: sense picking runs at temperature 0; explaining is sampled), at the
    /// sampling OpenAI documents as its default — no value of this app's own, so an endpoint answers as it would anyone.
    static let explanationTemperature = 1.0

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ProviderClient.Reading {
    /// What `text` answers, read as the model service reads its own model's answer: a sense number against its list,
    /// and a translation or an explanation that is not the sentence handed back.
    func reply(to text: String) -> ModelReply {
        switch self {
        case .sense(let count):
            guard let number = SenseAnswer.parse(text, count: count) else {
                return .failure(.generationFailed("an answer that names no sense in the list"))
            }
            return .sense(number)
        case .translation(let sentence, let target):
            let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An echo reads as success and is not one — and the model service refuses it the same way.
            guard TranslationCheck.isTranslation(translated, of: sentence, into: target) else {
                return .failure(.generationFailed("the model answered with the sentence it was given"))
            }
            return .translation(translated)
        case .explanation(let sentence):
            let explained = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !explained.isEmpty else { return .failure(.generationFailed("the model answered with nothing")) }
            guard TranslationCheck.isTranslation(explained, of: sentence) else {
                return .failure(.generationFailed("the model answered with the sentence it was given"))
            }
            return .explanation(explained)
        }
    }
}
