import Foundation

/// The modifier the reader must hold before the pointer does anything at all.
///
/// Hover is **opt-in per lookup, not per session** (`feature-ledger-ux.md` A4): without this, the
/// pointer resting anywhere is a lookup, and the reader cannot read a page without being helped.
/// There is no "none" case on purpose — a hover with no modifier is the design this exists to
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

    /// The written name, for a picker where a lone symbol is a guessing game.
    public var name: String {
        switch self {
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        case .shift: "Shift"
        }
    }
}

/// Why a hover did not fire. Every refusal is nameable, because "the popup did not appear" with no
/// reason is indistinguishable from a bug.
public enum HoverRefusal: String, Sendable, Equatable, CaseIterable {
    /// The modifier is not held. The ordinary case, and not a problem.
    case modifierNotHeld
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

    public var reason: String {
        switch self {
        case .modifierNotHeld: "Hold the hover modifier to look up the word under the pointer."
        case .excludedApp: "Words are not looked up in this app."
        case .excludedSite: "Words are not looked up on this site."
        case .paused: "Lookups are paused."
        case .stillMoving: "The pointer is still moving."
        case .samePlace: "This word was just looked up."
        case .captureInFlight: "A capture is already running."
        }
    }
}

public enum HoverDecision: Sendable, Equatable {
    case look
    case stayQuiet(HoverRefusal)

    public var willLook: Bool { self == .look }
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
    /// How long the pointer must be still. Debouncing is non-negotiable.
    public var settleMilliseconds: Int

    /// The rests the reader can choose between, named.
    ///
    /// A named list rather than a free slider, for the reason the text-size picker is one: every
    /// value here is a rest the hover path has been used at, and a free number lets a reader set
    /// 20 ms and conclude XiaolaiDict is broken when it fires at every word they pass over.
    public struct Settle: Sendable, Equatable, Identifiable, Codable {
        public let milliseconds: Int
        public let name: String
        public var id: Int { milliseconds }

        public init(milliseconds: Int, name: String) {
            self.milliseconds = milliseconds
            self.name = name
        }
    }

    public static let settleChoices: [Settle] = [
        Settle(milliseconds: 120, name: "Quick"),
        Settle(milliseconds: 180, name: "Standard"),
        Settle(milliseconds: 300, name: "Relaxed"),
        Settle(milliseconds: 500, name: "Patient"),
    ]

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
    /// enumerating six bundle identifiers.
    public static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    public static let shipped = HoverPolicy(
        modifier: .option, excludedApps: defaultExcludedApps, excludedHosts: [], settleMilliseconds: 180)

    public init(
        modifier: HoverModifier, excludedApps: Set<String>, excludedHosts: Set<String>,
        settleMilliseconds: Int
    ) {
        self.modifier = modifier
        self.excludedApps = excludedApps
        self.excludedHosts = excludedHosts
        self.settleMilliseconds = settleMilliseconds
    }

    /// The order is deliberate: the cheapest and commonest refusal first, so the ordinary case —
    /// the reader is just reading — costs one comparison and never touches Accessibility.
    public func decide(
        at site: HoverSite, modifiersHeld: Set<HoverModifier>, pointerStillFor: Duration,
        pausedUntil: Date?, lastLookedUp: String?, captureInFlight: Bool, now: Date
    ) -> HoverDecision {
        guard modifiersHeld.contains(modifier) else { return .stayQuiet(.modifierNotHeld) }
        if let pausedUntil, now < pausedUntil { return .stayQuiet(.paused) }
        if let bundleID = site.bundleID, excludedApps.contains(bundleID) { return .stayQuiet(.excludedApp) }
        if let host = site.host, Self.isExcluded(host, by: excludedHosts) { return .stayQuiet(.excludedSite) }
        if captureInFlight { return .stayQuiet(.captureInFlight) }
        guard pointerStillFor >= .milliseconds(settleMilliseconds) else { return .stayQuiet(.stillMoving) }
        if let wordKey = site.wordKey, wordKey == lastLookedUp { return .stayQuiet(.samePlace) }
        return .look
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

    public mutating func pause(for duration: Duration, from now: Date) {
        until = now.addingTimeInterval(TimeInterval(duration.components.seconds))
    }

    public mutating func resume() {
        until = nil
    }

    /// What the menu says, so a paused XiaolaiDict is never silently paused.
    public func label(at now: Date) -> String {
        guard let until, now < until else { return "Pause Hover…" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Paused — resumes \(formatter.localizedString(for: until, relativeTo: now))"
    }
}
