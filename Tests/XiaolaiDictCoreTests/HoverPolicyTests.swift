import Foundation
import XiaolaiDictCore
import Testing

/// The three gates the feature ledger marks P0 for hover — a held modifier (A4), per-app and
/// per-site exclusion (A3), and a pause switch (A5) — plus the two the design note calls
/// non-negotiable: debouncing, and never two captures at once.
struct HoverPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = HoverPolicy.shipped
    private let reading = HoverSite(bundleID: "com.apple.Preview", host: nil, wordKey: "hold@1")

    private func decide(
        _ site: HoverSite? = nil, held: Set<HoverModifier> = [.option],
        still: Duration = .milliseconds(500), pausedUntil: Date? = nil,
        lastLookedUp: String? = nil, capturing: Bool = false, policy: HoverPolicy? = nil
    ) -> HoverDecision {
        (policy ?? self.policy).decide(
            at: site ?? reading, modifiersHeld: held, pointerStillFor: still,
            pausedUntil: pausedUntil, lastLookedUp: lastLookedUp, captureInFlight: capturing, now: now)
    }

    /// The ordinary case: the reader is reading, and the pointer does nothing.
    @Test func withoutTheModifierNothingHappens() {
        #expect(decide(held: []) == .stayQuiet(.modifierNotHeld))
        #expect(decide(held: [.command]) == .stayQuiet(.modifierNotHeld))
    }

    @Test func withTheModifierHeldItLooks() {
        #expect(decide() == .look)
        #expect(decide(held: [.option, .shift]) == .look, "an extra modifier should not veto")
    }

    /// A hover with no modifier is the design this prevents, so it cannot be configured.
    @Test func thereIsNoModifierlessConfiguration() {
        #expect(!HoverModifier.allCases.isEmpty)
        for modifier in HoverModifier.allCases {
            let strict = HoverPolicy(
                modifier: modifier, excludedApps: [], excludedHosts: [], settleMilliseconds: 0)
            #expect(strict.decide(
                at: reading, modifiersHeld: [], pointerStillFor: .seconds(10), pausedUntil: nil,
                lastLookedUp: nil, captureInFlight: false, now: now) == .stayQuiet(.modifierNotHeld))
        }
    }

    // MARK: - A3, exclusion

    /// Password managers are a **safety** exclusion and ship excluded. The ledger stores the
    /// sentence a word was read in, so a lookup in a password manager would write a secret to disk;
    /// there the whole surface is secrets, which is what makes it a rule rather than a preference.
    @Test func itShipsExcludingPasswordManagers() {
        #expect(policy.excludedApps.contains("com.1password.1password"))
        #expect(decide(HoverSite(bundleID: "com.1password.1password")) == .stayQuiet(.excludedApp))
    }

    /// Terminals are **not** excluded by default, and this is a reversal.
    ///
    /// The screen-word spike measured hover working in Ghostty — finding 12, "OCR is the only path
    /// there" — and the exclusion, not the machinery, is what removed it. The rationale it shipped
    /// under was that a popup over a half-typed command is worse than useless, which underweights
    /// the gate shipping beside it: `HoverModifier` has no "none" case, so hover in a terminal only
    /// ever fires when the reader deliberately holds the modifier and rests the pointer. It cannot
    /// arrive over a half-typed command by accident.
    @Test func terminalsAreReadableByDefault() {
        #expect(!policy.excludedApps.contains("com.mitchellh.ghostty"))
        #expect(!policy.excludedApps.contains("com.apple.Terminal"))
        #expect(decide(HoverSite(bundleID: "com.mitchellh.ghostty")) != .stayQuiet(.excludedApp))
    }

    /// The set is still named, because a reader who wants the old behaviour should not have to
    /// enumerate six bundle identifiers to get it.
    @Test func terminalsRemainANamedSetAReaderCanExclude() {
        var quiet = policy
        quiet.excludedApps.formUnion(HoverPolicy.terminals)
        #expect(decide(HoverSite(bundleID: "com.mitchellh.ghostty"), policy: quiet) == .stayQuiet(.excludedApp))
        #expect(decide(HoverSite(bundleID: "net.kovidgoyal.kitty"), policy: quiet) == .stayQuiet(.excludedApp))
    }

    @Test func aSiteCanBeExcluded() {
        var strict = policy
        strict.excludedHosts = ["bank.example.com"]
        #expect(decide(HoverSite(bundleID: "com.apple.Safari", host: "bank.example.com"), policy: strict)
            == .stayQuiet(.excludedSite))
        #expect(decide(HoverSite(bundleID: "com.apple.Safari", host: "news.example.com"), policy: strict) == .look)
    }

    /// Excluding a host excludes its subdomains: a reader who excluded `example.com` did not mean
    /// to leave `secure.example.com` open.
    @Test func excludingAHostExcludesItsSubdomains() {
        var strict = policy
        strict.excludedHosts = ["example.com"]
        #expect(decide(HoverSite(bundleID: "com.apple.Safari", host: "secure.example.com"), policy: strict)
            == .stayQuiet(.excludedSite))
        // …but not a different registrable name that merely ends the same way.
        #expect(decide(HoverSite(bundleID: "com.apple.Safari", host: "notexample.com"), policy: strict) == .look)
    }

    // MARK: - A5, pause

    @Test func aPausedXiaolaiDictStaysQuiet() {
        #expect(decide(pausedUntil: now.addingTimeInterval(60)) == .stayQuiet(.paused))
        #expect(decide(pausedUntil: now.addingTimeInterval(-1)) == .look, "a lapsed pause still silenced it")
    }

    @Test func pausingAndResumingAreOneClickEach() {
        var pause = HoverPause()
        #expect(!pause.isPaused(at: now))
        pause.pause(for: .seconds(3_600), from: now)
        #expect(pause.isPaused(at: now))
        #expect(pause.isPaused(at: now.addingTimeInterval(3_500)))
        #expect(!pause.isPaused(at: now.addingTimeInterval(3_700)))
        pause.resume()
        #expect(!pause.isPaused(at: now))
    }

    /// A paused XiaolaiDict must never be *silently* paused, or it reads as broken.
    @Test func theMenuSaysWhenItIsPaused() {
        var pause = HoverPause()
        #expect(pause.label(at: now) == "Pause Hover…")
        pause.pause(for: .seconds(3_600), from: now)
        #expect(pause.label(at: now).contains("Paused"))
    }

    // MARK: - Debounce, and never two captures

    /// Debouncing is non-negotiable: without it, crossing a line of text is a dozen lookups.
    @Test func aMovingPointerIsNotAHover() {
        #expect(decide(still: .milliseconds(10)) == .stayQuiet(.stillMoving))
        #expect(decide(still: .milliseconds(179)) == .stayQuiet(.stillMoving))
        #expect(decide(still: .milliseconds(180)) == .look)
    }

    /// Two simultaneous `SCScreenshotManager` captures deadlock — measured 6 times out of 6 — so a
    /// second one is refused rather than started.
    @Test func aSecondCaptureIsRefusedWhileOneIsRunning() {
        #expect(decide(capturing: true) == .stayQuiet(.captureInFlight))
    }

    /// Resting on the same word must not look it up again and again.
    @Test func theSameWordIsNotLookedUpTwice() {
        #expect(decide(lastLookedUp: "hold@1") == .stayQuiet(.samePlace))
        #expect(decide(lastLookedUp: "fine@2") == .look)
    }

    /// The commonest refusal is checked first, so a reader who is simply reading never pays for
    /// Accessibility, an exclusion lookup, or a clock read.
    @Test func theCommonestRefusalIsCheckedFirst() {
        let excludedAndUnmodified = HoverSite(bundleID: "com.apple.Terminal")
        #expect(decide(excludedAndUnmodified, held: []) == .stayQuiet(.modifierNotHeld))
    }

    /// Every refusal can be shown to the reader: "nothing happened" with no reason is
    /// indistinguishable from a bug.
    @Test(arguments: HoverRefusal.allCases)
    func everyRefusalHasSomethingToSay(refusal: HoverRefusal) {
        #expect(!refusal.reason.isEmpty)
    }
}

/// Found by audit: an exclusion that a different capitalisation walks past is not an exclusion.
struct HoverHostMatchingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func excluded(_ host: String, by names: Set<String>) -> Bool {
        var policy = HoverPolicy.shipped
        policy.excludedHosts = names
        return policy.decide(
            at: HoverSite(bundleID: "com.apple.Safari", host: host), modifiersHeld: [.option],
            pointerStillFor: .seconds(1), pausedUntil: nil, lastLookedUp: nil,
            captureInFlight: false, now: now) == .stayQuiet(.excludedSite)
    }

    /// Host names are case-insensitive. `EXAMPLE.COM` is the site the reader excluded.
    @Test(arguments: ["EXAMPLE.COM", "Example.Com", "example.com", "SECURE.Example.COM"])
    func caseDoesNotDefeatAnExclusion(host: String) {
        #expect(excluded(host, by: ["example.com"]))
    }

    /// A trailing root dot is the same name in DNS, and is how a link can be written.
    @Test(arguments: ["example.com.", "EXAMPLE.COM.", "secure.example.com."])
    func aTrailingDotDoesNotDefeatAnExclusion(host: String) {
        #expect(excluded(host, by: ["example.com"]))
    }

    /// The reader's own entry is normalised too, so a mistyped exclusion still works.
    @Test func theConfiguredNameIsNormalisedAsWell() {
        #expect(excluded("example.com", by: ["EXAMPLE.COM."]))
        #expect(excluded("secure.example.com", by: [" Example.Com "]))
    }

    /// Still not over-broad: a different registrable name that merely ends the same way is not it.
    @Test(arguments: ["notexample.com", "example.com.evil.test", "fooexample.com"])
    func itDoesNotExcludeADifferentSite(host: String) {
        #expect(!excluded(host, by: ["example.com"]))
    }

    @Test func anEmptyNameExcludesNothing() {
        #expect(!excluded("example.com", by: [""]))
        #expect(!excluded("", by: ["example.com"]))
    }
}
