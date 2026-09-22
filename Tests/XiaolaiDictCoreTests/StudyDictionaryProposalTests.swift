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
    @Test func theReadersOwnOrderSurvives() {
        let proposal = StudyDictionaryProposal.forReader(
            of: "en", among: [thesaurus, longman, noad])
        #expect(proposal.candidates.map(\.identity.name) == [thesaurus, noad].map(\.identity.name))
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

    /// The reader's language comes from the system's list, never from the bundle's.
    @Test func theReadersLanguageIsTakenFromTheSystemList() {
        #expect(ReaderLanguage.preferred == Locale.preferredLanguages.first)
        #expect(!ReaderLanguage.preferred.isEmpty)
    }
}
