import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

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

    public var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// What stops working without it. A request that does not say what it buys is one a reader is
    /// right to refuse, so this is stated in terms of what XiaolaiDict can no longer do —
    /// never "XiaolaiDict requires this permission".
    public var blocks: String {
        switch self {
        case .accessibility:
            "Reading the selection under your shortcut, and the fast hover path."
        case .screenRecording:
            "Reading words by hover from apps that expose no text — a terminal, a canvas, an image."
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
            switch self {
            case .accessibility:
                AXIsProcessTrusted()
            case .screenRecording:
                await (try? SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
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
            case .accessibility: "Accessibility is off — XiaolaiDict cannot read your selection"
            case .screenRecording: "Screen Recording is off — hover cannot read the screen"
            }
        default: "\(missing.count) permissions are off — XiaolaiDict cannot read selections or the screen"
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
