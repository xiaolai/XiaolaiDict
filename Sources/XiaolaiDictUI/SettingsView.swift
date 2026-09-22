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

    /// Which pane is showing. **Held here rather than in the view** so the app can reach it:
    /// `--settings-report` selects each pane in turn and measures what the window does, and a
    /// selection buried in `@State` would leave the window's own resizing unmeasurable.
    public var pane: SettingsPane = .reading {
        didSet { if pane != .lookup { shortcutCapture.end() } }
    }

    /// The shortcut field's recorder, **held here rather than in the field it is drawn in.**
    ///
    /// Leaving the Lookup pane has to end a recording — the monitor it installs listens to the
    /// whole app — and only this knows the reader left. Measured in the running app, twice: a
    /// hidden pane's views are kept alive and not re-evaluated, so neither the field's
    /// `onDisappear` nor a flag handed to it fired on a pane change, and a combination pressed on
    /// another pane became the reader's new shortcut.
    @ObservationIgnored public let shortcutCapture = ShortcutCapture()

    /// Each pane's height as it measured itself: the content of its form, not the box it was put in.
    ///
    /// **Measured from the form's own scroll geometry, because nothing else knows it.** A grouped
    /// `Form` scrolls, so it offers the window no content height at all — it fills whatever it is
    /// given. Removing the fixed frame was measured to change nothing: every pane still came out at
    /// 450 points, the window's default, with Lookup scrolling and About adrift in empty space.
    /// The scroll view's content size is the one number that is the pane's own, and it does not
    /// depend on the height the pane is given, so reading it cannot feed back into itself.
    public internal(set) var heights: [SettingsPane: CGFloat] = [:]

    /// The height the showing pane's scroll view has been given — the other half of every resize.
    /// Not observed: it changes on every frame of a resize, and nothing should redraw for that.
    @ObservationIgnored public internal(set) var given: CGFloat = 0

    /// Whether the showing pane's scroll view currently has any height. Observed, unlike `given`,
    /// because it is what lets a fit happen: a pane measures itself before its window has a size,
    /// and a fit taken then is a fit against zero. **Tracked both ways**: it only ever went from
    /// false to true, so a pane that reported zero after the first — and then its real height —
    /// had its fit skipped and never retried, since nothing the fit watches had changed.
    public internal(set) var isLaidOut = false

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
/// **A pane per thing there is to decide about**, where there was one flat scroll holding
/// permissions and text size — while the hover modifier, the app and site exclusions and the
/// pointer rest were not settable at all, the lookup shortcut was a window of its own, and the
/// primary dictionary, the most consequential choice in the app since changing it starts study
/// over, was a submenu. The split was not by kind; it was by whatever happened to get built first.
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
    private var shortcut: ShortcutChoice?
    /// Opens the setup board. The board is reachable from the menu too; this is the other way in,
    /// for a reader already in Settings wondering whether anything is missing.
    private var openSetup: (() -> Void)?
    /// The local model's licence, downloaded with its weights — nil until there is a model.
    private var modelLicence: URL?

    /// Stands in for the app's policy in a preview, so the hover pane is live rather than inert
    /// wherever it is looked at. In the app the binding is passed in and this is never read.
    @State private var unattached = HoverPolicy.shipped

    /// The window this view is in, which `SettingsWindowFit` resizes. Nil in a preview, where
    /// there is no window to fit and the view simply lays out.
    @State private var window: NSWindow?

    public init(
        model: SettingsModel = SettingsModel(), appearance: Appearance? = nil,
        hover: Binding<HoverPolicy>? = nil, dictionary: DictionaryChoice? = nil,
        shortcut: ShortcutChoice? = nil, openSetup: (() -> Void)? = nil, modelLicence: URL? = nil
    ) {
        _model = State(initialValue: model)
        self.appearance = appearance
        self.hover = hover
        self.dictionary = dictionary
        self.shortcut = shortcut
        self.openSetup = openSetup
        self.modelLicence = modelLicence
    }

    public var body: some View {
        TabView(selection: $model.pane) {
            ForEach(SettingsPane.allCases) { pane in
                Tab(pane.title, systemImage: pane.symbol, value: pane) {
                    content(of: pane)
                        .onScrollGeometryChange(for: PaneGeometry.self) { geometry in
                            // Insets included on both sides of the comparison: whatever sits over
                            // the content — the tab bar, under a toolbar — is in `wanted` and in
                            // `given` alike, and cancels.
                            PaneGeometry(
                                wanted: geometry.contentSize.height + geometry.contentInsets.top
                                    + geometry.contentInsets.bottom,
                                given: geometry.containerSize.height)
                        } action: { _, geometry in
                            // **Only the pane on screen.** Settings keeps a hidden pane's views
                            // alive, and one reporting a height of its own — or none — would set
                            // the readiness and the viewport the fit reads for the pane that *is*
                            // showing.
                            guard pane == model.pane else { return }
                            model.given = geometry.given
                            let laidOut = geometry.given > 0
                            if model.isLaidOut != laidOut { model.isLaidOut = laidOut }
                            model.heights[pane] = geometry.wanted
                        }
                }
            }
        }
        // **One width for every pane, and each pane's own height.** The window used to be pinned
        // at 420 × 320, narrower than any settings window on the system and the wrong height for
        // every pane but one: Dictionary and About were padded out with empty space while Lookup
        // scrolled inside a box too small for it. The width is fixed here; the height is not set
        // here at all — the content fills the window, and `SettingsWindowFit` moves the window.
        .frame(width: Token.Panel.settingsWidth)
        .frame(maxHeight: .infinity)
        .background(WindowReader { found in
            window = found
            // Sized by the pane, never by the reader's drag: a settings window whose edge could be
            // pulled would be a second, disagreeing answer to "how tall is this pane".
            found?.styleMask.remove(.resizable)
        })
        // Chosen pane, or the same pane measuring differently — an exclusion added, a permission
        // granted and its buttons gone — both move the window, and both the same way. A pane not
        // yet measured leaves the window where it is until it has: it is drawn once at the old
        // height, measures itself, and the window moves to fit. The window arriving counts too,
        // since a pane can measure itself before there is a window to fit.
        .onChange(
            of: Fit(pane: model.pane, height: target, window: window.map(ObjectIdentifier.init), laidOut: model.isLaidOut),
            initial: true
        ) { _, fit in
            guard let height = fit.height, fit.laidOut, let window else { return }
            // The first fit is not animated: that is where the window opens, not a movement the
            // reader asked for.
            let animated = window.isVisible
            // **Outside the layout pass.** This runs during one, and resizing a window from inside
            // layout re-enters it — measured to abort the process once it had re-entered more
            // times than the window has views. What the pane was given is read there too, after
            // layout, rather than here in the middle of it.
            DispatchQueue.main.async {
                // The pane this fit was worked out for is still the pane showing: `given` is the
                // viewport of whichever pane is on screen now, and pairing one pane's wanted height
                // with another's viewport would move the window by the difference between panes.
                guard model.pane == fit.pane else { return }
                guard let delta = SettingsWindowFit.shortfall(wanted: height, given: model.given) else { return }
                SettingsWindowFit.move(
                    window, by: delta, width: Token.Panel.settingsWidth,
                    lowestBottom: window.screen?.visibleFrame.minY, animated: animated)
            }
        }
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

    /// What one pane's scroll view reports: the height its content wants, and the height it has.
    private struct PaneGeometry: Equatable {
        let wanted: CGFloat
        let given: CGFloat
    }

    /// What a fit depends on. The window is part of it because a pane can measure itself before
    /// there is a window to resize, and that first height must not be lost.
    private struct Fit: Equatable {
        let pane: SettingsPane
        let height: CGFloat?
        let window: ObjectIdentifier?
        let laidOut: Bool
    }

    /// The height the selected pane wants, floored so a two-row pane is still a window and not a
    /// strip, and capped so a long one scrolls inside the window rather than taking the window off
    /// the bottom of the screen. Nil until that pane has measured itself.
    private var target: CGFloat? {
        model.heights[model.pane].map {
            min(max($0, Token.Panel.settingsMinHeight), Token.Panel.settingsMaxHeight)
        }
    }

    /// The panes' width and the tallest a pane is drawn, for `--settings-report` to hold the
    /// window against. Published rather than restated there: a report carrying its own copy of a
    /// design value checks the window against the copy.
    ///
    /// **`nonisolated` because `SettingsView` is a `View`** and so main-actor isolated, which its
    /// statics inherit — while `--settings-report` reads them from a plain value type off the main
    /// actor. They are pure reads of `Token`'s own `static let`s, so there is nothing to isolate;
    /// without this the report site warns rather than the declaration, which is where it is
    /// actually wrong.
    public nonisolated static var paneWidth: CGFloat { Token.Panel.settingsWidth }
    public nonisolated static var paneMaxHeight: CGFloat { Token.Panel.settingsMaxHeight }
    public nonisolated static var paneMinHeight: CGFloat { Token.Panel.settingsMinHeight }

    @ViewBuilder private func content(of pane: SettingsPane) -> some View {
        switch pane {
        case .reading: ReadingPane(appearance: appearance)
        case .lookup: LookupPane(policy: hover ?? $unattached, shortcut: shortcut, capture: model.shortcutCapture)
        case .dictionary: DictionaryPane(choice: dictionary)
        case .permissions: PermissionsPane(model: model, openSetup: openSetup)
        // `Bundle.main` is the app when XiaolaiDict is running and the test runner when it is not, which
        // is why `AppRelease` is nil-able rather than invented: a pane that printed a version it
        // could not read would be worse than one that prints none.
        case .about: AboutPane(release: AppRelease(Bundle.main), modelLicence: modelLicence)
        }
    }
}

/// The settings window's panes, as data.
///
/// Named in one place because two things have to agree about them: the window that draws the tabs,
/// and `--settings-report`, which selects each one inside the running bundle and measures what the
/// window does. A report naming its own panes could drift from the window's and still pass.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case reading
    case lookup
    case dictionary
    case permissions
    case about

    public var id: String { rawValue }

    /// The tab's label. Also what the report prints, so a stage failure names the pane the reader
    /// would have clicked.
    public var name: String {
        switch self {
        case .reading: "Reading"
        case .lookup: "Lookup"
        case .dictionary: "Dictionary"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var title: LocalizedStringKey { LocalizedStringKey(name) }

    var symbol: String {
        switch self {
        case .reading: "textformat.size"
        case .lookup: "magnifyingglass"
        case .dictionary: "character.book.closed"
        case .permissions: "lock.shield"
        case .about: "info.circle"
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
