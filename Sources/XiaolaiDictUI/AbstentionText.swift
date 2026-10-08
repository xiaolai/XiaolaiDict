import DictionaryModel
import Foundation

public extension Abstention {
    /// What the panel says instead of a mark. It says why it did not choose, which is the other
    /// half of "the popup can mark a sense, and can say why it did not".
    ///
    /// Here rather than beside the enum in `DictionaryModel`: these are the only sentences the
    /// reader sees from the selector, and no target below the view layer may hold one — a sentence
    /// there could be shown and never given to a translator (ADR-0025).
    var reason: String {
        switch self {
        case .noCandidates:
            String(localized: "This dictionary does not mark its meanings, so the one you read cannot be identified.",
                   comment: "Shown on the lookup card when the dictionary marks no senses to choose between")
        case .noContext:
            String(localized: "No sentence was captured around the word, so its meanings cannot be told apart.",
                   comment: "Shown on the lookup card when no sentence surrounded the word")
        case .tooClose:
            String(localized: "Several meanings fit this sentence equally well.",
                   comment: "Shown on the lookup card when two senses cannot be separated")
        case .nothingFits:
            String(localized: "No meaning in this entry clearly fits this sentence.",
                   comment: "Shown on the lookup card when no sense is close enough to claim")
        case .undecided:
            String(localized: "This sentence does not settle which meaning the word carries.",
                   comment: "Shown on the lookup card when a model answered that the sentence decides nothing")
        case .unavailable:
            String(localized: "This sentence could not be compared against the meanings.",
                   comment: "Shown on the lookup card when the selector could not run")
        case .refused:
            String(localized: "The model declined to compare this sentence against the meanings.",
                   comment: "Shown on the lookup card when a language model refused to answer for this sentence")
        }
    }
}
