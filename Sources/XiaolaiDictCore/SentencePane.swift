import FoundationModels
import Foundation

/// Who is allowed to see what, when XiaolaiDict explains a sentence.
///
/// **This is a licensing boundary, not a performance one.** The dictionaries are licensed to the
/// reader, not to XiaolaiDict: extracted definitions, examples or translations must never be shipped,
/// published, **or sent to a remote service** (`dev-docs/dictionary-markup.md` §8). So the tiers
/// are not interchangeable, and the difference is legal rather than technical.
public enum ExplainerTier: String, Sendable, CaseIterable {
    /// Runs on this Mac. May see the sentence **and** the dictionary entry.
    case onDevice
    /// A frontier API, opt-in. May see **the reader's own sentence only** — never a definition, an
    /// example or a translation. That kills "explain this definition" over the network and keeps
    /// "parse this sentence", and it simplifies consent: the remote tier sends text the reader was
    /// already reading.
    case remote

    public var maySeeDictionaryText: Bool { self == .onDevice }
}

/// What XiaolaiDict is asking about a sentence.
///
/// The dictionary text is *optional here and dropped at the boundary* rather than being trusted not
/// to be sent: `prompt(for:)` cannot include it for the remote tier, so a caller who assembles the
/// wrong thing gets a prompt without it rather than a licence breach.
/// `Codable` because it crosses XPC to the model service — the same boundary the dictionary
/// questions cross, and the reason the tier's dropping happens in `prompt(for:)` rather than at
/// each call site.
public struct SentenceQuestion: Codable, Sendable, Equatable {
    /// The reader's own sentence. Theirs, not the publisher's — always sendable.
    public let sentence: String
    /// The word they looked up.
    public let term: String
    /// The sense's definition, where one is known. **Publisher's text.**
    public let senseText: String?

    public init(sentence: String, term: String, senseText: String? = nil) {
        self.sentence = sentence
        self.term = term
        self.senseText = senseText
    }

    /// The prompt for `tier`, with anything that tier may not see removed **here**, once, rather
    /// than at each call site.
    public func prompt(for tier: ExplainerTier) -> String {
        var lines = ["Sentence: \(sentence)", "Word: \(term)"]
        if tier.maySeeDictionaryText, let senseText, !senseText.isEmpty {
            lines.append("Dictionary sense: \(senseText)")
        }
        lines.append("Explain how the word is being used in this sentence, in two or three sentences.")
        return lines.joined(separator: "\n")
    }

    /// Whether `text` could carry publisher's text to a remote service. Used by the test that keeps
    /// the boundary honest, and cheap enough to assert on every remote send.
    public func leaksDictionaryText(_ text: String) -> Bool {
        guard let senseText, !senseText.isEmpty else { return false }
        return text.contains(senseText)
    }
}

public enum SentenceExplanation: Sendable, Equatable {
    case explained(String, tier: ExplainerTier)
    /// It could not, and why — never a blank pane, and never a guess.
    case unavailable(String)
}

public protocol SentenceExplaining: Sendable {
    var tier: ExplainerTier { get }
    func explain(_ question: SentenceQuestion) async -> SentenceExplanation
}

/// The explainer the reader actually gets: **the downloaded model first, Apple's where it is not
/// here.** The same shape as `SentenceTranslator`, and for the same reason — the LLM panes must
/// work for a reader without Apple Intelligence, which is most of mainland China, and a pane only
/// some readers ever see an answer in is a pane that reads as broken to the rest.
///
/// No label, unlike translation: both engines run on this Mac and neither was measured worse than
/// the other at explaining. What is labelled there is a *measured* difference, not the mere fact of
/// a fallback.
public struct LadderSentenceExplainer: SentenceExplaining {
    /// One round trip to the model service; nil where it could not be reached at all.
    public typealias Local = @Sendable (SentenceQuestion) async -> ModelReply?

    public let tier = ExplainerTier.onDevice
    private let local: Local
    private let apple: any SentenceExplaining

    public init(local: @escaping Local, apple: any SentenceExplaining = OnDeviceSentenceExplainer()) {
        self.local = local
        self.apple = apple
    }

    public func explain(_ question: SentenceQuestion) async -> SentenceExplanation {
        if case .explanation(let text)? = await local(question) {
            return .explained(text, tier: tier)
        }
        // Not installed, out of memory, declined, or no service: the rung below answers, and says
        // for itself why it could not where it cannot either.
        guard !Task.isCancelled else { return .unavailable("The explanation was stopped.") }
        return await apple.explain(question)
    }
}

/// The on-device tier: Apple's model, which may see the dictionary entry because nothing leaves
/// the Mac.
///
/// **On request, never automatically** (decision D4). Automatic would mean every hover starts a
/// generation, and Milestone 2's whole point is that hovers are cheap.
public struct OnDeviceSentenceExplainer: SentenceExplaining {
    public let tier = ExplainerTier.onDevice

    public init() {}

    public func explain(_ question: SentenceQuestion) async -> SentenceExplanation {
        guard !question.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("There is no sentence to explain.")
        }
        // **Asked through `SenseEngine`, which is the one place that asks.** This switched over
        // Apple's own enum itself, so the two could drift — and the reason a reader is told here
        // would stop matching the one the setup board shows.
        if SenseEngine.status().reason != nil {
            // Unavailable in mainland China, and on any Mac without Apple Intelligence. Said
            // plainly rather than silently falling back to something that may send text away — and
            // **without the enum's own name in it**: `appleIntelligenceNotEnabled` is an identifier,
            // not a sentence, and this string is not translatable where it lives.
            return .unavailable("The on-device model is not available here.")
        }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let answer = try await session.respond(to: question.prompt(for: tier))
            // **A blank answer is not an explanation.** `.explained` promises the pane has
            // something to show; handed an empty string it drew an empty pane, which reads as the
            // model having nothing to say about the sentence rather than as nothing arriving.
            let text = answer.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .unavailable("The on-device model answered with nothing.") }
            return .explained(text, tier: tier)
        } catch is CancellationError {
            // The reader closed the panel. Nothing to report about the model.
            return .unavailable("The explanation was stopped.")
        } catch {
            // **A refusal is the model declining this sentence; anything else is a failure.** Every
            // error reported as "declined" told the reader their sentence had been refused when the
            // session had in fact failed to load or the generation had broken off.
            guard ModelRefusal.isRefusal(error) else {
                return .unavailable("The on-device model could not answer.")
            }
            // A guardrail refusal on adult reading material lands here, and is reported as a
            // refusal rather than retried against a tier that may send the text off the Mac.
            return .unavailable("The on-device model declined to answer.")
        }
    }

    static let instructions = """
        You explain how one word is being used in one sentence, for a language learner.
        Be brief: two or three sentences. Explain the usage, do not define the word in isolation, \
        and do not repeat the sentence back.
        """
}
