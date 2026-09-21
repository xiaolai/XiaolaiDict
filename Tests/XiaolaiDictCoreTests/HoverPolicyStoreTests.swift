import Foundation
import XiaolaiDictCore
import Testing
import XiaolaiDictTestSupport

/// The hover policy, kept across launches.
///
/// `HoverPolicy` has been `Codable` with four settable fields since it was written, and
/// `HoverReader`/`HoverWatcher` have always taken it as a closure — a shape built for a value that
/// changes. Until now the only value that existed was the hardcoded `.shipped`, so the reader
/// could not choose a modifier, exclude an app or a site, or change how long the pointer must
/// rest. This is the store that makes those real.
struct HoverPolicyStoreTests {
    private func store() -> (HoverPolicyStore, UserDefaults) {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = TemporaryDefaults.suite()
        return (HoverPolicyStore(defaults: defaults), defaults)
    }

    @Test func withNothingSavedItIsTheShippedPolicy() {
        let (store, _) = store()
        #expect(store.load() == .shipped)
    }

    @Test func whatTheReaderChoseSurvivesALaunch() {
        let (store, defaults) = store()
        var chosen = HoverPolicy.shipped
        chosen.modifier = .control
        chosen.settleMilliseconds = 400
        chosen.excludedHosts = ["example.com"]
        store.save(chosen)

        let reopened = HoverPolicyStore(defaults: defaults).load()
        #expect(reopened.modifier == .control)
        #expect(reopened.settleMilliseconds == 400)
        #expect(reopened.excludedHosts == ["example.com"])
    }

    /// **Unreadable is the default, never a failure and never an empty policy.** A preferences
    /// file written by a later version, or half-written by a crash, must not leave the reader with
    /// no modifier gate and no exclusions — which is the one state this whole type exists to
    /// prevent.
    @Test func anUnreadableValueFallsBackToShipped() {
        let (store, defaults) = store()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: HoverPolicyStore.defaultsKey)
        #expect(store.load() == .shipped)
    }

    @Test func aValueOfTheWrongTypeAltogetherFallsBackToShipped() {
        let (store, defaults) = store()
        defaults.set("not a policy", forKey: HoverPolicyStore.defaultsKey)
        #expect(store.load() == .shipped)
    }

    /// **The password-manager exclusion is a rule, not a preference, so loading restores it.**
    /// The ledger stores the sentence a word was read in, so a lookup in a password manager writes
    /// a secret to disk — there the whole surface is secrets. A stored policy that has lost them,
    /// however it lost them, is corrected on the way in rather than trusted.
    @Test func aStoredPolicyCannotDropThePasswordManagers() {
        let (store, defaults) = store()
        var permissive = HoverPolicy.shipped
        permissive.excludedApps = []
        store.save(permissive)

        let reopened = HoverPolicyStore(defaults: defaults).load()
        #expect(reopened.excludedApps.isSuperset(of: HoverPolicy.defaultExcludedApps),
                "a saved policy dropped the password managers and the store believed it")
    }

    /// What the reader adds is kept alongside the rule, not replaced by it.
    @Test func theReadersOwnExclusionsAreKept() {
        let (store, defaults) = store()
        var chosen = HoverPolicy.shipped
        chosen.excludedApps.insert("com.example.Diary")
        store.save(chosen)

        let reopened = HoverPolicyStore(defaults: defaults).load()
        #expect(reopened.excludedApps.contains("com.example.Diary"))
        #expect(reopened.excludedApps.isSuperset(of: HoverPolicy.defaultExcludedApps))
    }
}
