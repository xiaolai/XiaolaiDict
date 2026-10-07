import Foundation
import Observation
import ReviewKit
import StudyPresentation
import XiaolaiDictBase
import os

/// **R1b's switch: choosing a meaning for a word saved without one replaces the word-only card.**
///
/// Off unless the reader turns it on in Settings › General › Study. **The one spelling of its key, and
/// what `LookupRecorder` reads** at each Choose a Meaning write, so the switch and the write cannot
/// disagree. What it does is `Ledger.replaceWordCards`, in the keep's own transaction.
struct WordCardReplacementSetting {
    /// **A persistent contract**: renaming it turns the option off for every reader who chose it.
    static let key = "studyReplacesWordCards"

    let defaults: UserDefaults

    /// Absent, or anything but true, is off — and off is today's Choose a Meaning, byte for byte.
    var isOn: Bool { defaults.bool(forKey: Self.key) }

    func save(_ isOn: Bool) { defaults.set(isOn, forKey: Self.key) }
}

/// **The study options Settings draws, kept in the suite the app was given** (R1b, R1c; 2026-10-05).
///
/// A collaborator of its own, so `XiaolaiDictApp` composes it and holds none of its state (ADR-0011).
/// It owns no key: each option is written through the setting struct its reader uses —
/// `WordCardReplacementSetting` (the recorder), `ConfirmationCooldownSetting` (the Library's Confirm) —
/// and this keeps an observed copy for the window, updated on every write and read back from the
/// suite, so what Settings shows is what was stored.
@MainActor
@Observable
final class StudyOptions {
    private(set) var replacesWordCards: Bool
    private(set) var waitsAfterConfirming: Bool
    private(set) var minimumWait: TimeInterval

    @ObservationIgnored private let replacement: WordCardReplacementSetting
    @ObservationIgnored private let cooldown: ConfirmationCooldownSetting
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "settings")

    /// `defaults` is the suite the app was given — never `.standard` reached for here.
    init(defaults: UserDefaults) {
        replacement = WordCardReplacementSetting(defaults: defaults)
        cooldown = ConfirmationCooldownSetting(defaults: defaults)
        replacesWordCards = replacement.isOn
        waitsAfterConfirming = cooldown.isOn
        minimumWait = cooldown.minimumDelay
    }

    func setReplacesWordCards(_ isOn: Bool) {
        replacement.save(isOn)
        replacesWordCards = replacement.isOn
    }

    func setWaitsAfterConfirming(_ isOn: Bool) {
        cooldown.save(isOn: isOn)
        waitsAfterConfirming = cooldown.isOn
    }

    /// A minimum the picker offers. **Anything else is refused and logged**, never fatal: it is our own
    /// caller's mistake, and the reader's choice stays as it was.
    func setMinimumWait(_ wait: TimeInterval) {
        if !cooldown.save(minimumDelay: wait) {
            log.error("settings: a minimum wait of \(wait, privacy: .public) s is not one Settings offers; kept \(self.minimumWait, privacy: .public) s")
        }
        minimumWait = cooldown.minimumDelay
    }

    /// What Settings › General draws.
    var choice: StudyChoice {
        StudyChoice(
            replacesWordCards: replacesWordCards, waitsAfterConfirming: waitsAfterConfirming,
            minimumWait: minimumWait, minimumWaitChoices: ConfirmationCooldown.minimumDelayChoices,
            setReplacesWordCards: { [weak self] in self?.setReplacesWordCards($0) },
            setWaitsAfterConfirming: { [weak self] in self?.setWaitsAfterConfirming($0) },
            setMinimumWait: { [weak self] in self?.setMinimumWait($0) })
    }
}
