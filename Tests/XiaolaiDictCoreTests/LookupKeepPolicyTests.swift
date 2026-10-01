import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import XiaolaiDictCore

struct LookupKeepPolicyTests {
    @Test func automaticDefaultManualRestartAndSuiteIsolation() {
        let defaults = TemporaryDefaults.suite()
        let store = LookupKeepPolicyStore(defaults: defaults)
        #expect(store.load() == .automatic)
        store.save(.manual)
        #expect(LookupKeepPolicyStore(defaults: defaults).load() == .manual)
        #expect(LookupKeepPolicyStore(defaults: TemporaryDefaults.suite()).load() == .automatic)
        defaults.set("invalid", forKey: LookupKeepPolicyStore.key)
        #expect(store.load() == .automatic)
    }
}
