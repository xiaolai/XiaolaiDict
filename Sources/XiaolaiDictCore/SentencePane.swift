import FoundationModels
import Foundation
import ModelKit


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
        // Asked of both rungs, before either is woken: an explanation with no sentence or no word
        // is not something a model can be asked, and falling through to Apple with it would only
        // spend a second generation on the same nothing.
        guard !question.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !question.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unavailable("There is no sentence to explain.") }
        guard !Task.isCancelled else { return .unavailable("The explanation was stopped.") }
        let reply = await local(question)
        // **A request the service refused as invalid is a defect in this rung**, not a reason to
        // spend a second generation on the same thing: the bounds it checks are ones this ladder
        // built, and falling through would hide that behind an answer.
        if case .failure(.invalidRequest(let why))? = reply {
            assertionFailure("the model service refused this rung's own question: \(why)")
            return .unavailable("This sentence could not be explained.")
        }
        if case .explanation(let text)? = reply {
            // **Checked on the way out too.** A reply that arrives after the reader has closed the
            // panel is an answer to a question nobody is waiting for, and a blank one is not an
            // explanation — `SentenceExplanation` promises the pane is never empty.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Task.isCancelled { return .unavailable("The explanation was stopped.") }
            if !trimmed.isEmpty { return .explained(trimmed, tier: tier) }
        }
        // Not installed, out of memory, declined, blank, or no service: the rung below answers, and
        // says for itself why it could not where it cannot either.
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
            let session = LanguageModelSession(instructions: ModelPrompt.explanationInstructions)
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
}
