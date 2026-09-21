import AppKit
import XiaolaiDictCore
import Observation
import SwiftUI

@Observable
@MainActor
public final class SettingsModel {
    /// Empty until the first probe answers. A window that said "everything is fine" before it had
    /// asked would be the same false green tick this whole probe exists to remove.
    var report = PermissionsReport(states: [])
    private(set) var hasAsked = false

    public init() {}

    public func refresh() async {
        show(await .probe())
    }

    /// Takes a report from wherever it came. Previews use it to show a state this machine is not
    /// in — a permission being *off* is what the window has to be designed around, and asking the
    /// system can only ever show how this Mac happens to be set up.
    public func show(_ report: PermissionsReport) {
        self.report = report
        hasAsked = true
    }
}

/// XiaolaiDict's settings window.
///
/// **Four panes, because there are four things to decide about and they were in three places.**
/// It was one flat scroll holding permissions and text size, while the hover modifier, the app and
/// site exclusions and the pointer rest were not settable at all, and the primary dictionary — the
/// most consequential choice in the app, since changing it starts study over — was a submenu. The
/// split was not by kind; it was by whatever happened to get built first.
///
/// `TabView` over `Form(.grouped)` rather than hand-laid rows: it is what a macOS settings window
/// is, and a single scroll stops working the moment there is more than one topic in it. The rows
/// also drop their own `glassEffect` — a grouped section *is* the raised surface, and glass inside
/// glass muddies both.
public struct SettingsView: View {
    @Environment(\.scale) private var scale
    @State private var model: SettingsModel
    /// Optional so a preview can show the window without one. A preview of the permission rows
    /// should not have to build an `Appearance`.
    private var appearance: Appearance?
    private var hover: Binding<HoverPolicy>?
    private var dictionary: DictionaryChoice?

    /// Stands in for the app's policy in a preview, so the hover pane is live rather than inert
    /// wherever it is looked at. In the app the binding is passed in and this is never read.
    @State private var unattached = HoverPolicy.shipped

    public init(
        model: SettingsModel = SettingsModel(), appearance: Appearance? = nil,
        hover: Binding<HoverPolicy>? = nil, dictionary: DictionaryChoice? = nil
    ) {
        _model = State(initialValue: model)
        self.appearance = appearance
        self.hover = hover
        self.dictionary = dictionary
    }

    public var body: some View {
        TabView {
            Tab("Reading", systemImage: "textformat.size") {
                ReadingPane(appearance: appearance)
            }
            Tab("Hover", systemImage: "hand.point.up.left") {
                HoverPane(policy: hover ?? $unattached)
            }
            Tab("Dictionary", systemImage: "character.book.closed") {
                DictionaryPane(choice: dictionary)
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsPane(model: model)
            }
            Tab("About", systemImage: "info.circle") {
                // `Bundle.main` is the app when XiaolaiDict is running and the test runner when it is
                // not, which is why `AppRelease` is nil-able rather than invented: a pane that
                // printed a version it could not read would be worse than one that prints none.
                AboutPane(release: AppRelease(Bundle.main))
            }
        }
        .frame(minWidth: Token.Panel.settingsMinWidth, minHeight: Token.Panel.settingsMinHeight)
        // macOS posts nothing when a permission changes, and the reader grants them in another app
        // and comes back. Polling is the only way to notice, and `.task` stops it when the window
        // goes away — which the hand-rolled controller had to remember to do itself.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: Token.Timing.permissionPoll)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor private func settingsModel(_ states: [PermissionState]) -> SettingsModel {
    let model = SettingsModel()
    model.show(PermissionsReport(states: states))
    return model
}

/// The state worth designing against: something is off, so the row carries what stops working,
/// where to grant it, and the two buttons. The happy state is the one that needs no thought.
#Preview("A permission is off") {
    SettingsView(model: settingsModel([
        PermissionState(permission: .accessibility, isGranted: true),
        PermissionState(permission: .screenRecording, isGranted: false),
    ]))
}

#Preview("Both off") {
    SettingsView(model: settingsModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: false)
    }))
}

#Preview("Everything granted") {
    SettingsView(model: settingsModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: true)
    }))
}

/// The dictionary pane with the service still answering, which is the state the warning has to
/// read well in — a reader who opens this pane before the service replies still needs to know that
/// switching costs them their study state.
#Preview("Dictionary, still asking") {
    SettingsView(dictionary: DictionaryChoice(available: nil, chosen: nil, choose: { _ in }))
}

/// About, with a release handed in rather than read: `Bundle.main` in a preview is Xcode's own
/// agent, so the canvas would otherwise show Xcode's version number.
#Preview("About") {
    AboutPane(release: AppRelease(version: "0.0.2", build: "2026.921.101500"))
}

/// And the same pane where the bundle declares nothing — the line is absent, not "unknown".
#Preview("About, no version") {
    AboutPane(release: nil)
}
#endif
