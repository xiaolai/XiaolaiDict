import Foundation
import ReviewKit

/// **The cooldown experiment's switch and minimum — off unless the reader turns it on.**
///
/// `ConfirmationCooldown` (review-module-plan §8.3c) is an experiment, and since 2026-10-05 the
/// reader's option (R1c): a switch and a minimum in Settings › General › Review, written through
/// `StudyOptions`. **This is the one spelling of both keys, and what the confirmation reads**, so the
/// switch and the hook cannot disagree. A switch set by hand before the option existed —
///
///     defaults write com.xiaolaidict reviewConfirmationCooldown -bool true
///
/// — is the same key, and Settings shows it on. Absent, or anything but true, is off — and off is
/// byte-for-byte what a confirmation did before the experiment existed. Read at each confirmation
/// rather than once, so switching it needs no relaunch.
struct ConfirmationCooldownSetting {
    /// **A persistent contract**: renaming it switches off every reader who switched it on, silently.
    /// `FunnelWiringTests` and `StudyOptionsWiringTests` spell it out for that reason.
    static let key = "reviewConfirmationCooldown"
    /// The minimum, in seconds — one of `ConfirmationCooldown.minimumDelayChoices`. **A persistent
    /// contract** too. Anything else reads as the placeholder (`ConfirmationCooldown.minimumDelay(stored:)`).
    static let minimumDelayKey = "reviewConfirmationCooldownMinimumDelay"

    let defaults: UserDefaults

    var isOn: Bool { defaults.bool(forKey: Self.key) }

    /// What the minimum is, as both the picker and the confirmation read it.
    var minimumDelay: TimeInterval {
        ConfirmationCooldown.minimumDelay(stored: defaults.object(forKey: Self.minimumDelayKey) as? TimeInterval)
    }

    /// The rule to apply, or nil while the experiment is off.
    var cooldown: ConfirmationCooldown? {
        isOn ? ConfirmationCooldown(studyDay: .standard, minimumDelay: minimumDelay) : nil
    }

    func save(isOn: Bool) { defaults.set(isOn, forKey: Self.key) }

    /// Keeps a minimum the picker offers; anything else is a caller's mistake and changes nothing —
    /// a stored value off the menu would read as the placeholder, not as what was asked for.
    @discardableResult
    func save(minimumDelay: TimeInterval) -> Bool {
        guard ConfirmationCooldown.minimumDelayChoices.contains(minimumDelay) else { return false }
        defaults.set(minimumDelay, forKey: Self.minimumDelayKey)
        return true
    }
}
