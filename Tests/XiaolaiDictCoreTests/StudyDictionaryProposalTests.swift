import DictionaryModel
import Foundation
import Testing

@testable import XiaolaiDictCore

/// The rule that decides what the setup checklist offers for a study dictionary.
///
/// The fixtures are the dictionaries actually enabled on the development Mac, with the languages
/// read off their bundles on 2026-09-22 — so these are the real cases, not invented ones.
struct StudyDictionaryProposalTests {
    private func dictionary(
        _ name: String, _ languages: [DictionaryLanguages], indexes: Set<ProbeScript> = [.latin]
    ) -> DictionaryCapability {
        DictionaryCapability(
            identity: DictionaryIdentity(name: name), senseKeyKind: .publisher, probed: true,
            languages: languages, indexes: indexes)
    }

    private var oxfordChinese: DictionaryCapability {
        dictionary(
            "牛津英汉汉英词典",
            [.init(index: "zh_CN", explains: "zh_CN"), .init(index: "en", explains: "zh_CN")],
            indexes: [.latin, .han])
    }
    private var dreye: DictionaryCapability {
        dictionary(
            "譯典通英漢雙向字典",
            [.init(index: "zh_TW", explains: "zh_TW"), .init(index: "en", explains: "zh_TW")],
            indexes: [.latin, .han])
    }
    private var noad: DictionaryCapability {
        dictionary("New Oxford American Dictionary", [.init(index: "en_US", explains: "en_US")])
    }
    private var thesaurus: DictionaryCapability {
        dictionary("Oxford American Writer's Thesaurus", [.init(index: "en_US", explains: "en_US")])
    }
    /// Every sideloaded conversion: no declared language at all.
    private var longman: DictionaryCapability { dictionary("Longman", []) }

    private var everything: [DictionaryCapability] {
        [oxfordChinese, dreye, noad, thesaurus, longman]
    }

    /// The case the whole feature exists for. Both Chinese dictionaries index English, and only one
    /// of them explains in Simplified — so this is a proposal rather than a question.
    @Test func aSimplifiedChineseReaderIsProposedExactlyOneDictionary() {
        #expect(
            StudyDictionaryProposal.forReader(of: "zh-Hans-CN", among: everything)
                == .propose(oxfordChinese))
    }

    @Test func aTraditionalChineseReaderIsProposedTheOtherOne() {
        #expect(
            StudyDictionaryProposal.forReader(of: "zh-Hant-TW", among: everything)
                == .propose(dreye))
    }

    /// English is not a special case in the code, only in its outcome: several dictionaries explain
    /// English in English, so the rule itself asks the reader.
    @Test func anEnglishReaderIsAskedBecauseSeveralSuitThem() {
        let proposal = StudyDictionaryProposal.forReader(of: "en-US", among: everything)
        #expect(proposal == .choose([noad, thesaurus]))
    }

    /// Dictionary.app's order is the reader's own, and nothing here re-sorts it.
    ///
    /// Matched against the whole case rather than a flattened list of names: which case the rule
    /// reached is half of what it decided, and comparing names alone would pass for a `.propose`
    /// that had somehow grown two.
    @Test func theReadersOwnOrderSurvives() {
        let proposal = StudyDictionaryProposal.forReader(
            of: "en", among: [thesaurus, longman, noad])
        #expect(proposal == .choose([thesaurus, noad]))
    }

    /// A Korean reader with only these dictionaries has nothing suitable — and XiaolaiDict cannot
    /// enable the one they need, so saying so is the whole answer.
    @Test func aReaderWithNoSuitableDictionaryIsToldSo() {
        #expect(StudyDictionaryProposal.forReader(of: "ko", among: everything) == .nothingSuitable)
    }

    @Test func noDictionariesAtAllIsNothingSuitableRatherThanAnEmptyChoice() {
        #expect(StudyDictionaryProposal.forReader(of: "en", among: []) == .nothingSuitable)
    }

    /// A sideloaded dictionary is never proposed, however it probed. It really does index English,
    /// but what it explains in is unknowable from a records probe, and proposing on that guess
    /// would hand an English-Chinese bilingual to a reader of English.
    @Test func aDictionaryDeclaringNothingIsNeverTheProposal() {
        #expect(
            StudyDictionaryProposal.forReader(of: "en", among: [longman]) == .nothingSuitable)
        // And it does not dilute a real answer into a question.
        #expect(
            StudyDictionaryProposal.forReader(of: "zh-Hans", among: [oxfordChinese, longman])
                == .propose(oxfordChinese))
    }

    // MARK: - The dictionary chosen for a reader who is not asked

    private func keyed(_ name: String, _ kind: SenseKeyKind, identifier: String? = nil,
                       languages: [DictionaryLanguages]) -> DictionaryCapability {
        DictionaryCapability(
            identity: DictionaryIdentity(name: name, identifier: identifier), senseKeyKind: kind,
            probed: true, languages: languages, indexes: [.latin])
    }

    /// NOAD as Apple ships it: the identifier is what the preference below keys on, never the name.
    private var realNoad: DictionaryCapability {
        keyed("New Oxford American Dictionary", .publisher, identifier: DictionaryIdentity.noad,
              languages: [.init(index: "en_US", explains: "en_US")])
    }

    /// A Chinese reader is never asked: exactly one enabled dictionary teaches them English, and
    /// that one is the study dictionary. Another dictionary being first in Dictionary.app's order
    /// changes nothing.
    @Test func aChineseReaderGetsTheDictionaryTheirLanguageNames() {
        let enabled = [longman, noad, thesaurus, oxfordChinese, dreye]
        #expect(StudyDictionaryProposal.automatic(for: "zh-Hans-CN", among: enabled) == oxfordChinese)
        #expect(StudyDictionaryProposal.automatic(for: "zh-Hant-TW", among: enabled) == dreye)
        #expect(StudyDictionaryProposal.automatic(for: "zh-Hans-SG", among: enabled) == oxfordChinese,
                "Singapore is Simplified")
    }

    /// An English reader has several suitable dictionaries, and the rule's answer is NOAD: it is
    /// the only one the accuracy figures describe. A thesaurus that the reader ranked first in
    /// Dictionary.app does not become the dictionary they study from.
    @Test func anEnglishReaderGetsNOADWhateverTheOrder() {
        let enabled = [thesaurus, longman, realNoad]
        #expect(StudyDictionaryProposal.automatic(for: "en-US", among: enabled) == realNoad)
    }

    /// Without NOAD the reader's own order decides, but a dictionary that can key a sense beats one
    /// that cannot: a primary that cannot key is a primary that can never produce a sense-level card.
    @Test func withoutNOADTheFirstThatCanKeyASenseWins() {
        let english = [DictionaryLanguages(index: "en_GB", explains: "en_GB")]
        let wholeEntries = keyed("Whole entries", .none, languages: english)
        let positional = keyed("Positional", .position, languages: english)
        let publisher = keyed("Publisher", .publisher, languages: english)
        #expect(StudyDictionaryProposal.automatic(for: "en-GB", among: [wholeEntries, positional, publisher])
            == positional)
        #expect(StudyDictionaryProposal.automatic(for: "en-GB", among: [wholeEntries]) == wholeEntries,
                "if none can, an entry-level study item is still a study item")
    }

    @Test func aReaderNothingSuitsGetsNoAutomaticDictionary() {
        #expect(StudyDictionaryProposal.automatic(for: "ko", among: everything) == nil)
        #expect(StudyDictionaryProposal.automatic(for: "en", among: []) == nil)
        // A dictionary declaring nothing is never chosen for a reader, as with the proposal.
        #expect(StudyDictionaryProposal.automatic(for: "en", among: [longman]) == nil)
    }

    /// **One rule, two spellings, and they must not drift.** The setup board branches on the proposal
    /// and the lookup on this; if they disagreed, a reader would be told nothing suits them while
    /// lookups studied from something, or the reverse.
    @Test func theAutomaticChoiceExistsExactlyWhereTheProposalIsNotNothingSuitable() {
        let sets: [[DictionaryCapability]] = [
            [], [longman], [noad], [oxfordChinese], [dreye, oxfordChinese], everything, [thesaurus, noad, realNoad],
        ]
        for language in ["en", "en-US", "zh-Hans", "zh-Hant-HK", "ko", "ja", "yue", "fr"] {
            for enabled in sets {
                let proposed = StudyDictionaryProposal.forReader(of: language, among: enabled) != .nothingSuitable
                #expect((StudyDictionaryProposal.automatic(for: language, among: enabled) != nil) == proposed,
                        "\(language) over \(enabled.map(\.identity.name))")
            }
        }
    }

    /// The reader's language comes from the system's list, never from `Locale.current`.
    ///
    /// **The two are distinguishable here, which is what keeps this from being a restatement of a
    /// one-line body.** Measured on the development Mac 2026-09-24: `Locale.preferredLanguages`
    /// answers `en-US` and `Locale.current.identifier` answers `en_US`. So the first assertion
    /// fails outright if the source is ever swapped, and the second says *how* they differ —
    /// a language tag, not a bundle-style identifier, which is the shape `DictionaryLanguages.tag`
    /// and everything downstream of it is given.
    @Test func theReadersLanguageIsTakenFromTheSystemList() {
        #expect(ReaderLanguage.preferred == Locale.preferredLanguages.first)
        #expect(!ReaderLanguage.preferred.contains("_"), "\(ReaderLanguage.preferred) is not a language tag")
        #expect(!ReaderLanguage.preferred.isEmpty)
    }
}
