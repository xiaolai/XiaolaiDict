import Foundation
import Testing
import XiaolaiDictTestSupport

@testable import XiaolaiDictCore

/// The one flag in the setup feature, and the one question it answers.
struct SetupPresentationTests {
    @Test func aFreshInstallHasNeverOpenedIt() {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = TemporaryDefaults.suite()
        #expect(!SetupPresentationStore(defaults: defaults).hasOpenedBefore())
    }

    @Test func openingItOnceIsRemembered() {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = TemporaryDefaults.suite()
        let store = SetupPresentationStore(defaults: defaults)
        store.markOpened()
        #expect(store.hasOpenedBefore())
        #expect(SetupPresentationStore(defaults: defaults).hasOpenedBefore(), "it did not reach disk")
    }

    /// Read through `object(forKey:)`, so "never set" and "set to false" stay different. A fresh
    /// install has never set it, and that is exactly the state that must open the window.
    @Test func neverSetAndSetToFalseAreBothClosedButNotTheSameValue() {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = TemporaryDefaults.suite()
        let store = SetupPresentationStore(defaults: defaults)
        #expect(defaults.object(forKey: SetupPresentationStore.defaultsKey) == nil)
        defaults.set(false, forKey: SetupPresentationStore.defaultsKey)
        #expect(!store.hasOpenedBefore())
        #expect(defaults.object(forKey: SetupPresentationStore.defaultsKey) != nil)
    }

    /// The key is pinned as a literal. Renaming it silently re-opens the window for every reader
    /// who has already been through setup, and nothing else would say so.
    @Test func theKeyIsPinned() {
        #expect(SetupPresentationStore.defaultsKey == "SetupWindowShown")
    }
}
