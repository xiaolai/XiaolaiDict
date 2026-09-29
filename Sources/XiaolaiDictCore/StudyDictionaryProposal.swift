import DictionaryModel
import Foundation

/// Which dictionary the reader should study English from, before they have chosen one.
///
/// One rule, with no branch for "is the system English": a dictionary suits a reader of language L
/// when it indexes English and explains in L. English readers land in `choose` rather than
/// `propose` because several of their dictionaries satisfy that — NOAD, the Writer's Thesaurus and
/// every English learner's dictionary — which *is* "let the reader pick", arrived at by the rule
/// rather than by a special case.
///
/// **This never decides for a reader who has already chosen.** Switching the primary dictionary
/// starts study over, because `StudyItem` is keyed by dictionary, so a proposal is only ever made
/// into an empty seat.
public enum StudyDictionaryProposal: Sendable, Equatable {
    /// Exactly one enabled dictionary suits this reader. Offer it.
    case propose(DictionaryCapability)
    /// Several do. Naming a favourite among them would be a coin toss dressed as a recommendation,
    /// so the reader is asked — and these are the ones worth asking about.
    case choose([DictionaryCapability])
    /// None does, and **XiaolaiDict cannot enable one**: the inactive dictionaries are undownloaded
    /// MobileAssets, and the active list belongs to Dictionary.app. The only honest move is to say
    /// which kind is missing and open Dictionary.app.
    case nothingSuitable

    /// Applies the rule.
    ///
    /// Input order is preserved throughout — it is Dictionary.app's order, which is the reader's
    /// own and the only ordering here that means anything.
    public static func forReader(
        of language: String, among dictionaries: [DictionaryCapability]
    ) -> StudyDictionaryProposal {
        let suitable = dictionaries.filter { $0.teachesEnglish(to: language) }
        switch suitable.count {
        case 0: return .nothingSuitable
        case 1: return .propose(suitable[0])
        default: return .choose(suitable)
        }
    }
}
