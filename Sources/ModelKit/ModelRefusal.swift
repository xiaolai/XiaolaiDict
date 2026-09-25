import FoundationModels

/// Whether a model's error means **it declined this request** — as against being absent, overflowing
/// its context, or going away mid-answer.
///
/// One question, asked in one place, because two rungs ask it: Apple's model refuses *"The police
/// will charge him with fraud."*, and until this existed that refusal was filed as `.unavailable` —
/// "no model here" — and the reader of crime news fell to a weaker rung with nothing recording why.
///
/// **Measured on the E2E Mac, 2026-09-22**: with the app's instructions and the eight senses of
/// *charge*, the system model threw `LanguageModelError.refusal` ("May contain sensitive content")
/// four runs of four — never the `GenerationError` macOS 27 deprecated, which is why that type is
/// not matched here. A guardrail violation is the same kind of fact, so it counts too.
public enum ModelRefusal {
    public static func isRefusal(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        switch error {
        case .refusal, .guardrailViolation: return true
        default: return false
        }
    }
}
