import DictionaryModel
import Foundation
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// What the Study pane shows before the reader asks to see anything else.
///
/// The pane is a SwiftUI `Form`, which `ImageRenderer` draws as nothing at all, so the decision about
/// what it shows lives in a value that can be asserted.
struct StudyDictionaryPresentationTests {
    private static let oxford = DictionaryCapability(
        identity: DictionaryIdentity(name: "牛津英汉汉英词典", identifier: "com.apple.dictionary.zh_CN-en.OCD"),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "zh_CN", explains: "zh_CN"), .init(index: "en", explains: "zh_CN")],
        indexes: [.latin, .han])
    private static let noad = DictionaryCapability(
        identity: DictionaryIdentity(name: "New Oxford American Dictionary", identifier: DictionaryIdentity.noad),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "en_US", explains: "en_US")], indexes: [.latin])
    private static let longman = DictionaryCapability(
        identity: DictionaryIdentity(name: "Longman"), senseKeyKind: .none, probed: true,
        languages: [], indexes: [.latin])

    /// The default view names the dictionary and offers no list: that is the whole change.
    @Test func aReaderWhoNeverChoseIsToldWhatIsUsedAndNotAskedToChoose() {
        let shown = StudyDictionaryPresentation.of(
            available: [Self.longman, Self.noad, Self.oxford], chosen: nil, automatic: Self.oxford.identity.key)
        #expect(shown == .automatic(Self.oxford))
        #expect(!shown.offersTheListFirst)
    }

    @Test func aReadersOwnChoiceIsShownAsTheirs() {
        let shown = StudyDictionaryPresentation.of(
            available: [Self.noad, Self.oxford], chosen: Self.noad.identity.key, automatic: Self.oxford.identity.key)
        #expect(shown == .chosen(Self.noad))
        #expect(!shown.offersTheListFirst)
    }

    /// A choice that is no longer enabled is not shown as current: lookups have already fallen to the
    /// automatic dictionary, and the pane says what is actually used.
    @Test func aChoiceThatWasDisabledFallsToWhatIsActuallyUsed() {
        let shown = StudyDictionaryPresentation.of(
            available: [Self.oxford], chosen: Self.noad.identity.key, automatic: Self.oxford.identity.key)
        #expect(shown == .automatic(Self.oxford))
    }

    /// **Where nothing can be derived the list is the only way in**, so it is the first thing shown:
    /// a Korean reader, or one whose only dictionaries are sideloaded, would otherwise be left with a
    /// pane that names nothing and offers nothing.
    @Test func whereNothingCanBeDerivedTheListIsOfferedFirst() {
        let shown = StudyDictionaryPresentation.of(available: [Self.longman], chosen: nil, automatic: nil)
        #expect(shown == .listOnly)
        #expect(shown.offersTheListFirst)
        // An automatic key that no longer names an enabled dictionary is the same state.
        #expect(StudyDictionaryPresentation.of(available: [Self.longman], chosen: nil, automatic: "gone") == .listOnly)
        #expect(StudyDictionaryPresentation.of(available: nil, chosen: nil, automatic: nil) == .listOnly)
    }
}
