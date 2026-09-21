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

    public init(available: [DictionaryCapability]?, chosen: String?, choose: @escaping (String?) -> Void) {
        self.available = available
        self.chosen = chosen
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
                Text("Frosted keeps cards and headings easy to read over any window. Clear shows "
                     + "more of what is behind the drawer — over a dark terminal it stays dark "
                     + "instead of turning grey.")
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

// MARK: - Hover

/// The hover gate, made settable.
///
/// Every control here edits a field `HoverPolicy` has had since it was written and that nothing
/// could reach: the only policy that existed was the hardcoded `.shipped`. The exception is the
/// password-manager list, which is a rule rather than a preference and so is shown and not
/// offered — the ledger stores the sentence a word was read in, and in a password manager the
/// whole surface is secrets.
struct HoverPane: View {
    @Environment(\.scale) private var scale
    @Binding var policy: HoverPolicy
    @State private var host = ""

    var body: some View {
        Form {
            Section {
                Picker("Hold", selection: $policy.modifier) {
                    ForEach(HoverModifier.allCases, id: \.self) { modifier in
                        Text("\(modifier.name)  \(modifier.symbol)").tag(modifier)
                    }
                }

                Picker("Rest the pointer", selection: $policy.settleMilliseconds) {
                    ForEach(HoverPolicy.settleChoices) { Text($0.name).tag($0.milliseconds) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("The gate")
            } footer: {
                Text("A hover only fires while the key is held and the pointer has stopped. "
                     + "There is no setting for holding nothing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(policy.excludedApps.sorted(), id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer(minLength: scale.space.inline)
                        if HoverPolicy.defaultExcludedApps.contains(app) {
                            Text("always").foregroundStyle(.secondary)
                        } else {
                            Button("Remove") { policy.excludedApps.remove(app) }
                                .buttonStyle(.link)
                        }
                    }
                }
                Button("Add an app…") { addApp() }
            } header: {
                Text("Never look up in these apps")
            } footer: {
                Text("Password managers cannot be removed. XiaolaiDict records the sentence a word was "
                     + "read in, and there every sentence is a secret.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

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
        .formStyle(.grouped)
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
                            Text("\(capability.identity.name) — \(capability.note)")
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
                Text("A sense id only means anything inside the dictionary that issued it, so "
                     + "what XiaolaiDict has learned about your senses cannot follow you to another one. "
                     + "Your reading history is kept either way.")
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

    var body: some View {
        Form {
            Section {
                Text(verdict).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        return model.report.allGranted ? "XiaolaiDict has everything it needs." : (model.report.menuWarning ?? "")
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
                        Link("@xiaolai", destination: site)
                    } else {
                        Text("@xiaolai")
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
