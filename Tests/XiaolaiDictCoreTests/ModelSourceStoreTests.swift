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
