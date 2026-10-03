import AppKit
import XiaolaiDictCore
import Observation
import SwiftUI

@Observable
@MainActor
public final class SettingsModel {
    /// Which pane is showing. **Held here rather than in the view** so the app can reach it:
    /// `--settings-report` selects each pane in turn and measures what the window does, and a
    /// selection buried in `@State` would leave the window's own resizing unmeasurable.
    ///
    /// **It starts where `SettingsPaneStore` says**: on Setup while something there is still
    /// needed, otherwise on the pane the reader last chose. It was Setup at every launch, with a
    /// comment saying there was no other deliberate route to the board; Setup has been the first
    /// tab since 2026-10-01, so the route exists and the reason does not.
    ///
    /// Setting this moves the window and **stores nothing** — that is `choose(_:)`, which the
    /// tabs call. An instrument walking the panes, or the lookup window's link to the Dictionary
    /// pane, must not become the reader's preference.
    public var pane: SettingsPane {
        didSet { if pane != .lookup { shortcutCapture.end() } }
    }

    /// The reader picked a tab: show it, and open there next time.
    public func choose(_ pane: SettingsPane) {
        self.pane = pane
        paneStore?.save(pane)
    }

    /// What the setup pane found, once it can say. Stored so the *next* launch knows whether to
    /// open on it — the board itself cannot be asked before the window exists, because its
    /// permission probe runs only while it is on screen.
    func note(setupUnfinished: Bool) {
        paneStore?.save(setupUnfinished: setupUnfinished)
    }

    /// Whether the menu bar icon is shown. Observable, so the status item can follow it, and
    /// written through to `MenuBarIconSetting.key` in the app's own suite.
    public var showsMenuBarIcon: Bool {
        didSet { if showsMenuBarIcon != oldValue { menuBarIcon?.save(showsMenuBarIcon) } }
    }

    /// Opening at login, where the app supplied a way to register for it.
    @ObservationIgnored public let loginItem: LoginItemChoice?

    @ObservationIgnored private let paneStore: SettingsPaneStore?
    @ObservationIgnored private let menuBarIcon: MenuBarIconSetting?

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

    /// Which fit is the latest. **Only the latest applies**: a fit queued before a newer one ran would
    /// read the same viewport and move the window by the same delta twice. Dropping the newer fit
    /// instead lost a pane change's resize — an audit's regression finding, 2026-10-03.
    @ObservationIgnored var fitGeneration = 0

    /// Whether the showing pane's scroll view currently has any height. Observed, unlike `given`,
    /// because it is what lets a fit happen: a pane measures itself before its window has a size,
    /// and a fit taken then is a fit against zero. **Tracked both ways**: it only ever went from
    /// false to true, so a pane that reported zero after the first — and then its real height —
    /// had its fit skipped and never retried, since nothing the fit watches had changed.
    public internal(set) var isLaidOut = false

    /// `defaults` is the suite the app was given, never `.standard` reached for here. Nil — a
    /// preview, a test that is not about persistence — keeps everything in memory and opens on
    /// Setup with the icon shown.
    ///
    /// **No permission state lives here any more.** This held a `PermissionsReport` and polled
    /// for it once a second; the Permissions pane that read it was absorbed into Setup on
    /// 2026-10-01 and nothing has read it since — a `SCShareableContent` round trip a second, about
    /// 70 ms each, feeding a property with no reader, beside `SetupModel`'s identical poll.
    public init(defaults: UserDefaults? = nil, loginItem: LoginItemChoice? = nil) {
        let paneStore = defaults.map(SettingsPaneStore.init(defaults:))
        let menuBarIcon = defaults.map(MenuBarIconSetting.init(defaults:))
        self.paneStore = paneStore
        self.menuBarIcon = menuBarIcon
        self.loginItem = loginItem
        pane = paneStore?.openingPane() ?? .setup
        showsMenuBarIcon = menuBarIcon?.load() ?? true
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
    @State private var model: SettingsModel
    /// Optional so a preview can show the window without one. A preview of the permission rows
    /// should not have to build an `Appearance`.
    private var keepPolicy: Binding<LookupKeepPolicy>?
    private var appearance: Appearance?
    private var hover: Binding<HoverPolicy>?
    private var hoverEnabled: Binding<Bool>?
    /// Reading the screen has stopped answering. See `LookupPane.captureStuck`.
    private var captureStuck: Bool
    private var dictionary: DictionaryChoice?
    private var shortcut: ShortcutChoice?
    /// The local model's licence, downloaded with its weights — nil until there is a model.
    private var modelLicence: URL?
    /// The erase command's state and its action. Optional together: a preview shows the pane
    /// without one rather than being given a half-wired destructive control.
    private var erase: ErasePresentation?
    private var eraseAction: (@MainActor (EraseAction) -> Void)?

    /// Stands in for the app's policy in a preview, so the hover pane is live rather than inert
    /// wherever it is looked at. In the app the binding is passed in and this is never read.
    @State private var unattached = HoverPolicy.shipped

    /// The window this view is in, which `SettingsWindowFit` resizes. Nil in a preview, where
    /// there is no window to fit and the view simply lays out.
    @State private var window: NSWindow?

    /// What the setup pane needs and the rest of the window does not. Nil where Settings is drawn
    /// without the app behind it — a preview, an instrument — and the pane says so rather than
    /// drawing rows that report nothing.
    private let setup: SetupModel?
    private let shortcutIsRegistered: Bool
    private let localModel: LocalModelChoice?
    private let refreshDictionaries: (() async -> Void)?

    public init(
        model: SettingsModel = SettingsModel(), appearance: Appearance? = nil,
        keepPolicy: Binding<LookupKeepPolicy>? = nil,
        hover: Binding<HoverPolicy>? = nil, hoverEnabled: Binding<Bool>? = nil,
        captureStuck: Bool = false,
        dictionary: DictionaryChoice? = nil,
        shortcut: ShortcutChoice? = nil, modelLicence: URL? = nil,
        erase: ErasePresentation? = nil,
        eraseAction: (@MainActor (EraseAction) -> Void)? = nil,
        setup: SetupModel? = nil, shortcutIsRegistered: Bool = false,
        localModel: LocalModelChoice? = nil,
        refreshDictionaries: (() async -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.keepPolicy = keepPolicy
        self.appearance = appearance
        self.hover = hover
        self.hoverEnabled = hoverEnabled
        self.captureStuck = captureStuck
        self.dictionary = dictionary
        self.shortcut = shortcut
        self.modelLicence = modelLicence
        self.erase = erase
        self.eraseAction = eraseAction
        self.setup = setup
        self.shortcutIsRegistered = shortcutIsRegistered
        self.localModel = localModel
        self.refreshDictionaries = refreshDictionaries
    }

    public var body: some View {
        // **Through `choose`, so a tab the reader clicked is remembered** and a pane something
        // else selected is not.
        TabView(selection: Binding(get: { model.pane }, set: { model.choose($0) })) {
            ForEach(SettingsPane.allCases) { pane in
                Tab(pane.title, systemImage: pane.symbol, value: pane) {
                    content(of: pane)
                        .onScrollGeometryChange(for: ContentFit.self) { ContentFit(of: $0) }
                        action: { _, geometry in
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
            // **A new window, or none, invalidates every queued fit at once** — not when SwiftUI next
            // runs `onChange`, by which time a fit queued for the old window may already have moved
            // it, or moved the new one by the old one's arithmetic.
            if found !== window { model.fitGeneration += 1 }
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
            // **Every change moves the generation**, a fit that cannot apply too: a fit queued for
            // the window that has since gone must not apply to it after.
            model.fitGeneration += 1
            let generation = model.fitGeneration
            guard fit.height != nil, fit.laidOut, let fitWindow = window else { return }
            // The first fit is not animated: that is where the window opens, not a movement the
            // reader asked for.
            let animated = fitWindow.isVisible
            // **Outside the layout pass.** This runs during one, and resizing a window from inside
            // layout re-enters it — measured to abort the process once it had re-entered more
            // times than the window has views. What the pane was given is read there too, after
            // layout, rather than here in the middle of it.
            DispatchQueue.main.async {
                // A newer fit has been seen since this one: it applies, against the newer window too.
                guard generation == model.fitGeneration, window === fitWindow else { return }
                // **Read now, not when the change was seen**: the height the pane wants and the
                // viewport it was given are both the latest, so a fit that waited behind layout
                // does not apply a height the pane has since moved past.
                // The pane this fit was worked out for is still the pane showing: `given` is the
                // viewport of whichever pane is on screen now, and pairing one pane's wanted height
                // with another's viewport would move the window by the difference between panes.
                guard model.pane == fit.pane, let height = Self.fitted(model.heights[fit.pane]) else { return }
                guard let delta = SettingsWindowFit.shortfall(wanted: height, given: model.given) else { return }
                SettingsWindowFit.move(
                    fitWindow, by: delta, width: Token.Panel.settingsWidth,
                    lowestBottom: fitWindow.screen?.visibleFrame.minY, animated: animated)
            }
        }
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
    private var target: CGFloat? { Self.fitted(model.heights[model.pane]) }

    /// A pane's wanted height, floored and capped — one spelling for the fit seen and the fit applied.
    private static func fitted(_ wanted: CGFloat?) -> CGFloat? {
        wanted.map { min(max($0, Token.Panel.settingsMinHeight), Token.Panel.settingsMaxHeight) }
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
        // **The board, in a pane rather than a window of its own.** Each row's action selects the
        // pane it is about, which is now a sibling tab rather than another window.
        case .setup:
            if let setup {
                SetupView(
                    model: setup, dictionary: dictionary, shortcut: shortcut,
                    shortcutIsRegistered: shortcutIsRegistered, localModel: localModel,
                    // Not `choose`: the board sent the reader there, they did not pick the tab.
                    openSettings: { model.pane = $0 },
                    refreshDictionaries: refreshDictionaries,
                    onOutstandingChange: { model.note(setupUnfinished: $0) })
            } else {
                Form { Unavailable() }.formStyle(.grouped)
            }
        case .general:
            GeneralPane(model: model, keepPolicy: keepPolicy, erase: erase, eraseAction: eraseAction)
        case .reading: ReadingPane(appearance: appearance)
        case .lookup:
            LookupPane(policy: hover ?? $unattached, hoverEnabled: hoverEnabled,
                       captureStuck: captureStuck, shortcut: shortcut, capture: model.shortcutCapture)
        case .dictionary: DictionaryPane(choice: dictionary)
        // `Bundle.main` is the app when XiaolaiDict is running and the test runner when it is not, which
        // is why `AppRelease` is nil-able rather than invented: a pane that printed a version it
        // could not read would be worse than one that prints none.
        case .about:
            AboutPane(release: AppRelease(Bundle.main), modelLicence: modelLicence,
                      notices: Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        }
    }
}

/// What a pane says where it was drawn without the app behind it — a preview, an instrument.
///
/// One sentence in one place. It was four, each naming what "this pane is not connected to",
/// which is the app's wiring described to a reader who has no way to connect anything.
struct Unavailable: View {
    var body: some View {
        Text("These settings are not available right now.").foregroundStyle(.secondary)
    }
}

/// The settings window's panes, as data.
///
/// Named in one place because two things have to agree about them: the window that draws the tabs,
/// and `--settings-report`, which selects each one inside the running bundle and measures what the
/// window does. A report naming its own panes could drift from the window's and still pass.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    /// **First, because it is what a fresh install needs and the only pane that answers across the
    /// others**: is any of this working. It absorbed the Permissions pane on 2026-10-01 — that pane
    /// listed the same two grants this one already has rows for, with fewer affordances: it named
    /// no list to find them in and offered no way to ask macOS. It was a window of its own until 2026-10-01 — a second
    /// surface over the same facts, and the only place the reader could choose which model answers,
    /// which is a standing preference rather than something a fresh install lacks.
    case setup
    /// The app itself: when it starts, where it shows, what it saves and deletes. `GeneralPane`
    /// records why it is a pane of its own.
    case general
    case reading
    case lookup
    case dictionary
    case about

    public var id: String { rawValue }

    /// What `--settings-report` prints, so a stage failure names the pane the reader would have
    /// clicked. **Not the tab's label** and deliberately never localized: the harness matches on
    /// it, and a name that changed with the reader's language would name nothing on a translated
    /// Mac. `title` is the label.
    public var name: String {
        switch self {
        case .setup: "Setup"
        case .general: "General"
        case .reading: "Reading"
        case .lookup: "Lookup"
        case .dictionary: "Dictionary"
        case .about: "About"
        }
    }

    /// The tab's label. Written out per case rather than built from `name`, because a
    /// `LocalizedStringKey` assembled at run time is a key the compiler never saw and so a key no
    /// translator is ever given — the four that are not also written somewhere else were missing
    /// from the catalog for exactly that reason.
    var title: LocalizedStringKey {
        switch self {
        case .setup: "Setup"
        case .general: "General"
        case .reading: "Reading"
        case .lookup: "Lookup"
        case .dictionary: "Dictionary"
        case .about: "About"
        }
    }

    /// A tab's symbol, which is a place and not an action — so it is written here and not in
    /// `ActionSymbol`. **Lookup is `text.magnifyingglass`, not `magnifyingglass`**: the plain
    /// glass is the system's Search symbol, and the Library's search field already draws it for
    /// exactly that; a tab wearing it promised a search of the settings.
    var symbol: String {
        switch self {
        case .setup: "checklist"
        case .general: "gearshape"
        case .reading: "textformat.size"
        case .lookup: "text.magnifyingglass"
        case .dictionary: "character.book.closed"
        case .about: "info.circle"
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor private func setupModel(_ states: [PermissionState]) -> SetupModel {
    let model = SetupModel()
    model.show(PermissionsReport(states: states))
    return model
}

/// The state worth designing against: something is off, so the row carries why it is needed,
/// where to grant it, and the two buttons. The happy state is the one that needs no thought.
#Preview("A permission is off") {
    SettingsView(setup: setupModel([
        PermissionState(permission: .accessibility, isGranted: true),
        PermissionState(permission: .screenRecording, isGranted: false),
    ]))
}

#Preview("Both off") {
    SettingsView(setup: setupModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: false)
    }))
}

#Preview("Everything granted") {
    SettingsView(setup: setupModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: true)
    }))
}

/// The dictionary pane with the dictionaries still being read, which is a state a reader can
/// open the pane in.
#Preview("Dictionary, still asking") {
    // On the Dictionary pane: the default model opens on Setup, which this preview is not about.
    let model = SettingsModel()
    model.pane = .dictionary
    return SettingsView(model: model, dictionary: DictionaryChoice(available: nil, chosen: nil, choose: { _ in }))
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
