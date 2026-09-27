import DictionaryModel
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
            at: site ?? reading, modifiersHeld: held, tappedTwice: false, pointerStillFor: still,
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
                at: reading, modifiersHeld: [], tappedTwice: false, pointerStillFor: .seconds(10), pausedUntil: nil,
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
    ///
    /// **The site has to be one the shipped policy really excludes, or the order is not under
    /// test.** This asked about `com.apple.Terminal`, which stopped being excluded when terminals
    /// were un-excluded — after which `.modifierNotHeld` was the only refusal the site could
    /// produce whatever order the guards were in, and the check passed by construction. A password
    /// manager is excluded by `defaultExcludedApps`, so the site can answer either way and the
    /// order is what decides which.
    @Test func theCommonestRefusalIsCheckedFirst() {
        let excludedAndUnmodified = HoverSite(bundleID: "com.1password.1password")
        #expect(decide(excludedAndUnmodified) == .stayQuiet(.excludedApp), "the fixture is not excluded")
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
            at: HoverSite(bundleID: "com.apple.Safari", host: host), modifiersHeld: [.option], tappedTwice: false,
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

    /// **Each pause length has to say how long it is**, because the menu offers three and a row
    /// reading "900 seconds" is not an offer anyone can act on. `HoverPause.durations` shipped as
    /// a list with nothing to render it, which is part of why the switch was never built.
    @Test func eachPauseLengthNamesItself() {
        let named = HoverPause.durations.map { HoverPause.name(of: $0, in: Locale(identifier: "en_US")) }
        #expect(named == ["15 minutes", "1 hour", "8 hours"], "the menu would read \(named)")
    }

    // MARK: - Naming the modifier

    /// **The modifier has to name itself, because two surfaces show it and one of them lied.**
    /// The menu read "Hover Lookup    hold ⌥" as a literal while `HoverModifier` had four cases,
    /// so the label was correct only for as long as the modifier could not be changed. Making it
    /// changeable without this would have shipped a menu that confidently names the wrong key.
    ///
    /// Asserted over `allCases` as one list, the way the written names are: a case added later
    /// fails here rather than sliding past a set of four per-case assertions that never mention it.
    @Test func everyModifierCarriesItsKeySymbol() {
        #expect(HoverModifier.allCases.map(\.symbol) == ["\u{2325}", "\u{2303}", "\u{2318}", "\u{21E7}"])
    }

    /// And a written name, for a picker where a lone symbol is a guessing game.
    @Test func everyModifierCarriesAWrittenName() {
        #expect(HoverModifier.allCases.map(\.name) == ["Option", "Control", "Command", "Shift"])
    }


    // MARK: - The rest the reader can choose

    /// **The shipped rest must be one the picker can show.** A `Picker` whose selection matches no
    /// tag renders with nothing selected — the reader opens Settings, sees an empty control, picks
    /// something to fill it, and has silently changed a setting they only meant to look at. It
    /// costs one comparison to make that unrepresentable.
    @Test func theShippedRestIsOneOfTheOfferedOnes() {
        #expect(HoverPolicy.settleChoices.map(\.milliseconds).contains(HoverPolicy.shipped.settleMilliseconds),
                "the picker would open with nothing selected")
    }

    @Test func theOfferedRestsAreDistinctAndInOrder() {
        let values = HoverPolicy.settleChoices.map(\.milliseconds)
        #expect(values == values.sorted(), "the picker would read out of order")
        #expect(Set(values).count == values.count, "two choices share a value, so one cannot be picked")
    }

    /// Every one names itself, because "180" is not a choice anyone can make.
    @Test func everyRestIsNamed() {
        for choice in HoverPolicy.settleChoices {
            #expect(!choice.name.isEmpty, "\(choice.milliseconds) ms has no name")
        }
    }
}

extension HoverPolicyTests {
    /// **Decided after the word is read, never in `decide`.** The gate runs before any text
    /// exists — that is what makes it cheap — so the script of the word cannot be one of its
    /// inputs. This is the second line, beside the repeat check.
    @Test func aWordInAScriptTheReaderDoesNotStudyIsNotLookedUp() {
        var policy = HoverPolicy.shipped
        policy.scripts = [.latin]
        #expect(policy.studies("hold"))
        #expect(!policy.studies("水"), "a han word was looked up under a Latin-only policy")
        #expect(!policy.studies("하다"))
    }

    /// The reader who wants both gets both. This is the setting's whole point: a reader whose
    /// study dictionary is 譯典通 studies han, and the same switch serves them.
    @Test func aReaderWhoStudiesBothScriptsGetsBoth() {
        var policy = HoverPolicy.shipped
        policy.scripts = [.latin, .han]
        #expect(policy.studies("hold"))
        #expect(policy.studies("水"))
        #expect(!policy.studies("する"), "kana was not asked for")
    }

    /// **What cannot be classified is looked up.** A capture of `42`, of punctuation, or of a
    /// script this does not know names no script at all — and refusing there would make the filter
    /// quietly wider than the reader set it, in exactly the cases where OCR is least sure.
    @Test func textInNoScriptAtAllIsStillLookedUp() {
        var policy = HoverPolicy.shipped
        policy.scripts = [.latin]
        #expect(policy.studies("42"))
        #expect(policy.studies("—"))
        #expect(policy.studies(""))
    }

    /// The refusal says something a reader could act on. Every other refusal here is silent
    /// because "you did not hold the modifier" explains itself; this one does not.
    @Test func theScriptRefusalExplainsItself() {
        #expect(!HoverRefusal.scriptNotStudied.reason.isEmpty)
        #expect(HoverRefusal.scriptNotStudied.reason != HoverRefusal.excludedApp.reason)
    }

    /// **A pause is a duration, not a whole number of seconds.** `Duration.components` splits into
    /// seconds and attoseconds, and reading only the first threw the remainder away: a pause of
    /// 1.5 s lasted 1 s, and anything under a second expired the instant it was set. The shipped
    /// menu offers 15 minutes and up, so nothing reachable today is wrong — which is exactly why
    /// it would have gone on being wrong the day a shorter one was offered.
    @Test func aPauseKeepsTheFractionOfASecondItWasGiven() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var pause = HoverPause()
        pause.pause(for: .milliseconds(1_500), from: start)
        #expect(pause.until == start.addingTimeInterval(1.5))

        pause.pause(for: .milliseconds(500), from: start)
        #expect(pause.until == start.addingTimeInterval(0.5), "a sub-second pause expired at once")
    }

    /// **The gaps in the classifier were holes in this gate**, so the regression belongs here too
    /// and not only where the classifier is tested. Text the classifier cannot name is looked up on
    /// purpose, which means every script it failed to recognise walked through a filter set to
    /// exclude it: halfwidth katakana, han past the basic plane, and Latin beyond `0x024F`.
    @Test func theFilterHoldsForEveryFormOfTheScriptsItNames() {
        var latinOnly = HoverPolicy.shipped
        latinOnly.scripts = [.latin]
        for refused in ["ｶﾀｶﾅ", "𠮷", "한글", "水", "\u{1B001}", "㌍"] {
            #expect(!latinOnly.studies(refused), "\(refused) walked through a Latin-only filter")
        }
        for allowed in ["hold", "ế", "naïve", "ﬀ", "ＡＢＣ"] {
            #expect(latinOnly.studies(allowed), "\(allowed) is Latin and was refused")
        }
    }

    /// Greek is not Latin, however close its block sits. A reader who ticks Latin alone has not
    /// asked for Greek, and the widened Latin ranges briefly gave it to them.
    @Test func widerLatinDidNotQuietlyAdmitGreek() {
        var latinOnly = HoverPolicy.shipped
        latinOnly.scripts = [.latin]
        // Unclassified, so it is looked up — the permissive default, not a Latin match. What must
        // never happen is it being *counted* as Latin, which is what the block sweep did.
        #expect(ProbeScript.dominant(in: "\u{AB65}") != .latin)
    }
}

/// **The second way to ask for a lookup: tap the modifier twice.**
///
/// Holding a modifier is a weak statement of intent, because every modifier already means
/// something. ⌥ is Meta in a terminal, it types special characters, and it modifies clicks and
/// drags — so a reader who holds it for any of those, with the pointer at rest over text, gets a
/// lookup they did not ask for. Two presses inside a short window, with the pointer already still,
/// is a thing nobody does by accident.
///
/// Tap-once was considered and refused: a bare modifier is *abandoned* constantly — pressed, then
/// thought better of, then released — and that is indistinguishable from a deliberate tap without
/// waiting to see whether a chord follows. It would fire more often than holding does, which is
/// the opposite of the point.
struct HoverGestureTests {
    private static func policy(_ gesture: HoverGesture) -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.gesture = gesture
        return policy
    }

    private static let still = Duration.milliseconds(500)

    private func decision(
        _ gesture: HoverGesture, held: Set<HoverModifier>, tappedTwice: Bool
    ) -> HoverDecision {
        Self.policy(gesture).decide(
            at: HoverSite(bundleID: nil), modifiersHeld: held, tappedTwice: tappedTwice,
            pointerStillFor: Self.still, pausedUntil: nil, lastLookedUp: nil,
            captureInFlight: false, now: .now)
    }

    @Test func holdingIsWhatTheDefaultGestureAsksFor() {
        #expect(HoverPolicy.shipped.gesture == .hold, "the shipped gesture changed")
        #expect(decision(.hold, held: [.option], tappedTwice: false) == .look)
        #expect(decision(.hold, held: [], tappedTwice: false) == .stayQuiet(.modifierNotHeld))
    }

    /// **A tap is not a hold, and the key is released by the time the lookup runs.** Requiring the
    /// modifier to still be down would make the gesture a hold with extra steps.
    @Test func aDoubleTapDoesNotRequireTheKeyToStillBeDown() {
        #expect(decision(.doubleTap, held: [], tappedTwice: true) == .look)
    }

    /// And merely holding the key does nothing when the reader asked for taps.
    @Test func holdingAloneDoesNothingUnderTheTapGesture() {
        #expect(decision(.doubleTap, held: [.option], tappedTwice: false) == .stayQuiet(.notTapped))
    }

    /// **The two gestures do not leak into each other.** A double-tap under the hold gesture is
    /// just a key going up and down, and must not look anything up on its own.
    @Test func aTapUnderTheHoldGestureIsNotATrigger() {
        #expect(decision(.hold, held: [], tappedTwice: true) == .stayQuiet(.modifierNotHeld))
    }

    /// Every other refusal still applies — the gesture decides *whether the reader asked*, not
    /// whether the answer may be given.
    @Test func aDoubleTapIsStillSubjectToEveryOtherRefusal() {
        var policy = Self.policy(.doubleTap)
        policy.excludedApps = ["com.example.vault"]
        let decision = policy.decide(
            at: HoverSite(bundleID: "com.example.vault"), modifiersHeld: [], tappedTwice: true,
            pointerStillFor: Self.still, pausedUntil: nil, lastLookedUp: nil,
            captureInFlight: false, now: .now)
        #expect(decision == .stayQuiet(.excludedApp))
    }

    /// A tap while the pointer is still moving is the reader repositioning, not asking.
    @Test func aDoubleTapWhileThePointerIsMovingIsRefused() {
        let decision = Self.policy(.doubleTap).decide(
            at: HoverSite(bundleID: nil), modifiersHeld: [], tappedTwice: true,
            pointerStillFor: .milliseconds(10), pausedUntil: nil, lastLookedUp: nil,
            captureInFlight: false, now: .now)
        #expect(decision == .stayQuiet(.stillMoving))
    }
}

/// The detector itself: two presses of one key, close enough together, with nothing in between.
///
/// Times are the events' own, in seconds — `NSEvent.timestamp` — not a clock read when the
/// callback runs. Each press is bound before it is asserted on, because `#expect` captures its
/// operands immutably and a `mutating` call cannot go inside the macro.
struct TapCounterTests {
    @Test func twoPressesInsideTheWindowAreADoubleTap() {
        var counter = TapCounter()
        let first = counter.pressed(at: 100)
        let second = counter.pressed(at: 100.15)
        #expect(!first)
        #expect(second)
    }

    @Test func twoPressesTooFarApartAreTwoSinglePresses() {
        var counter = TapCounter()
        _ = counter.pressed(at: 100)
        let late = counter.pressed(at: 100 + TapCounter.window + 0.001)
        #expect(!late, "a press outside the window completed a double-tap")
    }

    /// **A third press is not a second double-tap.** Without resetting, a key held long enough to
    /// auto-repeat would fire a lookup on every press after the first.
    @Test func aThirdPressStartsOver() {
        var counter = TapCounter()
        let presses = [100.0, 100.1, 100.2, 100.3].map { counter.pressed(at: $0) }
        #expect(presses == [false, true, false, true], "presses read as \(presses)")
    }

    /// **The boundary is asserted on either side of itself, never on it.**
    ///
    /// `100 + 0.4 - 100` is not `0.4` in binary floating point, and `NSEvent.timestamp` is seconds
    /// since boot — six figures, where the error is larger still. A test sitting exactly on the
    /// edge decides on the last bit of a subtraction, which is the coin toss the window exists to
    /// avoid. What matters, and what is checked, is that a press comfortably inside counts and one
    /// comfortably outside does not; the reader cannot tell a millisecond either way.
    @Test func pressesEitherSideOfTheWindowAreDecidedTheObviousWay() {
        var inside = TapCounter()
        _ = inside.pressed(at: 12_345.0)
        let within = inside.pressed(at: 12_345.0 + TapCounter.window - 0.01)
        #expect(within, "a press inside the window did not complete the pair")

        var outside = TapCounter()
        _ = outside.pressed(at: 12_345.0)
        let beyond = outside.pressed(at: 12_345.0 + TapCounter.window + 0.01)
        #expect(!beyond, "a press outside the window completed the pair")
    }

    /// **The finding this gesture would otherwise have reproduced.** Watching modifier
    /// transitions alone, two ⌥-arrows inside the window are two presses of ⌥ — and the reader
    /// gets a dictionary lookup for moving the caret. So is ⌘C then ⌘V. Anything between the
    /// presses cancels the pair.
    @Test func aKeystrokeBetweenThePressesCancelsThePair() {
        var counter = TapCounter()
        _ = counter.pressed(at: 100)      // ⌥ down for ⌥←
        counter.invalidate()              // ← pressed
        let second = counter.pressed(at: 100.1)  // ⌥ down for the next ⌥←
        #expect(!second, "two ⌥-arrow shortcuts read as a double-tap")
    }

    /// And a cancelled pair is cancelled, not merely delayed: the next press starts a fresh one.
    @Test func afterCancellingTheNextPairStillWorks() {
        var counter = TapCounter()
        _ = counter.pressed(at: 100)
        counter.invalidate()
        let first = counter.pressed(at: 100.1)
        let second = counter.pressed(at: 100.2)
        #expect(!first)
        #expect(second, "a cancelled pair left the counter unable to recognise the next one")
    }

    /// An event delivered out of order must not complete a pair by arriving *before* the first.
    @Test func aPressEarlierThanTheFirstDoesNotComplete() {
        var counter = TapCounter()
        _ = counter.pressed(at: 100)
        let backwards = counter.pressed(at: 99.9)
        #expect(!backwards)
    }
}

/// **The gesture rule against event sequences**, which is what a grep of the watcher could not
/// check — and what let a chord between two presses complete a pair.
struct GestureRecogniserTests {
    private static func asked(_ inputs: [GestureRecogniser.Input], gesture: HoverGesture = .doubleTap)
        -> [Bool] {
        var recogniser = GestureRecogniser()
        return inputs.map { recogniser.saw($0, gesture: gesture, modifier: .option) }
    }

    private static func tap(_ at: TimeInterval) -> GestureRecogniser.Input { .modifiers([.option], at: at) }
    private static func release(_ at: TimeInterval) -> GestureRecogniser.Input { .modifiers([], at: at) }

    @Test func twoTapsAreTheGesture() {
        let asked = Self.asked([Self.tap(100), Self.release(100.05), Self.tap(100.1)])
        #expect(asked == [false, false, true], "read as \(asked)")
    }

    /// **The residual half of the shortcut finding.** Key and button events cancel a pair, but a
    /// *chord* arrives as a modifier change: ⌥ down, ⌘ down, both up, ⌥ down is two presses of ⌥
    /// inside the window with a ⌘V in the middle. Nothing about it is a request for a lookup.
    @Test func aChordBetweenTheTapsCancelsThePair() {
        let asked = Self.asked([
            Self.tap(100),                                   // ⌥ down
            .modifiers([.option, .command], at: 100.02),     // ⌘ joins — a shortcut, not a tap
            Self.release(100.06),
            Self.tap(100.1),                                 // ⌥ down again
        ])
        #expect(!asked.contains(true), "a chord between the presses completed the gesture: \(asked)")
    }

    /// A keystroke or a click between them cancels it too — the case already fixed, held here so
    /// the two halves of the rule are checked in one place.
    @Test func otherInputBetweenTheTapsCancelsThePair() {
        let asked = Self.asked([Self.tap(100), .otherInput, Self.tap(100.1)])
        #expect(!asked.contains(true), "read as \(asked)")
    }

    /// Under the hold gesture nothing is ever "asked" by a tap; holding is read elsewhere.
    @Test func theTapRuleIsSilentUnderTheHoldGesture() {
        let asked = Self.asked([Self.tap(100), Self.release(100.05), Self.tap(100.1)], gesture: .hold)
        #expect(!asked.contains(true))
    }

    /// **A press is a transition, not a state.** Repeated events reporting the key still down —
    /// which `flagsChanged` produces whenever any other modifier moves — are not presses.
    @Test func repeatedHeldReportsAreNotPresses() {
        let asked = Self.asked([Self.tap(100), Self.tap(100.05), Self.tap(100.1)])
        #expect(!asked.contains(true), "a held key read as repeated presses: \(asked)")
    }

    @Test func resetForgetsAHalfMadePair() {
        var recogniser = GestureRecogniser()
        _ = recogniser.saw(Self.tap(100), gesture: .doubleTap, modifier: .option)
        recogniser.reset()
        _ = recogniser.saw(Self.release(100.05), gesture: .doubleTap, modifier: .option)
        let after = recogniser.saw(Self.tap(100.1), gesture: .doubleTap, modifier: .option)
        #expect(!after, "a pair survived the watcher being stopped")
    }
}
