import Foundation
import XiaolaiDictCore

public extension Abstention {
    /// What the panel says instead of a mark. It says why it did not choose, which is the other
    /// half of "the popup can mark a sense, and can say why it did not".
    ///
    /// Here rather than beside the enum in `XiaolaiDictCore`: these are the only sentences the
    /// reader sees from the selector, and a string is only translatable where the catalog can
    /// extract it — `Tools/strings.sh` reads the view layer and the app, never the core.
    var reason: String {
        switch self {
        case .noCandidates:
            String(localized: "This dictionary does not mark its senses, so the one you read cannot be identified.",
                   comment: "Shown on the lookup card when the dictionary marks no senses to choose between")
        case .noContext:
            String(localized: "No sentence was captured around the word, so its senses cannot be told apart.",
                   comment: "Shown on the lookup card when no sentence surrounded the word")
        case .tooClose:
            String(localized: "Several senses fit this sentence equally well.",
                   comment: "Shown on the lookup card when two senses cannot be separated")
        case .nothingFits:
            String(localized: "No sense in this entry clearly fits this sentence.",
                   comment: "Shown on the lookup card when no sense is close enough to claim")
        case .undecided:
            String(localized: "This sentence does not settle which sense the word carries.",
                   comment: "Shown on the lookup card when a model answered that the sentence decides nothing")
        case .unavailable:
            String(localized: "This sentence could not be compared against the senses.",
                   comment: "Shown on the lookup card when the selector could not run")
        case .refused:
            String(localized: "The model declined to compare this sentence against the senses.",
                   comment: "Shown on the lookup card when a language model refused to answer for this sentence")
        }
    }
}
