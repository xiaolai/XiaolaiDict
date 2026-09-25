import ApplicationServices
import OSLog
import XiaolaiDictBase
import XiaolaiDictCore
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


    /// The option key that makes `AXIsProcessTrustedWithOptions` show its prompt. Spelled out
    /// because the SDK's constant is a global `var` Swift 6 will not let this read; a test holds
    /// the two equal.
    static let promptKey = "AXTrustedCheckOptionPrompt" 

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

    /// Whether macOS has granted it, asked **the way the feature asks**.
    ///
    /// **It does not prompt once the question has been answered, which is not the same as never
    /// prompting.** `SCShareableContent` is what the recogniser captures through, and on a Mac
    /// where the reader has never been asked, macOS may put its consent dialog up for it. That is
    /// correct behaviour for a capture and wrong for a status check that runs on a menu refresh —
    /// recorded here rather than claimed away, because the previous wording said "Neither path
    /// prompts" and an audit was right to call it.
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
                    // **Bounded.** This is a call into another process, and it has no timeout of its
                    // own. `PermissionsReport.probe` is awaited by the menu's refresh, by the setup
                    // board's polling, and by `askForDictionaries()` before dictionary discovery —
                    // so a capture service that stops answering used to stall all three with no
                    // way out. A probe that does not return in time has not said anything about
                    // consent, which is exactly `couldNotTell`.
                    try await withDeadline(Token.Timing.permissionProbe) {
                        // Answers `Void`, not the content: `SCShareableContent` is not `Sendable`,
                        // and nothing here wants it — only that the call was allowed to return.
                        _ = try await SCShareableContent.excludingDesktopWindows(
                            false, onScreenWindowsOnly: true)
                    }
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
                    // **Kept, not swallowed.** `couldNotTell` preserves that something went wrong
                    // and loses what — which is the one thing worth knowing when this fires. The
                    // domain and code are the diagnosis; the message may carry a path, so it is
                    // not logged.
                    let failure = error as NSError
                    Logger(subsystem: XiaolaiDictIdentity.app, category: "permissions").error(
                        "screen-recording probe failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
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
            // The literal, and **not** because nobody thought of the constant. An audit asked for
            // `kAXTrustedCheckOptionPrompt`; it cannot be used. The SDK declares it as a global
            // `var`, so Swift 6 refuses to read it from this module at all — "not concurrency-safe
            // because it involves shared mutable state" — and that refusal extends to a
            // `nonisolated(unsafe)` binding in a test, which was tried. So there is no compile-time
            // check of this string and no test that can make one.
            //
            // **The gap is real and is left visible rather than papered over.** A mistyped key is
            // not an error: `AXIsProcessTrustedWithOptions` simply never prompts, and the reader is
            // left on a permission screen that does nothing. If this ever needs proving, the route
            // is `dlsym` against the framework at runtime — deliberately not taken for one string.
            AXIsProcessTrustedWithOptions([Self.promptKey: true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
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
    public static func probe(_ probe: (Permission) async -> PermissionProbe = { await $0.probe }) async -> PermissionsReport {
        var states: [PermissionState] = []
        for permission in Permission.allCases {
            states.append(PermissionState(permission: permission, found: await probe(permission)))
        }
        return PermissionsReport(states: states)
    }
}
