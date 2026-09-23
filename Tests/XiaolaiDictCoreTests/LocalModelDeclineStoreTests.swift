import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport

/// The model row's Not now: its own flag, as the plan asks, so a decline outlives the app quitting.
struct LocalModelDeclineStoreTests {
    @Test func aDeclineIsRememberedAndCanBeCleared() {
        let defaults = TemporaryDefaults.suite()
        #expect(!LocalModelDeclineStore(defaults: defaults).hasDeclined())
        LocalModelDeclineStore(defaults: defaults).decline()
        #expect(LocalModelDeclineStore(defaults: defaults).hasDeclined(), "a decline did not survive a new store")
        LocalModelDeclineStore(defaults: defaults).clear()
        #expect(!LocalModelDeclineStore(defaults: defaults).hasDeclined())
    }
}
