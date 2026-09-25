import ApplicationServices
import ScreenCaptureKit
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// What XiaolaiDict needs from the system, and whether it has it.
///
/// The probe exists because a missing permission is silent. Hover's OCR path failed for months
/// with "no word under the pointer" — a sentence about the window's contents — while the real
/// causes were elsewhere entirely. Nothing in XiaolaiDict reported which permissions it held, so there
/// was nowhere to look.
struct PermissionsTests {
    private func report(accessibility: Bool, screenRecording: Bool) -> PermissionsReport {
        PermissionsReport(states: [
            PermissionState(permission: .accessibility, isGranted: accessibility),
            PermissionState(permission: .screenRecording, isGranted: screenRecording),
        ])
    }

    @Test func everythingGrantedIsNothingToReport() {
        let granted = report(accessibility: true, screenRecording: true)
        #expect(granted.allGranted)
        #expect(granted.missing.isEmpty)
        #expect(granted.menuWarning == nil, "two green ticks are not news")
    }

    /// The menu says which one, not merely that something is wrong. "A permission is missing" sends
    /// the reader to a window to find out what a sentence could have told them.
    @Test func oneMissingPermissionIsNamedInTheMenu() {
        let warning = report(accessibility: true, screenRecording: false).menuWarning
        #expect(warning == "Screen Recording is off — hover cannot read the screen")
    }

    @Test func severalMissingAreCountedRatherThanListed() {
        let warning = report(accessibility: false, screenRecording: false).menuWarning
        #expect(warning == "2 permissions are off — selections and the screen cannot be read")
    }

    @Test func missingHoldsOnlyWhatIsActuallyMissing() {
        let partial = report(accessibility: false, screenRecording: true)
        #expect(!partial.allGranted)
        #expect(partial.missing.map(\.permission) == [.accessibility])
    }

    /// A permission request that does not say what it buys is one a reader refuses.
    @Test func eachPermissionSaysWhatStopsWorkingWithoutIt() {
        for permission in Permission.allCases {
            #expect(!permission.blocks.isEmpty, "\(permission) does not say what it blocks")
            #expect(!permission.name.isEmpty)
        }
        #expect(Permission.accessibility.blocks.contains("selection"))
        #expect(Permission.screenRecording.blocks.contains("hover"))
    }

    /// After a refusal macOS never prompts again, so every permission has to be able to send the
    /// reader to the exact list — under whatever name this macOS gives it.
    @Test func eachPermissionKnowsWhereItIsGranted() {
        #expect(Permission.accessibility.location(majorVersion: 27).contains("Device Control"))
        #expect(Permission.screenRecording.location(majorVersion: 27).contains("Screen & System Audio"))
        #expect(Permission.accessibility.location(majorVersion: 26).contains("Accessibility"))
        #expect(Permission.screenRecording.location(majorVersion: 26).contains("Screen Recording"))
    }

    @Test func eachPermissionOpensItsOwnPane() {
        let panes = Permission.allCases.map(\.settingsURL)
        #expect(Set(panes).count == panes.count, "two permissions must not open the same pane")
        for pane in panes { #expect(pane.scheme == "x-apple.systempreferences") }
    }

    /// The report is ordered so the window reads the same way twice.
    @Test func theReportIsInAStableOrder() async {
        let report = await PermissionsReport.probe { _ in .granted }
        #expect(report.states.map(\.permission) == Permission.allCases)
    }

    /// Probing asks about every permission, not only the ones that were missing last time.
    @Test func probingAsksAboutEachPermissionOnce() async {
        let asked = Asked()
        _ = await PermissionsReport.probe { permission in
            asked.note(permission)
            return permission == .accessibility ? .granted : .declined
        }
        #expect(asked.all == Permission.allCases)
    }

    final class Asked: @unchecked Sendable {
        private(set) var all: [Permission] = []
        func note(_ permission: Permission) { all.append(permission) }
    }

    @Test func probeReportsWhatItWasTold() async {
        let report = await PermissionsReport.probe { $0 == .accessibility ? .granted : .declined }
        #expect(report.missing.map(\.permission) == [.screenRecording])
    }
}

/// The constants a permission depends on.
struct PermissionConstantsTests {
    /// `SCStreamErrorUserDeclined` is read from the SDK rather than written as -3801, but the
    /// domain is matched as a string, so this pins the pair the probe decides on.
    @Test func theRefusalCodeIsTheOneScreenCaptureKitSends() {
        #expect(SCStreamError.Code.userDeclined.rawValue == -3801)
        #expect(SCStreamErrorDomain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain")
    }
}


/// The third state reaching the reader, which is what the change was for.
struct UnknownPermissionStateTests {
    /// **Unknown is not "Off".** It used to be: the probe's `couldNotTell` arrived at the Settings
    /// pane as `false`, which drew a warning triangle, the word "Off", and an *Ask macOS…* button
    /// for a permission that may already be granted.
    @Test func anUnknownGrantIsNotReportedAsRefused() async {
        let report = await PermissionsReport.probe { _ in .couldNotTell }
        for state in report.states {
            #expect(state.found == .couldNotTell)
            #expect(state.isGranted == false, "unknown must not be mistaken for granted either")
        }
    }

    /// And it still counts as missing, so the setup board keeps asking the reader to look —
    /// harmless there, unlike asserting "Off" in Settings.
    @Test func anUnknownGrantStillCountsAsMissing() async {
        let report = await PermissionsReport.probe { _ in .couldNotTell }
        #expect(report.missing.count == Permission.allCases.count)
    }
}
