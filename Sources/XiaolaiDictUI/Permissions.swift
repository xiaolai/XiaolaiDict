import Foundation
import MacCapture

/// What the reader is told about a permission, and where they are sent to grant it — **the view layer's half of
/// `Permission`**, whose cases and probes are `MacCapture`'s (2026-10-08, plan-macos-modularisation P5). The words are
/// macOS's own names and this app's sentences, so they are written here, where every sentence the reader sees is.
extension Permission {
    /// The name macOS gives it, and the name the reader is looking for in System Settings — so a
    /// translation has to be the running system's own word for the list, not a fresh rendering of
    /// the English. `SetupView` draws the same two names, and drew them translated while these
    /// stayed English, which is the whole reason they are keys rather than literals.
    public var name: String {
        switch self {
        case .accessibility:
            String(localized: "Accessibility",
                   comment: "The Accessibility permission, as macOS names it in System Settings")
        case .screenRecording:
            String(localized: "Screen Recording",
                   comment: "The Screen Recording permission, as macOS names it in System Settings")
        }
    }

    /// Why the app wants it, as a sentence for the state it is in.
    ///
    /// A request that does not say what it buys is one a reader is right to refuse, so the
    /// ungranted sentence says what the access is for and what does not work without it.
    ///
    /// **One sentence per state, because one sentence for both was wrong in one of them.** This
    /// was `blocks` — "what stops working" — a fragment written for the missing grant and drawn
    /// unchanged under a row that said Ready: "Reading the selection under your shortcut, and the
    /// fast hover path." A reader with the grant in place was shown a list of things that had
    /// stopped working, in the app's own vocabulary.
    ///
    /// These name the app, which reader-facing text otherwise does not: a permission is the one
    /// place the reader has to find it by that name, in a list in System Settings.
    public func explanation(isGranted: Bool) -> String {
        switch (self, isGranted) {
        case (.accessibility, true):
            String(localized: "XiaolaiDict can read the text you select and the word under the pointer.",
                   comment: "Setup row for the Accessibility permission, once it is granted")
        case (.accessibility, false):
            String(localized: "XiaolaiDict needs Accessibility to read the text you select and the word under the pointer. Without it, neither the lookup shortcut nor hover can read anything.",
                   comment: "Setup row for the Accessibility permission, while it is not granted")
        case (.screenRecording, true):
            String(localized: "XiaolaiDict can read the word under the pointer in apps that expose no text, such as a terminal, a canvas or an image.",
                   comment: "Setup row for the Screen Recording permission, once it is granted")
        case (.screenRecording, false):
            String(localized: "XiaolaiDict needs Screen Recording to read the word under the pointer in apps that expose no text, such as a terminal, a canvas or an image. Without it, hover finds nothing there.",
                   comment: "Setup row for the Screen Recording permission, while it is not granted")
        }
    }

    /// Where this is granted, under the name the running macOS gives the list.
    public var location: String { location(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    public func location(majorVersion: Int) -> String {
        switch self {
        case .accessibility: PrivacySettings.accessibilityLocation(majorVersion: majorVersion)
        case .screenRecording: PrivacySettings.screenRecordingLocation(majorVersion: majorVersion)
        }
    }

    /// The exact pane, so the reader is not asked to go and find it.
    public var settingsURL: URL {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

public struct PermissionState: Equatable, Sendable, Identifiable {
    public let permission: Permission
    /// **What the probe found, all three of it.** This used to be a `Bool`, and an audit was right
    /// about what that cost: `couldNotTell` arrived as `false`, so the Settings pane drew "Off" in
    /// warning orange and offered *Ask macOS…* for a permission that may well be granted. Telling
    /// a reader to grant something they already granted is worse than saying nothing, because they
    /// will go and look and find it already on.
    public let found: PermissionProbe

    /// For the surfaces that genuinely have two renderings — the setup board's tick, and `missing`.
    /// **Unknown counts as not-granted here on purpose**: the board asking the reader to look is
    /// harmless, where the Settings pane asserting "Off" is not.
    public var isGranted: Bool { found == .granted }

    public var id: String { permission.id }

    public init(permission: Permission, found: PermissionProbe) {
        self.permission = permission
        self.found = found
    }

    /// The two-valued form, for call sites that genuinely know — previews, and tests that are not
    /// about the third state.
    public init(permission: Permission, isGranted: Bool) {
        self.init(permission: permission, found: isGranted ? .granted : .declined)
    }
}

/// What XiaolaiDict has, and what it is missing.
public struct PermissionsReport: Equatable, Sendable {
    /// In `Permission.allCases` order, so the window reads the same way twice.
    public let states: [PermissionState]

    public init(states: [PermissionState]) {
        self.states = states
    }

    public var allGranted: Bool { states.allSatisfy(\.isGranted) }
    /// What the reader declined. **Not what could not be checked**: a probe that failed says nothing
    /// about consent, and counting it here told the menu a permission was off that may well be on.
    public var missing: [PermissionState] { states.filter { $0.found == .declined } }
    /// What could not be checked — said as that, never as "off".
    public var unchecked: [PermissionState] { states.filter { $0.found == .couldNotTell } }

    /// One line for the menu, or nil when there is nothing to say. Two green ticks are not news.
    ///
    /// Names the permission when one is missing rather than reporting that *something* is — sending
    /// the reader to a window to discover what a sentence could have told them is the failure this
    /// whole probe exists to avoid.
    public var menuWarning: String? {
        // Both kinds at once: a refusal and a failed check are said together, neither hidden.
        if !missing.isEmpty, !unchecked.isEmpty {
            return String(localized: "\(missing.count + unchecked.count) permissions are off or could not be checked — open Setup",
                          comment: "Menu warning when some permissions are off and others could not be checked")
        }
        return switch missing.count {
        case 0 where !unchecked.isEmpty:
            String(localized: "A permission could not be checked — open Setup to check again",
                   comment: "Menu warning when a permission probe failed, which is not a refusal")
        case 0: nil
        case 1:
            switch missing[0].permission {
            case .accessibility:
                String(localized: "Accessibility is off — your selection cannot be read",
                       comment: "Menu warning when only Accessibility is missing")
            case .screenRecording:
                String(localized: "Screen Recording is off — hover cannot read the screen",
                       comment: "Menu warning when only Screen Recording is missing")
            }
        default:
            String(localized: "\(missing.count) permissions are off — selections and the screen cannot be read",
                   comment: "Menu warning when more than one permission is missing")
        }
    }

    /// Asks about every permission, every time. Caching which were missing last time is how a probe
    /// comes to report a permission the reader has since granted.
    public static func probe(_ probe: (Permission) async -> PermissionProbe = { await $0.probe }) async -> PermissionsReport {
        var states: [PermissionState] = []
        for permission in Permission.allCases {
            states.append(PermissionState(permission: permission, found: await probe(permission)))
        }
        return PermissionsReport(states: states)
    }
}
