import AppKit
import XiaolaiDictCore
import SwiftUI

/// Which dictionary the reader studies from, as the settings window needs it.
///
/// Passed in rather than read: the list comes from the XPC dictionary service, which lives in the
/// app target, and `XiaolaiDictUI` carries no private API and no XPC by design. `available` is optional
/// because "still asking" is a real state the reader can arrive in — an empty list and an
/// unanswered one must not look the same.
public struct DictionaryChoice {
    public var available: [DictionaryCapability]?
    public var chosen: String?
    public var choose: (String?) -> Void
    /// Whether the service has been asked and has finished answering.
    ///
    /// `available` is nil both before the question is asked and after one that failed, and those
    /// are different sentences: "asking…" is a state that resolves, and a service that answered
    /// nothing is a state that does not. Without this the setup board said "asking" for the life
    /// of the window.
    public var hasAsked: Bool

    public init(
        available: [DictionaryCapability]?, chosen: String?, hasAsked: Bool = false,
        choose: @escaping (String?) -> Void
    ) {
        self.available = available
        self.chosen = chosen
        self.hasAsked = hasAsked
        self.choose = choose
    }
}

// MARK: - Reading

struct ReadingPane: View {
    @Environment(\.scale) private var scale
    var appearance: Appearance?

    var body: some View {
        Form {
            if let appearance {
                Bound(appearance: appearance)
            } else {
                Section {
                    Text("This pane is not connected to the reader's settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Split out because `@Bindable` needs a non-optional, and unwrapping inside a `body` with a
    /// `$` binding is not something an `if let` can produce.
    private struct Bound: View {
        @Environment(\.scale) private var scale
        @Bindable var appearance: Appearance

        var body: some View {
            // A segmented picker rather than a slider: every step is a size the surfaces have been
            // looked at, and a free number would let the reader build a layout nobody designed.
            Section {
                Picker("Size", selection: $appearance.textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Mark the word", selection: $appearance.emphasis) {
                    ForEach(WordEmphasis.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text")
            } footer: {
                // Set in the chosen size and marked the chosen way, so the controls show what they
                // do rather than describing it.
                Text(specimen)
                    .foregroundStyle(.secondary)
                    .lineSpacing(appearance.scale.text.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, scale.space.stack)
            }

            Section {
                Toggle("Name the app a word was read in", isOn: $appearance.showsPlaceName)
                Toggle("Show the time a word was looked up", isOn: $appearance.showsTime)
            } header: {
                Text("On a card")
            }

            // Which glass is right depends on what is usually behind the drawer, and only the
            // reader knows that. Frosted over a black terminal is flat grey — working glass that
            // looks broken — which is why this is a choice rather than a constant.
            Section {
                Picker("Glass", selection: $appearance.drawerGlass) {
                    ForEach(DrawerGlass.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Reading history drawer")
            } footer: {
                Text("""
                     Frosted keeps cards and headings easy to read over any window. Clear shows \
                     more of what is behind the drawer — over a dark terminal it stays dark \
                     instead of turning grey.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        private var specimen: AttributedString {
            var text = AttributedString("The quick brown fox jumps over the lazy dog.")
            guard let marked = text.range(of: "jumps") else { return text }
            let chosen = appearance.emphasis
            var font = Font.system(size: appearance.scale.text.body, weight: chosen.weight)
            if chosen.isItalic { font = font.italic() }
            text[marked].font = font
            text[marked].foregroundColor = ReadingPalette.accents[
                ReadingPalette.index(for: "jumps")].color(in: .light)
            return text
        }
    }
}

// MARK: - Lookup

/// How a lookup starts: the shortcut, and the hover gate.
///
/// Every control here edits a field `HoverPolicy` has had since it was written and that nothing
/// could reach: the only policy that existed was the hardcoded `.shipped`. The exception is the
/// password-manager list, which is a rule rather than a preference and so is shown and not
/// offered — the ledger stores the sentence a word was read in, and in a password manager the
/// whole surface is secrets.
struct LookupPane: View {
    @Environment(\.scale) private var scale
    @Binding var policy: HoverPolicy
    var shortcut: ShortcutChoice?
    /// The shortcut field's recorder. Held by the settings model, because ending it belongs to
    /// whoever knows the reader has left this pane — which this pane cannot see.
    var capture = ShortcutCapture()
    @State private var host = ""

    var body: some View {
        Form {
            shortcutSection
            gateSection
            appsSection
            sitesSection
        }
        .formStyle(.grouped)
    }

    /// The lookup shortcut, as a setting rather than a window of its own.
    private var shortcutSection: some View {
        // The shortcut was a window of its own, which activated XiaolaiDict to open and left it
        // active with nothing on screen when it closed. It is a setting; it lives here.
        Section {
            if let shortcut {
                ShortcutField(choice: shortcut, capture: capture)
            } else {
                Text("This pane is not connected to the shortcut.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Whatever is selected is looked up, wherever you are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What must be true before a hover looks anything up.
    private var gateSection: some View {
        Section {
            Picker("Hold", selection: $policy.modifier) {
                ForEach(HoverModifier.allCases, id: \.self) { modifier in
                    Text(verbatim: "\(modifier.name)  \(modifier.symbol)").tag(modifier)
                }
            }

            Picker("Rest the pointer", selection: $policy.settleMilliseconds) {
                ForEach(HoverPolicy.settleChoices) { Text($0.name).tag($0.milliseconds) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("The gate")
        } footer: {
            Text("""
                 A hover only fires while the key is held and the pointer has stopped. \
                 There is no setting for holding nothing.
                 """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Apps XiaolaiDict never looks up in: the password managers by rule, and the reader's own.
    private var appsSection: some View {
        Section {
            // **The rule as one row, with what it covers a click away.** Every password manager
            // was a row of its own, by bundle identifier — twelve of them, `com.agilebits.
            // onepassword7` and its kind, each marked "always". It made this the tallest pane
            // in the window, measured at 1,184 points and taller than a MacBook's screen, and
            // told the reader nothing they could act on: none of those rows had a control.
            DisclosureGroup {
                ForEach(Self.passwordManagers, id: \.self) { AppRow(bundleID: $0) }
            } label: {
                LabeledContent(String(localized: "Password managers")) {
                    Text("Always").foregroundStyle(.secondary)
                }
            }
            ForEach(readersOwn, id: \.self) { app in
                HStack {
                    AppRow(bundleID: app)
                    Spacer(minLength: scale.space.inline)
                    Button("Remove") { policy.excludedApps.remove(app) }
                        .buttonStyle(.link)
                }
            }
            Button("Add an app…") { addApp() }
        } header: {
            Text("Never look up in these apps")
        } footer: {
            Text("""
                 Password managers cannot be removed. The sentence a word was read in is \
                 recorded, and there every sentence is a secret.
                 """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sites XiaolaiDict never looks up on.
    private var sitesSection: some View {
        Section {
            ForEach(policy.excludedHosts.sorted(), id: \.self) { site in
                HStack {
                    Text(site)
                    Spacer(minLength: scale.space.inline)
                    Button("Remove") { policy.excludedHosts.remove(site) }
                        .buttonStyle(.link)
                }
            }
            HStack {
                TextField("example.com", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addHost)
                Button("Add", action: addHost)
                    .disabled(HoverPolicy.normalisedHost(host).isEmpty)
            }
        } header: {
            Text("Never look up on these sites")
        } footer: {
            Text("Subdomains are covered too, so example.com also excludes docs.example.com.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The apps the reader added, which are the only ones they can take away again.
    private var readersOwn: [String] {
        policy.excludedApps.subtracting(HoverPolicy.defaultExcludedApps).sorted()
    }

    /// Installed ones first, by name, so the password manager the reader actually uses is at the
    /// top of the list rather than somewhere among identifiers for apps they have never had.
    @MainActor private static var passwordManagers: [String] {
        HoverPolicy.defaultExcludedApps.sorted { left, right in
            switch (AppNames.name(for: left), AppNames.name(for: right)) {
            case let (l?, r?): l.localizedStandardCompare(r) == .orderedAscending
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): left < right
            }
        }
    }

    /// Normalised on the way in, for the reason `HoverPolicy` normalises on the way out: an
    /// exclusion typed as `EXAMPLE.COM.` that fails to match `example.com` is not an exclusion.
    private func addHost() {
        let normalised = HoverPolicy.normalisedHost(host)
        guard !normalised.isEmpty else { return }
        policy.excludedHosts.insert(normalised)
        host = ""
    }

    /// The bundle identifier is read from the app the reader picked, never typed. Asking someone
    /// to enter `com.agilebits.onepassword7` by hand is asking for an exclusion that silently
    /// covers nothing.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        policy.excludedApps.insert(identifier)
    }
}

/// An app as a reader knows it: its icon and its name. **The identifier only when that is all there
/// is** — an app that is not installed has no name to give, and is shown as what it is rather than
/// dressed as something the system said. The identifier is always a hover away, because it is what
/// the rule actually matches on.
private struct AppRow: View {
    @Environment(\.scale) private var scale
    let bundleID: String

    var body: some View {
        HStack(spacing: scale.space.inline) {
            if let icon = AppIcons.icon(for: bundleID) {
                // Sized to the name beside it, as a card sizes the icon of the app a word was read
                // in: a glyph standing with its text, not a picture beside it.
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: scale.text.body, height: scale.text.body)
                    .accessibilityHidden(true)
            }
            if let name = AppNames.name(for: bundleID) {
                Text(name)
            } else {
                Text(bundleID)
                    .font(.system(size: scale.text.label).monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .help(bundleID)
    }
}

// MARK: - Dictionary

/// Decision D7: the reader studies from **one** dictionary.
struct DictionaryPane: View {
    @Environment(\.scale) private var scale
    var choice: DictionaryChoice?

    var body: some View {
        Form {
            Section {
                if let choice, let available = choice.available {
                    Picker("Dictionary", selection: binding(choice)) {
                        Text("First that marks senses").tag(String?.none)
                        ForEach(available, id: \.identity.key) { capability in
                            // What choosing it can key, beside its name: a dictionary that marks
                            // senses with nothing a parser can read only ever gives whole-entry
                            // cards, and the reader should see that before choosing rather than
                            // after a week of them.
                            Text(verbatim: "\(capability.identity.name) — \(capability.note)")
                                .tag(String?.some(capability.identity.key))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } else if choice != nil {
                    Text("Asking the dictionary service…").foregroundStyle(.secondary)
                } else {
                    Text("This pane is not connected to the dictionary service.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Study from")
            }

            Section {
                Label {
                    Text("Switching dictionaries starts study over.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("""
                     A sense id only means anything inside the dictionary that issued it, so \
                     what has been learned about your senses cannot follow you to another one. \
                     Your reading history is kept either way.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// A binding rather than a button per row, so the pane says "one of these" the way the
    /// decision does.
    private func binding(_ choice: DictionaryChoice) -> Binding<String?> {
        Binding(get: { choice.chosen }, set: { choice.choose($0) })
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    @Environment(\.scale) private var scale
    var model: SettingsModel
    var openSetup: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Text(verdict).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The other way into the board. This pane answers "are my permissions on"; the
                // board answers "is any of this working", which is the question a reader who came
                // here actually has.
                if let openSetup {
                    Button("Set Up…") { openSetup() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            ForEach(model.report.states) { state in
                Section {
                    PermissionRow(state: state)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Asking costs a ScreenCaptureKit round trip, so there is a moment before the answer. Saying
    /// so beats showing a verdict that is merely the empty state.
    private var verdict: String {
        guard model.hasAsked else { return "Checking…" }
        return model.report.allGranted ? "Everything needed has been granted." : (model.report.menuWarning ?? "")
    }
}

struct PermissionRow: View {
    @Environment(\.scale) private var scale
    let state: PermissionState

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                Image(systemName: state.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.isGranted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                Text(state.permission.name).font(.system(size: scale.text.heading, weight: .medium))
                Spacer(minLength: scale.space.inline)
                Text(state.isGranted ? "On" : "Off")
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(state.permission.blocks)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.isGranted {
                Text(state.permission.location)
                    .font(.system(size: scale.text.label))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                HStack(spacing: scale.space.stack) {
                    // Asks macOS to prompt. It will do so only the first time ever, which is why
                    // the button beside it exists and why the list is named above.
                    Button("Ask macOS…") { state.permission.request() }
                        .buttonStyle(.glassProminent)
                    Button("Open Settings…") { NSWorkspace.shared.open(state.permission.settingsURL) }
                        .buttonStyle(.glass)
                }
                .controlSize(.small)
            }
        }
        // No glass here. A grouped `Form` section already *is* the raised surface, and the
        // project's rule against glass inside glass is exactly this case — the rows carried their
        // own `glassEffect` when they were laid out by hand in a `ScrollView`.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

/// Which build of XiaolaiDict this is.
///
/// **Read from the bundle, never written here.** The version is declared in `Resources/Info.plist`
/// and `Resources/DictionaryService-Info.plist`, and `build-bundle.sh` fails the build when those
/// two disagree. A number typed into a view would be a third declaration with nothing checking it,
/// and it would be the one the reader sees.
public struct AppRelease: Equatable, Sendable {
    /// `CFBundleShortVersionString` — what a release is called.
    public let version: String
    /// `CFBundleVersion` — which build it is. Development builds number themselves from the clock,
    /// so this is what tells two otherwise identical-looking builds apart.
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// From a bundle's own dictionary, or nil where it declares no version.
    ///
    /// Taking the dictionary rather than the `Bundle` is what makes this testable: a test cannot
    /// fabricate a bundle, and asserting against whichever bundle happens to be running would
    /// measure the test runner.
    public init?(infoDictionary: [String: Any]?) {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = infoDictionary?["CFBundleVersion"] as? String,
              !version.isEmpty, !build.isEmpty
        else { return nil }
        self.init(version: version, build: build)
    }

    public init?(_ bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    /// The build is in brackets because it is not the name of anything — two builds of 0.0.2 are
    /// both 0.0.2, and the bracketed number is the only thing that separates them.
    public var label: String { "Version \(version) (\(build))" }
}

/// Who made this, and which build it is.
///
/// A window rather than an App menu item because XiaolaiDict has no App menu: it is an accessory app, so
/// the menu-bar extra is the whole of its menu and Settings is the only window a reader can reach
/// from it.
struct AboutPane: View {
    @Environment(\.scale) private var scale
    var release: AppRelease?

    /// Built once and checked, rather than force-unwrapped at the call site. A link that is nil is
    /// a link that is not drawn — never a crash on a settings pane.
    private static let site = URL(string: "https://lixiaolai.com")

    var body: some View {
        Form {
            Section {
                HStack(spacing: scale.space.column) {
                    if let icon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: Token.Panel.aboutIcon, height: Token.Panel.aboutIcon)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: scale.space.line) {
                        Text("XiaolaiDict")
                            .font(.system(size: scale.text.display, weight: .semibold))
                        Text("A menu-bar dictionary for macOS.")
                            .foregroundStyle(.secondary)
                        // Nothing is invented where the bundle says nothing: a pane that printed
                        // "unknown" would be claiming to have looked and found that answer.
                        if let release {
                            Text(release.label)
                                .font(.system(size: scale.text.label))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, scale.space.stack)
            }

            Section {
                LabeledContent("Author") {
                    if let site = Self.site {
                        Link(destination: site) { Text(verbatim: "@xiaolai") }
                    } else {
                        Text(verbatim: "@xiaolai")
                    }
                }
                if let site = Self.site {
                    LabeledContent("Website") {
                        Link(site.host() ?? site.absoluteString, destination: site)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
