import Foundation
@testable import ModelKit
import Testing
import XiaolaiDictTestSupport

struct ModelSourceStoreTests {
    /// **Unset is `fastest`**, and a value this build does not know is too: a half-written or
    /// foreign preference must not leave a download with nowhere to go.
    @Test(arguments: [nil, "gibberish", "", "HuggingFace"] as [String?])
    func anythingUnreadableIsTheDefault(stored: String?) {
        let defaults = TemporaryDefaults.suite()
        if let stored { defaults.set(stored, forKey: ModelSourceStore.defaultsKey) }
        #expect(ModelSourceStore(defaults: defaults).load() == .fastest)
    }

    @Test(arguments: ModelSource.allCases)
    func whatIsSavedIsWhatComesBack(source: ModelSource) {
        let store = ModelSourceStore(defaults: TemporaryDefaults.suite())
        store.save(source)
        #expect(store.load() == source)
    }

    /// **A named host is an order, a measured one is not.** `fastest` has no fixed order — that
    /// is the whole difference — and ModelScope alone is never departed from.
    @Test func anamedHostDecidesTheOrderAndModelScopeIsNeverDeparted() {
        #expect(ModelSource.fastest.fixedOrder == nil)
        #expect(ModelSource.modelScope.fixedOrder == [.modelScope])
        #expect(ModelSource.huggingFace.fixedOrder == [.huggingFace, .modelScope])
        // Every fixed order can serve a download: the canonical host has every file.
        for source in ModelSource.allCases {
            guard let order = source.fixedOrder else { continue }
            #expect(order.contains(.modelScope), "\(source) can reach no host that has the licence")
        }
    }
}

struct ModelChoiceStoreTests {
    /// **Unset is nil, not a size.** "They have not said" and "they chose the smallest" lead to
    /// different answers — the first takes the largest that fits, the second does not.
    @Test func unsetIsNoChoiceRatherThanAsmallOne() {
        #expect(ModelChoiceStore(defaults: TemporaryDefaults.suite()).load() == nil)
    }

    /// A value this build does not know is no choice either, rather than a crash or a default
    /// that silently overrides what the reader actually picked on a later version.
    @Test func avalueThisBuildDoesNotKnowIsNoChoice() {
        let defaults = TemporaryDefaults.suite()
        defaults.set("enormous", forKey: ModelChoiceStore.defaultsKey)
        #expect(ModelChoiceStore(defaults: defaults).load() == nil)
    }

    @Test(arguments: LocalModelSize.allCases)
    func whatIsChosenComesBack(size: LocalModelSize) {
        let store = ModelChoiceStore(defaults: TemporaryDefaults.suite())
        store.save(size)
        #expect(store.load() == size)
        // And it can be taken back, which is what removing the chosen model has to do.
        store.save(nil)
        #expect(store.load() == nil)
    }
}
