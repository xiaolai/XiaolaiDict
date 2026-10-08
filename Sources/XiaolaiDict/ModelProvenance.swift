import Foundation
import LLMProviders
import ModelKit
import Synchronization
import XiaolaiDictCore

/// **Who answered a pane, said from where its question was sent** (ADR-0053, plan §6).
///
/// The ladders cannot tell: `LadderSentenceExplainer` marks every answer of its first rung `.onDevice`, and
/// `SentenceTranslator` every one `.localModel` — both were written when that rung was the bundled model, and the plan
/// keeps them unchanged. The router knows where it sent the question, so the app reads that and re-marks an answer
/// that came from a remote source. **Only an answer that is the remote source's own** is re-marked: where its reply was
/// refused or empty the ladder fell to Apple's engine, which ran on this Mac, and keeps its own label.
enum ModelProvenance {
    /// `result`, marked `.remote` where it is the explanation a remote source sent back.
    static func explanation(_ result: SentenceExplanation, answeredBy routed: RoutedReply?) -> SentenceExplanation {
        guard case .explained(let text, _) = result, routed?.tier == .remote,
              case .explanation(let sent)? = routed?.reply,
              sent.trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return result }
        return .explained(text, tier: .remote)
    }

    /// `outcome`, marked `.remoteModel` where it is the translation a remote source sent back.
    static func translation(_ outcome: TranslationOutcome, answeredBy routed: RoutedReply?) -> TranslationOutcome {
        guard case .translated(let text, by: .localModel) = outcome, routed?.tier == .remote,
              case .translation(let sent)? = routed?.reply, sent == text
        else { return outcome }
        return .translated(text, by: .remoteModel)
    }
}

/// **What the router answered one pane's question with**, kept while the ladder decides what to show — the ladder's
/// first rung is a closure that can hand back only the reply, so the tier is set aside here beside it.
final class RoutedAnswer: Sendable {
    private let kept = Mutex<RoutedReply?>(nil)

    var last: RoutedReply? { kept.withLock { $0 } }

    /// Keeps `routed`, and hands its reply to the ladder.
    func keep(_ routed: RoutedReply) -> ModelReply? {
        kept.withLock { $0 = routed }
        return routed.reply
    }
}
