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

    /// Forgetting restores a fresh install's *behaviour* and nothing else — no dictionary, no
    /// shortcut and no permission is touched, because none of them is stored here.
    @Test func forgettingOnlyAffectsWhetherItOpensByItself() {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = TemporaryDefaults.suite()
        defaults.set("com.apple.dictionary.NOAD", forKey: "PrimaryDictionary")
        let store = SetupPresentationStore(defaults: defaults)
        store.markOpened()
        store.forget()
        #expect(!store.hasOpenedBefore())
        #expect(defaults.string(forKey: "PrimaryDictionary") == "com.apple.dictionary.NOAD")
    }

    /// The key is pinned as a literal. Renaming it silently re-opens the window for every reader
    /// who has already been through setup, and nothing else would say so.
    @Test func theKeyIsPinned() {
        #expect(SetupPresentationStore.defaultsKey == "SetupWindowShown")
    }
}
