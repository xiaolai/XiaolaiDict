import AppKit
import ReviewKit
import SwiftUI

/// **What macOS says about this app's notifications** — four answers, and no `Bool` beside them
/// (ADR-0017's shape, for the third permission).
///
/// `notAsked` is the only state in which asking can do anything: macOS shows its prompt once, so a
/// request over `declined` is a click that does nothing. `couldNotTell` is a statement about the
/// probe, never about the reader — a provisional authorization, which this app never requests, lands
/// here too, because it is not an answer the reader gave.
public enum NotificationGrant: Sendable, Equatable {
    case granted
    case notAsked
    case declined
    case couldNotTell
}

/// **Every word a review reminder carries** (review-module-plan §5.3). A title, and a sentence that
/// counts — never a word, a sentence the reader met, or a meaning: `ReminderContent` has no `String`
/// payload, so there is nothing else here to say.
///
/// In the view layer because it is reader-facing text, which `XiaolaiDictCore` and `ReviewKit` may not
/// hold; the delivery in the app builds the banner from these.
public enum ReminderWords {
    /// The banner's title: the place it leads to, under the name the Library's sidebar gives it.
    public static var title: String { String(localized: ActionSymbol.reviewPane.title) }

    public static func body(_ content: ReminderContent) -> String {
        switch content {
        case .sittingReady(let count?):
            String(localized: "A sitting of \(count) is ready",
                   comment: "A review reminder's banner; the number is how many meanings the sitting would ask")
        case .sittingReady(nil):
            hiddenBody
        }
    }

    /// The same sentence without its count — what a reader who chose not to see N is told, and what a
    /// hidden preview shows on a locked or shared screen.
    public static var hiddenBody: String {
        String(localized: "A sitting is ready",
               comment: "A review reminder's banner without a count, and its hidden preview")
    }
}

/// **What the reminder switch shows, whether it can be clicked, and why not.**
///
/// A value, because a grouped `Form` cannot be checked by rendering it. Two rules decide it: a switch
/// is never drawn on over reminders macOS will not deliver, and a control that would refuse a click
/// is disabled with its reason legible before the click.
public struct ReminderSwitch: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The reader said no, and macOS will not ask again: System Settings is the way back.
        case declined
        /// The probe failed; the reader's choice stands, with a caution.
        case couldNotTell
    }

    public let isOn: Bool
    public let isDisabled: Bool
    public let reason: Reason?

    public init(isOn: Bool, isDisabled: Bool, reason: Reason?) {
        self.isOn = isOn
        self.isDisabled = isDisabled
        self.reason = reason
    }

    /// `access` is nil until the pane has asked, which it does as it appears.
    public init(settings: ReminderSettings, access: NotificationGrant?) {
        switch access {
        case .declined?:
            self.init(isOn: false, isDisabled: true, reason: .declined)
        case .notAsked?:
            // On in the settings with no grant behind it delivers nothing, so it is drawn off; the
            // click is what asks.
            self.init(isOn: false, isDisabled: false, reason: nil)
        case .couldNotTell?:
            self.init(isOn: settings.isEnabled, isDisabled: false, reason: .couldNotTell)
        case .granted?, nil:
            self.init(isOn: settings.isEnabled, isDisabled: false, reason: nil)
        }
    }

    /// The time, the count and how long Later waits are worth setting only while reminders are on.
    public var detailsAreEnabled: Bool { isOn }

    /// **Why the details cannot be changed** — nil while they can. A disabled control says why before
    /// the click (AGENTS.md); declined, the section's own caution already says it, so the details name
    /// the same reason rather than a second sentence.
    public enum DetailsReason: Equatable, Sendable {
        case remindersOff
        case declined
    }

    public var detailsReason: DetailsReason? {
        guard !isOn else { return nil }
        return reason == .declined ? .declined : .remindersOff
    }
}

/// **The reminder settings, and what changes them**, handed in by the app like the shortcut and the
/// login item: the notification center and the plan are the app's, and this layer reaches neither.
public struct ReminderChoice {
    public var settings: ReminderSettings
    /// The last answer about the grant; nil until asked.
    public var access: NotificationGrant?
    /// **The only thing in the app that asks for the permission**, and only when turning on.
    public var setEnabled: @MainActor (Bool) async -> Void
    public var setTime: @MainActor (_ hour: Int, _ minute: Int) -> Void
    public var setShowsCount: @MainActor (Bool) -> Void
    /// How long Later waits — one of `settings.offeredLaterDelays`.
    public var setLaterDelay: @MainActor (TimeInterval) -> Void
    /// Asks the grant again, never prompting: the reader may have been to System Settings and back.
    public var refresh: @MainActor () async -> Void
    public var openNotificationSettings: @MainActor () -> Void

    public init(settings: ReminderSettings, access: NotificationGrant?,
                setEnabled: @escaping @MainActor (Bool) async -> Void,
                setTime: @escaping @MainActor (_ hour: Int, _ minute: Int) -> Void,
                setShowsCount: @escaping @MainActor (Bool) -> Void,
                setLaterDelay: @escaping @MainActor (TimeInterval) -> Void,
                refresh: @escaping @MainActor () async -> Void,
                openNotificationSettings: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.access = access
        self.setEnabled = setEnabled
        self.setTime = setTime
        self.setShowsCount = setShowsCount
        self.setLaterDelay = setLaterDelay
        self.refresh = refresh
        self.openNotificationSettings = openNotificationSettings
    }
}

/// **Settings › General › Review Reminder.** In General because that pane is the app's behaviour —
/// when it starts, where it shows, what it saves for study — and a reminder is the app speaking up
/// unasked. The Study section beside it decides what reaches Review; this decides whether Review may
/// say it is waiting.
struct ReminderSection: View {
    let choice: ReminderChoice
    /// The value the reader just asked for, held while the answer — perhaps the system prompt — is
    /// pending, so the switch neither snaps back nor takes a second click meanwhile.
    @State private var asking: Bool?

    var body: some View {
        let state = ReminderSwitch(settings: choice.settings, access: choice.access)
        Section {
            Toggle("Remind me when a sitting is ready", isOn: Binding(
                get: { asking ?? state.isOn },
                set: { wanted in
                    asking = wanted
                    Task {
                        await choice.setEnabled(wanted)
                        asking = nil
                    }
                }))
                .disabled(state.isDisabled || asking != nil)
            switch state.reason {
            case .declined?:
                StatusLabel(
                    .caution, "Notifications from XiaolaiDict are turned off in System Settings.",
                    size: Token.Text.form)
                Button("Open Notification Settings…") { choice.openNotificationSettings() }
            case .couldNotTell?:
                StatusLabel(.caution, "Whether notifications are allowed could not be checked.",
                            size: Token.Text.form)
            case nil:
                EmptyView()
            }
            // **Why the rows below cannot be changed**, before anyone clicks one. Declined says so above.
            if state.detailsReason == .remindersOff {
                Text("Turn on the reminder to change the settings below.")
                    .foregroundStyle(.secondary)
            }
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .disabled(!state.detailsAreEnabled)
            Toggle("Show how many are ready", isOn: Binding(
                get: { choice.settings.showsPredictedCount }, set: { choice.setShowsCount($0) }))
                .disabled(!state.detailsAreEnabled)
            // The banner's own button is "Later"; this is how long it waits.
            Picker("Later reminds again in", selection: Binding(
                get: { choice.settings.laterDelay }, set: { choice.setLaterDelay($0) })) {
                ForEach(choice.settings.offeredLaterDelays, id: \.self) { delay in
                    // A duration, which Foundation words in the reader's language — not prose.
                    Text(Duration.seconds(delay), format: .units(allowed: [.hours, .minutes], width: .wide))
                        .tag(delay)
                }
            }
            .disabled(!state.detailsAreEnabled)
        } header: {
            Text("Review Reminder")
        } footer: {
            Text("""
                 At most one reminder a study day, at the time you choose, and only when a sitting has \
                 something in it. A reminder never shows a word or its meaning.
                 """)
        }
        .task { await choice.refresh() }
        // The reader may have changed it in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await choice.refresh() }
        }
    }

    /// The reminder's time as a date today, for the picker; only its hour and minute are kept.
    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: choice.settings.hour, minute: choice.settings.minute,
                                      second: 0, of: .now) ?? .now
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                choice.setTime(parts.hour ?? choice.settings.hour, parts.minute ?? choice.settings.minute)
            })
    }
}
