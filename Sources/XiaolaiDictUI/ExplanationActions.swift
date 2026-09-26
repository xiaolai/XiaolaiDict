import ModelKit
import SwiftUI
import XiaolaiDictCore

/// What the panel needs to explain a sentence, handed in by the app — which owns the model service.
///
/// The default explains nothing and says so, for the same reason `TranslationActions.none` does: a
/// view built without the app must read as unable rather than pretend.
public struct ExplanationActions: Sendable {
    public var explain: @Sendable (SentenceQuestion) async -> SentenceExplanation

    public init(explain: @escaping @Sendable (SentenceQuestion) async -> SentenceExplanation) {
        self.explain = explain
    }

    public static let none = ExplanationActions { _ in
        .unavailable(String(localized: "No model is available to explain this sentence.",
                            comment: "Shown in the sentence pane when nothing can explain the sentence"))
    }
}

private struct ExplanationActionsKey: EnvironmentKey {
    static let defaultValue = ExplanationActions.none
}

extension EnvironmentValues {
    public var explainer: ExplanationActions {
        get { self[ExplanationActionsKey.self] }
        set { self[ExplanationActionsKey.self] = newValue }
    }
}
