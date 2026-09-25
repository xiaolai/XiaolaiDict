import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What a permission probe found, three-valued because two values are what caused the defect.
///
/// `granted` and `declined` are claims about the reader's consent. `couldNotTell` is a claim about
/// the probe, and folding it into either neighbour is wrong in a way that shows: folded into
/// `declined` it raises a prompt that grants nothing, folded into `granted` it promises a capture
/// that then fails.
///
/// The same shape, and for the same reason, as `ModelServiceProcess.Presence` — a scan that
/// answered nothing is a failure carrying its own reason, never the other side's answer.
public enum PermissionProbe: Sendable, Equatable {
    case granted
    /// The reader said no. macOS prompts only once, so there is somewhere to send them instead.
    case declined
    /// The probe failed for a reason that is not a refusal — so it says nothing about consent.
    case couldNotTell
}

/// A permission XiaolaiDict needs from macOS.
///
/// Both are silent when missing, which is the whole reason this type exists. Accessibility was
/// granted on the E2E machine and Screen Recording was not; every Accessibility stage passed, and
/// the one path needing the other failed for months reporting "no word under the pointer". A
/// permission that fails by saying nothing needs somewhere it can be looked at.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case accessibility
    case screenRecording

    public var id: String { rawValue }

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

    /// What stops working without it. A request that does not say what it buys is one a reader is
    /// right to refuse, so this is stated in terms of what XiaolaiDict can no longer do —
    /// never "XiaolaiDict requires this permission".
    public var blocks: String {
        switch self {
        case .accessibility:
            String(localized: "Reading the selection under your shortcut, and the fast hover path.",
                   comment: "What stops working without the Accessibility permission")
        case .screenRecording:
            String(localized: "Reading words by hover from apps that expose no text — a terminal, a canvas, an image.",
                   comment: "What stops working without the Screen Recording permission")
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

    /// Whether macOS has granted it, asked **the way the feature asks**. Neither path prompts.
    ///
    /// Screen Recording is checked by calling `SCShareableContent` — the same API the recogniser
    /// uses — rather than `CGPreflightScreenCaptureAccess()`. Not because the two were seen to
    /// disagree: they were not, and an earlier version of this comment claimed so on a
    /// misdiagnosis. The reason is that a probe answering from a different API than the feature
    /// *can* diverge from it, and the whole value of this window is that its answer matches what
    /// the reader will actually experience. Asking the same question rules the divergence out
    /// rather than hoping.
    ///
    /// The cost is the recogniser's own: ~70 ms for on-screen windows only.
    public var isGranted: Bool {
        get async {
            let answer: PermissionProbe = await probe
            return answer == .granted
        }
    }

    /// The same question, three-valued — **and the third value is the point.**
    ///
    /// `isGranted` above collapses this, which is safe for a checklist (an unknown draws as *not
    /// ready*, and the reader is told where to look) and is **not** safe for deciding whether to
    /// prompt. `try?` used to do the collapsing here, so any failure of the probe — not just a
    /// refusal — reached `ScreenRecordingAccess.ensure()` as "no grant" and raised a system dialog.
    ///
    /// Measured 2026-09-25 on a Mac whose grant had stood since 2026-09-22: the first hover after a
    /// fresh launch raised the Screen Recording dialog, and **nothing in the system TCC database
    /// changed** — not `auth_value`, not `last_modified`, not `last_reminded`, not `reminder_count`.
    /// A dialog that grants nothing is a dialog that should never have been raised. The first
    /// `SCShareableContent` call in a cold process is where that non-refusal failure lives; this
    /// project already measured the capture subsystem at 14.8 s for a first read against ~0.5 s
    /// after.
    ///
    /// So a refusal is `SCStreamErrorUserDeclined` and nothing else. Anything else is
    /// `couldNotTell`, which is not an answer about the reader's consent and must not be reported
    /// as one.
    public var probe: PermissionProbe {
        get async {
            switch self {
            case .accessibility:
                // Genuinely two-valued: the API returns a Bool and cannot say why.
                return AXIsProcessTrusted() ? .granted : .declined
            case .screenRecording:
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    return .granted
                // The SDK's own symbol, never the number behind it: `SCStreamErrorUserDeclined`
                // is the one code in that domain that is a statement about the reader's consent —
                // every other code there is about the capture — and spelling it out keeps this
                // tied to the SDK rather than to a literal that has to be re-checked.
                } catch let error as NSError
                            where error.domain == SCStreamErrorDomain
                            && error.code == SCStreamError.Code.userDeclined.rawValue {
                    return .declined
                } catch {
                    return .couldNotTell
                }
            }
        }
    }

    /// Asks macOS to prompt. It does so **only once per permission, ever** — after a refusal there
    /// is no second prompt and the reader has to use Settings, which is why every refusal here
    /// carries a location.
    @discardableResult
    public func request() -> Bool {
        switch self {
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        }
    }
}

public struct PermissionState: Equatable, Sendable, Identifiable {
    public let permission: Permission
    public let isGranted: Bool

    public var id: String { permission.id }

    public init(permission: Permission, isGranted: Bool) {
        self.permission = permission
        self.isGranted = isGranted
    }
}

/// What XiaolaiDict has, and what it is missing.
public struct PermissionsReport: Equatable, Sendable {
    /// In `Permission.allCases` order, so the window reads the same way twice.
    public let states: [PermissionState]

    public init(states: [PermissionState]) {
        self.states = states
    }

    public var allGranted: Bool { missing.isEmpty }
    public var missing: [PermissionState] { states.filter { !$0.isGranted } }

    /// One line for the menu, or nil when there is nothing to say. Two green ticks are not news.
    ///
    /// Names the permission when one is missing rather than reporting that *something* is — sending
    /// the reader to a window to discover what a sentence could have told them is the failure this
    /// whole probe exists to avoid.
    public var menuWarning: String? {
        switch missing.count {
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
    public static func probe(_ isGranted: (Permission) async -> Bool = { await $0.isGranted }) async -> PermissionsReport {
        var states: [PermissionState] = []
        for permission in Permission.allCases {
            states.append(PermissionState(permission: permission, isGranted: await isGranted(permission)))
        }
        return PermissionsReport(states: states)
    }
}
