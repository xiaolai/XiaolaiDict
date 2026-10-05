import ReviewKit
import Testing
@testable import XiaolaiDictUI

/// **The reminder switch in Settings › General: what it shows, whether it can be clicked, and why
/// not** (review-module-plan §5.3).
///
/// A grouped `Form` cannot be rendered to pixels here (AGENTS.md), so the decision the section draws
/// from is a value, and this is where it is held. Two rules: a control that refuses a click is a
/// broken switch — disabled, with the reason legible before the click — and a switch is never on
/// over reminders that cannot be delivered.
struct ReminderSectionTests {
    private static let on = ReminderSettings(isEnabled: true)
    private static let off = ReminderSettings(isEnabled: false)

    @Test func adeclinedGrantDisablesTheSwitchAndSaysWhy() {
        for settings in [Self.on, Self.off] {
            let state = ReminderSwitch(settings: settings, access: .declined)
            #expect(!state.isOn, "a switch drawn on over notifications macOS will not deliver")
            #expect(state.isDisabled)
            #expect(state.reason == .declined)
        }
    }

    @Test func aGrantNobodyHasAnsweredLeavesTheSwitchToAsk() {
        let state = ReminderSwitch(settings: Self.off, access: .notAsked)
        #expect(!state.isOn && !state.isDisabled && state.reason == nil)
        // On in the settings with no grant behind it — written by another version, or by the
        // end-to-end stage — is drawn off: nothing will be delivered, and the click is what asks.
        #expect(!ReminderSwitch(settings: Self.on, access: .notAsked).isOn)
    }

    @Test func grantedTheSwitchIsTheReadersChoice() {
        #expect(ReminderSwitch(settings: Self.on, access: .granted)
                == ReminderSwitch(isOn: true, isDisabled: false, reason: nil))
        #expect(ReminderSwitch(settings: Self.off, access: .granted)
                == ReminderSwitch(isOn: false, isDisabled: false, reason: nil))
    }

    /// A probe that could not tell is not a refusal: the switch stays the reader's, with a caution.
    @Test func aProbeThatCouldNotTellIsSaidAndRefusesNothing() {
        let state = ReminderSwitch(settings: Self.on, access: .couldNotTell)
        #expect(state.isOn && !state.isDisabled && state.reason == .couldNotTell)
        // Not asked yet — the pane has only just appeared — draws the setting as it is.
        #expect(ReminderSwitch(settings: Self.on, access: nil).isOn)
    }

    /// The time and the count are only worth setting while reminders are on.
    @Test func theTimeAndTheCountFollowTheSwitch() {
        #expect(ReminderSwitch(settings: Self.on, access: .granted).detailsAreEnabled)
        #expect(!ReminderSwitch(settings: Self.off, access: .granted).detailsAreEnabled)
        #expect(!ReminderSwitch(settings: Self.on, access: .declined).detailsAreEnabled)
    }

    /// **The time, the count and how long Later waits say why they cannot be changed** — a disabled
    /// control with no reason is a broken switch (AGENTS.md). Off, the reason is that reminders are
    /// off; declined, it is the grant, which the section already says.
    @Test func theDetailsSayWhyTheyCannotBeChanged() {
        #expect(ReminderSwitch(settings: Self.off, access: .granted).detailsReason == .remindersOff)
        #expect(ReminderSwitch(settings: Self.off, access: nil).detailsReason == .remindersOff)
        #expect(ReminderSwitch(settings: Self.on, access: .notAsked).detailsReason == .remindersOff)
        #expect(ReminderSwitch(settings: Self.on, access: .declined).detailsReason == .declined)
        #expect(ReminderSwitch(settings: Self.on, access: .granted).detailsReason == nil)
        #expect(ReminderSwitch(settings: Self.on, access: .couldNotTell).detailsReason == nil)
        for settings in [Self.on, Self.off] {
            for access in [NotificationGrant.granted, .notAsked, .declined, .couldNotTell, nil] {
                let state = ReminderSwitch(settings: settings, access: access)
                #expect(state.detailsAreEnabled == (state.detailsReason == nil), "\(settings) \(String(describing: access))")
            }
        }
    }
}
