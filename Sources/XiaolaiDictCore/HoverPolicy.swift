import DictionaryModel
import Foundation

/// **How the reader asks** — the gesture, which is a separate question from which key it uses.
///
/// Holding is a weak statement of intent, because every modifier already means something: ⌥ is
/// Meta in a terminal, types special characters, and modifies clicks and drags. A reader holding
/// it for any of those, with the pointer at rest over text, gets a lookup they did not ask for.
///
/// **Tap-once is deliberately not offered.** A bare modifier is abandoned constantly — pressed,
/// then thought better of, then released — and that cannot be told from a deliberate tap without
/// waiting to see whether a chord follows. It would fire more often than holding does, which is
/// the opposite of why the gesture exists.
public enum HoverGesture: String, Codable, Sendable, CaseIterable {
    /// Hold the key while the pointer rests. The shipped default.
    case hold
    /// Tap the key twice, quickly. The key is released by the time the lookup runs.
    case doubleTap

    /// What the reader does, shown with the key they chose: `⌥` against `⌥⌥`.
    public func label(_ modifier: HoverModifier) -> String {
        switch self {
        case .hold: modifier.symbol
        case .doubleTap: modifier.symbol + modifier.symbol
        }
    }
}

/// Two presses of one key, close enough together, **with nothing in between**.
///
/// A value rather than a timer: it is handed each event and answers whether that press completed
/// a double-tap, which makes the whole rule testable without a clock or a keyboard.
public struct TapCounter: Sendable {
    /// **How long the second press has to arrive.** Long enough not to demand dexterity, short
    /// enough that two unrelated presses of a key as busy as ⌥ rarely fall inside it.
    public static let window: TimeInterval = 0.4

    private var first: TimeInterval?

    public init() {}

    /// Whether this press completed a double-tap.
    ///
    /// **Times come from the events themselves**, not from a clock read when the callback runs.
    /// Global event monitors are delivered asynchronously, so `NSEvent.modifierFlags` and "now"
    /// describe when this process got around to looking rather than when the reader pressed the
    /// key — which mistimes the window under load, exactly when callbacks are late.
    ///
    /// **A completed tap resets the count**, so a third press begins a new pair rather than
    /// completing a second. Without that, a key held down long enough to auto-repeat — or a
    /// reader tapping three times — would fire a lookup on every press after the first.
    public mutating func pressed(at instant: TimeInterval) -> Bool {
        if let first, instant - first <= Self.window, instant >= first {
            self.first = nil
            return true
        }
        first = instant
        return false
    }

    /// **Anything else the reader did cancels the pair**, and this is what makes the gesture mean
    /// something. Watching modifier transitions alone, `⌥←` twice in quick succession is two
    /// presses of ⌥ inside the window — so is `⌘C` then `⌘V` — and the reader gets a lookup for
    /// editing text. That is precisely the accidental firing the gesture exists to remove, so
    /// without this the feature argues against itself.
    public mutating func invalidate() { first = nil }
}

/// **The whole of the gesture rule, as a value.** Events in, "did the reader just ask" out.
///
/// It exists because the rule was spread across a watcher that reads AppKit and the clock
/// directly, so the only checks possible on it were greps of the source — which cannot see event
/// ordering, and did not see that a chord between two presses still completed a pair.
public struct GestureRecogniser: Sendable {
    /// What the recogniser is told. Everything that is not a modifier change is `otherInput`:
    /// which key or button it was does not matter, only that the reader did something else.
    public enum Input: Sendable, Equatable {
        /// The modifiers now held, and when the event says so.
        case modifiers(Set<HoverModifier>, at: TimeInterval)
        case otherInput
    }

    private var taps = TapCounter()
    private var wasHeld = false

    public init() {}

    /// Whether this input completed the reader's gesture.
    ///
    /// **A chord is not a tap.** Holding ⌥ and pressing ⌘ leaves ⌥ down, so no press is seen —
    /// but releasing both and pressing ⌥ again would otherwise complete a pair made of two
    /// *shortcut* presses. Any other modifier joining the set cancels, which is the same rule
    /// `otherInput` applies to keys and buttons, extended to the only input that arrives as a
    /// modifier change.
    public mutating func saw(
        _ input: Input, gesture: HoverGesture, modifier: HoverModifier
    ) -> Bool {
        switch input {
        case .otherInput:
            taps.invalidate()
            return false
        case .modifiers(let held, let instant):
            let isHeld = held.contains(modifier)
            defer { wasHeld = isHeld }
            if held.subtracting([modifier]).isEmpty == false { taps.invalidate(); return false }
            guard gesture == .doubleTap, isHeld, !wasHeld else { return false }
            return taps.pressed(at: instant)
        }
    }

    /// **State does not outlive the watching.** Left set, a modifier released while stopped makes
    /// the first press after a restart invisible, and a half-finished pair from minutes ago can
    /// complete against an unrelated press.
    public mutating func reset() {
        taps = TapCounter()
        wasHeld = false
    }
}

/// The key the reader uses to ask, whether they hold it or tap it — see `HoverGesture`, which is
/// the other half of the question.
///
/// Hover is **opt-in per lookup, not per session** (`feature-ledger-ux.md` A4): without this, the
/// pointer resting anywhere is a lookup, and the reader cannot read a page without being helped.
///
/// There is no "none" case on purpose — a hover with no key is the design this exists to
/// prevent, and making it unrepresentable is cheaper than remembering not to configure it.
public enum HoverModifier: String, Codable, Sendable, CaseIterable {
    case option
    case control
    case command
    case shift

    /// The key's own symbol, for a label that sits beside a shortcut. `XiaolaiDictMenu` carried "⌥" as a
    /// literal, which was right only while the modifier could not be changed — a label that names
    /// the wrong key is worse than no label, because the reader holds it and nothing happens.
    ///
    /// A `switch` rather than a dictionary: a case added later fails to compile here instead of
    /// silently returning an empty string into the menu.
    public var symbol: String {
        switch self {
        case .option: "\u{2325}"
        case .control: "\u{2303}"
        case .command: "\u{2318}"
        case .shift: "\u{21E7}"
        }
    }

}

/// Why a hover did not fire. Every refusal is nameable, because "the popup did not appear" with no
/// reason is indistinguishable from a bug.
public enum HoverRefusal: String, Sendable, Equatable, CaseIterable {
    /// The modifier is not held. The ordinary case, and not a problem.
    case modifierNotHeld
    /// The reader asked for the double-tap gesture and has not tapped.
    case notTapped
    /// This app is excluded — a password manager, a terminal (A3).
    case excludedApp
    /// This site is excluded (A3).
    case excludedSite
    /// The reader asked XiaolaiDict to stop for a while (A5).
    case paused
    /// The pointer has not settled yet. Debouncing is non-negotiable (design note §8).
    case stillMoving
    /// The pointer has not left the word XiaolaiDict last looked up, so there is nothing new to say.
    case samePlace
    /// A capture is already running. Two simultaneous `SCScreenshotManager` captures deadlock —
    /// measured 6 times out of 6 — so a second one is refused rather than started.
    case captureInFlight
    /// The word is not written in a script the reader studies. Unlike every other refusal here,
    /// this one is a setting the reader chose and can change, so its text has to say so.
    case scriptNotStudied
    /// The reader moved on while the capture was running. The capture itself cannot be stopped —
    /// it is a detached task and a `SCScreenshotManager` call that does not honour cancellation —
    /// so what is refused is *accepting its answer*, which is the part that would otherwise deliver
    /// a panel and remember a word for a hover nobody was waiting for.
    case cancelled

    public var reason: String {
        switch self {
        case .modifierNotHeld: "Hold the hover modifier to look up the word under the pointer."
        case .notTapped: "Tap the hover modifier twice to look up the word under the pointer."
        case .excludedApp: "Words are not looked up in this app."
        case .excludedSite: "Words are not looked up on this site."
        case .paused: "Lookups are paused."
        case .stillMoving: "The pointer is still moving."
        case .samePlace: "This word was just looked up."
        case .captureInFlight: "A capture is already running."
        case .scriptNotStudied: "This word is not in a script you study. Change that under Hover in Settings."
        case .cancelled: "The pointer moved on before the word could be read."
        }
    }
}

public enum HoverDecision: Sendable, Equatable {
    case look
    case stayQuiet(HoverRefusal)
}

/// Where the pointer is, in terms a decision can be made about.
public struct HoverSite: Sendable, Equatable {
    public let bundleID: String?
    /// The page's host, when the app is a browser and could say.
    public let host: String?
    /// Which word the pointer is over, if the capture already knows — used only to tell "the same
    /// word again" from "a new word".
    public let wordKey: String?

    public init(bundleID: String?, host: String? = nil, wordKey: String? = nil) {
        self.bundleID = bundleID
        self.host = host
        self.wordKey = wordKey
    }
}

/// Whether a hover may fire. All three gates are P0 in the feature ledger, and all three have to
/// exist **before** any capture does: the first hover that fires in a password field is already
/// the problem they prevent.
public struct HoverPolicy: Sendable, Equatable, Codable {
    /// Held before the pointer does anything (A4).
    public var modifier: HoverModifier
    /// Apps XiaolaiDict never looks things up in (A3). Ships non-empty, and for the same reason the place
    /// exclusions do: a popup in a password field or a terminal is worse than no popup.
    public var excludedApps: Set<String>
    /// Sites XiaolaiDict never looks things up on (A3), by host.
    public var excludedHosts: Set<String>
    /// How the reader asks for a lookup. `.hold` is what shipped and stays the default.
    public var gesture: HoverGesture
    /// How long the pointer must be still. Debouncing is non-negotiable.
    public var settleMilliseconds: Int
    /// The scripts the reader studies. A word in any other is read and then dropped.
    ///
    /// **Scripts and not languages, because only one of the two is decidable here.** A single word
    /// carries far too little for `NLLanguageRecognizer` to separate English from German, and the
    /// hover path often has no sentence to give it — so a setting called "English only" would
    /// refuse *Schadenfreude* and the reader would have no way to find out why. The script a word
    /// is written in is a property of its characters, and `ProbeScript.dominant` reads it exactly.
    ///
    /// Latin alone by default: the reader this app is for studies English, and a popup over every
    /// Chinese word they pass is the noise the switch exists to remove. A reader whose study
    /// dictionary is 譯典通 adds `han` and is served by the same setting.
    public var scripts: Set<ProbeScript>

    /// The rests the reader can choose between, named.
    ///
    /// A named list rather than a free slider, for the reason the text-size picker is one: every
    /// value here is a rest the hover path has been used at, and a free number lets a reader set
    /// 20 ms and conclude XiaolaiDict is broken when it fires at every word they pass over.
    ///
    /// **A case per rest, and no name here.** Each carried an English `name` — "Quick",
    /// "Standard" — which the settings picker drew verbatim, so four labels were in no catalog and
    /// no translator ever saw them. This module has no view layer and may hold no display text;
    /// `HoverLabels` in the UI module names them, and switches over these cases so a rest added
    /// here cannot go unnamed there.
    public enum Settle: Int, Sendable, Equatable, Identifiable, CaseIterable {
        case quick = 120
        case standard = 180
        case relaxed = 300
        case patient = 500

        public var milliseconds: Int { rawValue }
        public var id: Int { rawValue }
    }

    public static let settleChoices: [Settle] = Settle.allCases

    /// **Safety, not taste.** The ledger stores the sentence a word was read in, so a lookup in a
    /// password manager writes a secret to disk. There the whole surface is secrets, which is what
    /// makes this a rule and not a preference — and why it is the only thing shipped excluded.
    public static let defaultExcludedApps: Set<String> = PlacePolicy.passwordManagers

    /// Terminals — a named set, and **not excluded by default**.
    ///
    /// They shipped excluded on the reasoning that a popup over a half-typed command is worse than
    /// useless and that terminal content is often not prose. Both are weaker than they look. The
    /// screen-word spike measured hover working in Ghostty (finding 12: "a terminal exposes no text
    /// through Accessibility — OCR is the only path there"), so the exclusion removed something
    /// demonstrated to work; and `HoverModifier` has no "none" case, so hover only fires when the
    /// reader deliberately holds the modifier and rests. It cannot land on a half-typed command by
    /// accident. Whether the content is prose is the reader's business, not the policy's — people
    /// read prose in terminals.
    ///
    /// Kept as a set so a reader who wants the old behaviour can have it in one line rather than by
    /// enumerating six bundle identifiers. **That one line is the whole reason it is `public` and
    /// the whole reason nothing calls it** — being unreferenced is the state it is meant to be in,
    /// and `terminalsRemainANamedSetAReaderCanExclude` is what proves the line still works.
    public static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    /// The scripts a reader studies unless they say otherwise.
    public static let defaultScripts: Set<ProbeScript> = [.latin]

    public static let shipped = HoverPolicy(
        modifier: .option, excludedApps: defaultExcludedApps, excludedHosts: [],
        settleMilliseconds: 180)

    public init(
        modifier: HoverModifier, excludedApps: Set<String>, excludedHosts: Set<String>,
        settleMilliseconds: Int, scripts: Set<ProbeScript> = HoverPolicy.defaultScripts,
        gesture: HoverGesture = .hold
    ) {
        self.modifier = modifier
        self.excludedApps = excludedApps
        self.excludedHosts = excludedHosts
        self.settleMilliseconds = settleMilliseconds
        self.scripts = scripts
        self.gesture = gesture
    }

    /// **Decoded with a default, because the policy is stored as one blob.** A value written
    /// before `scripts` existed carries no such key, and a synthesised decoder would throw on it —
    /// which `HoverPolicyStore.load` turns into `.shipped`, silently discarding every app and site
    /// the reader had excluded. That would read as the exclusions resetting themselves one launch
    /// after an update, with nothing said. Every field a later version adds needs this treatment.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifier = try values.decode(HoverModifier.self, forKey: .modifier)
        excludedApps = try values.decode(Set<String>.self, forKey: .excludedApps)
        excludedHosts = try values.decode(Set<String>.self, forKey: .excludedHosts)
        settleMilliseconds = try values.decode(Int.self, forKey: .settleMilliseconds)
        scripts = try values.decodeIfPresent(Set<ProbeScript>.self, forKey: .scripts)
            ?? HoverPolicy.defaultScripts
        // Added after readers already had a stored policy. The synthesised decoder throws on a
        // blob written before a field existed, and `HoverPolicyStore.load` turns a throw into
        // `.shipped` — silently discarding every exclusion the reader had set.
        gesture = try values.decodeIfPresent(HoverGesture.self, forKey: .gesture) ?? .hold
    }

    /// The order is deliberate: the cheapest and commonest refusal first, so the ordinary case —
    /// the reader is just reading — costs one comparison and never touches Accessibility.
    /// `tappedTwice` says a double-tap of the hover modifier just completed. **It has no default**
    /// — a caller that forgets it would silently make the double-tap gesture unreachable, and a
    /// parameter nobody supplies is invisible to every unit test that exercises the value directly.
    public func decide(
        at site: HoverSite, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool,
        pointerStillFor: Duration, pausedUntil: Date?, lastLookedUp: String?,
        captureInFlight: Bool, now: Date
    ) -> HoverDecision {
        // **The gesture decides whether the reader asked; everything below decides whether the
        // answer may be given.** A tap does not require the key to still be down — requiring it
        // would make the gesture a hold with extra steps.
        switch gesture {
        case .hold:
            guard modifiersHeld.contains(modifier) else { return .stayQuiet(.modifierNotHeld) }
        case .doubleTap:
            guard tappedTwice else { return .stayQuiet(.notTapped) }
        }
        if let pausedUntil, now < pausedUntil { return .stayQuiet(.paused) }
        if let bundleID = site.bundleID, excludedApps.contains(bundleID) { return .stayQuiet(.excludedApp) }
        if let host = site.host, Self.isExcluded(host, by: excludedHosts) { return .stayQuiet(.excludedSite) }
        if captureInFlight { return .stayQuiet(.captureInFlight) }
        guard pointerStillFor >= .milliseconds(settleMilliseconds) else { return .stayQuiet(.stillMoving) }
        if let wordKey = site.wordKey, wordKey == lastLookedUp { return .stayQuiet(.samePlace) }
        return .look
    }

    /// Whether a word the reader rested on is written in a script they study.
    ///
    /// **Asked after the word has been read, never inside `decide`.** The gate runs before any
    /// text exists — that is what makes the ordinary refusal cost one set comparison — so the
    /// script cannot be one of its inputs. This is the second line, beside the repeat check, and
    /// what it saves is everything downstream: the XPC lookup and the sense ladder, which on a
    /// multi-sense entry is a prompt through the model on the GPU.
    ///
    /// **Text in no script at all is looked up.** A capture of `42`, of punctuation, or of a
    /// script this does not enumerate names nothing — and refusing there would make the filter
    /// quietly wider than the reader set it, in precisely the captures OCR is least sure of.
    public func studies(_ text: String) -> Bool {
        guard let script = ProbeScript.dominant(in: text) else { return true }
        return scripts.contains(script)
    }

    /// Host names are case-insensitive and may carry a trailing root dot, so `EXAMPLE.COM.` and
    /// `example.com` are the same site. Compared without normalising, an exclusion the reader set
    /// is bypassed by the capitalisation of a link they clicked — which is not an exclusion.
    public static func normalisedHost(_ host: String) -> String {
        var normalised = host.trimmingCharacters(in: .whitespaces).lowercased()
        while normalised.hasSuffix(".") { normalised.removeLast() }
        return normalised
    }

    /// Whether `host` is excluded by `excluded`, matching the name itself or any subdomain of it.
    /// Both sides are normalised, so it does not matter how either was typed.
    static func isExcluded(_ host: String, by excluded: Set<String>) -> Bool {
        let host = normalisedHost(host)
        guard !host.isEmpty else { return false }
        return excluded.contains { name in
            let name = normalisedHost(name)
            guard !name.isEmpty else { return false }
            return host == name || host.hasSuffix(".\(name)")
        }
    }
}

/// The pause switch: "stop looking things up for an hour", reachable in one click (A5). No surveyed
/// dictionary has one, and the reader sometimes wants to read without being helped.
public struct HoverPause: Sendable, Equatable {
    public static let durations: [Duration] = [.seconds(900), .seconds(3_600), .seconds(28_800)]

    /// How long a pause lasts, said in words. The menu offers three lengths and a row reading
    /// "900 seconds" is not an offer anyone can act on — `durations` shipped as a list with
    /// nothing to render it, which is part of why the switch it was written for never appeared.
    ///
    /// Localised, because it is read by the reader; the locale is a parameter so a test can pin
    /// one rather than assert this machine's.
    public static func name(of duration: Duration, in locale: Locale = .current) -> String {
        duration.formatted(
            .units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1,
                   zeroValueUnits: .hide)
            .locale(locale))
    }

    public var until: Date?

    public init(until: Date? = nil) {
        self.until = until
    }

    public func isPaused(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// **Both components, not just the seconds.** `Duration.components` splits into whole seconds
    /// and attoseconds, and taking the first alone silently truncated: 1.5 s became 1 s and
    /// anything under a second expired the moment it was set. Every duration the menu offers today
    /// is a whole number of seconds, which is what kept it invisible.
    public mutating func pause(for duration: Duration, from now: Date) {
        let parts = duration.components
        until = now.addingTimeInterval(
            TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
    }

    public mutating func resume() {
        until = nil
    }

    // **What the menu says about a pause is not here.** `label(at:)` returned the menu's words from
    // this module, which may hold no display text — they were in no string catalog. The app target's
    // `HoverPauseMenu` builds them from `until`, localised, since 2026-10-02.
}
