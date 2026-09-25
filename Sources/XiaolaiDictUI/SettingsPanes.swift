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
    /// Asks the service again, discarding its last answer.
    ///
    /// **The failure state needs an action, not just a sentence.** Telling the reader the
    /// service did not answer, with nothing to do about it, leaves them to guess that
    /// reopening the window might help — and nothing guarantees it does: the dictionary list
    /// is asked once and handed in, and the window's own polling `.task` refreshes
    /// permissions, not this.
    public var reask: () -> Void

    public init(
        available: [DictionaryCapability]?, chosen: String?, hasAsked: Bool = false,
        choose: @escaping (String?) -> Void, reask: @escaping () -> Void = {}
    ) {
        self.available = available
        self.chosen = chosen
        self.hasAsked = hasAsked
        self.reask = reask
        self.choose = choose
    }
}

// MARK: - Reading

struct ReadingPane: View {
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
        /// The specimen's accent follows the appearance, the way a card's does.
        @Environment(\.colorScheme) private var scheme
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

            Section {
                Toggle(
                    "Say when a word was read off the screen",
                    isOn: $appearance.warnsAboutScreenReading)
            } header: {
                Text("In the panel")
            } footer: {
                // One literal with backslash continuations, so it stays a literal: a `+` makes it
                // a String and SwiftUI takes the verbatim overload, which extracts nothing.
                Text("""
                     Words in a terminal, a canvas or an image are read from the pixels. That is \
                     the one way of reading a word that can be wrong rather than simply missing — \
                     and you can check it yourself, because the word it read is the one shown.
                     """)
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

        /// The sentence and the one word in it that is set in the reader's chosen emphasis. A pair:
        /// the word has to occur in the sentence, so a translation that moves one must move the
        /// other. It degrades to an unemphasised specimen rather than to a wrong one if it does not
        /// — `MarkedSentence` drops a range it cannot place, which is what `NSString.range(of:)`
        /// hands it when the word is missing.
        ///
        /// **Through `MarkedSentence`, like the two cards.** This was a third implementation of
        /// marking a word in a sentence, written out beside the one the lookup card and the drawer
        /// share — the same drift those two had, in the one surface whose whole job is to show the
        /// reader what their setting does. It had already gone wrong in the way a copy does: the
        /// accent was pinned to `.light`, so in a dark appearance the control previewed a shade no
        /// card would ever draw.
        private var specimen: AttributedString {
            let sentence = String(localized: "The quick brown fox jumps over the lazy dog.",
                                  comment: "Type specimen in the Reading pane; any sentence that shows off the reader's script will do")
            let emphasised = String(localized: "jumps",
                                    comment: "The one word of the specimen shown in the reader's chosen emphasis; it must occur in that sentence")
            return MarkedSentence.text(
                sentence, marking: [(sentence as NSString).range(of: emphasised)],
                size: appearance.scale.text.body, emphasis: appearance.emphasis,
                accent: ReadingPalette.accent(for: emphasised).color(in: scheme))
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

            // **Scripts, because only a script is decidable from one word.** A row saying
            // "English only" would be a promise the code cannot keep: a single word gives
            // `NLLanguageRecognizer` far too little to separate English from German, and the
            // hover path often has no sentence to offer it. Naming the writing system says
            // exactly what is checked.
            ForEach(ProbeScript.allCases, id: \.self) { script in
                // **The last remaining box is disabled, not silently refused.** The binding
                // still guards — an empty set looks up almost nothing — but a control that
                // accepts a click and does nothing reads as a broken switch. Disabled, the
                // reason is visible before the click rather than inferred after it.
                Toggle(isOn: binding(for: script)) { Self.label(for: script) }
                    .disabled(isTheOnlyScriptChosen(script))
            }
            if policy.scripts.count == 1 {
                Text("At least one script has to stay ticked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The gate")
        } footer: {
            // **The second sentence is the whole reason this footer changed.** A word in an
            // unticked script is read and then dropped, and hover's refusals are otherwise silent
            // — "you did not hold the key" explains itself, this does not. A reader who never
            // opened this pane still gets the default, so the place they will go looking when
            // nothing happens over a Chinese word has to answer them.
            Text("""
                 A hover only fires while the key is held and the pointer has stopped. \
                 There is no setting for holding nothing. \
                 Hovering a word in a script you have not ticked looks nothing up, and your \
                 reading history shows only the scripts ticked here. Looking a word up from \
                 a selection still works whatever it is written in. Nothing is deleted: \
                 ticking a script back shows its words again.
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

    /// What each script is called, in the reader's own words.
    ///
    /// **Here and not on `ProbeScript`**, which lives in `XiaolaiDictCore` — a module with no view
    /// layer, where a sentence can be written and never extracted for a translator.
    /// `theCoreHoldsNoDisplayText` is what keeps that true. The scripts are named the way a reader
    /// names them rather than the way Unicode does: "Chinese characters", not "Han".
    static func label(for script: ProbeScript) -> Text {
        switch script {
        case .latin: Text("Latin — English and most European languages")
        // **Named for what it governs, not for what Unicode calls it.** `日本語` is written
        // entirely in kanji and classifies as han, so a Japanese reader who ticks only
        // "Japanese kana" is refused most of their own language. "Chinese characters" alone
        // hid that, and the reader had no way to find out except by it not working.
        case .han: Text("Chinese characters / Japanese kanji")
        case .hangul: Text("Korean")
        case .kana: Text("Japanese kana")
        }
    }

    /// Whether `script` is the only one left ticked, which is what makes its box read-only.
    private func isTheOnlyScriptChosen(_ script: ProbeScript) -> Bool {
        policy.scripts == [script]
    }

    /// One box per script, and **the last one cannot be unticked**.
    ///
    /// An empty set looks up nothing at all, which is not a preference any reader is expressing —
    /// it is a state a settings pane can walk into one click at a time, and the reader would then
    /// find hover silently dead with every other setting looking right. `HoverPolicyStore` repairs
    /// it on the way in as a backstop; this stops it being reachable.
    private func binding(for script: ProbeScript) -> Binding<Bool> {
        Binding(
            get: { policy.scripts.contains(script) },
            set: { wanted in
                var scripts = policy.scripts
                if wanted {
                    scripts.insert(script)
                } else {
                    scripts.remove(script)
                }
                guard !scripts.isEmpty else { return }
                policy.scripts = scripts
            })
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
                } else if let choice, !choice.hasAsked {
                    Text("Asking the dictionary service…").foregroundStyle(.secondary)
                } else if choice != nil {
                    // **Asked and answered with nothing is not still asking.** The pane said
                    // "Asking…" for as long as it was open whenever discovery finished without
                    // a list — a spinner that never resolves, describing a request that had
                    // already come back. `hasAsked` is the flag the app already sets and
                    // `SetupView` already reads; this pane was simply not looking at it.
                    VStack(alignment: .leading) {
                        Text("The dictionary service did not answer.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let choice { Button("Ask again") { choice.reask() } }
                    }
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
    var model: SettingsModel
    var openSetup: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Text(verbatim: verdict).foregroundStyle(.secondary)
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
        guard model.hasAsked else {
            return String(localized: "Checking…", comment: "While the permissions are being probed")
        }
        guard model.report.allGranted else { return model.report.menuWarning ?? "" }
        return String(localized: "Everything needed has been granted.",
                      comment: "Permissions pane, when nothing is missing")
    }
}

struct PermissionRow: View {
    @Environment(\.scale) private var scale
    let state: PermissionState

    /// Three states, three marks. Unknown is neither a tick nor a warning: it is the question mark
    /// it actually is, and it does not wear the orange that means *you need to do something*.
    private var symbol: String {
        switch state.found {
        case .granted: "checkmark.circle.fill"
        case .declined: "exclamationmark.triangle.fill"
        case .couldNotTell: "questionmark.circle.fill"
        }
    }

    private var tint: AnyShapeStyle {
        switch state.found {
        case .granted: AnyShapeStyle(.green)
        case .declined: AnyShapeStyle(.orange)
        case .couldNotTell: AnyShapeStyle(.secondary)
        }
    }

    private var status: Text {
        switch state.found {
        case .granted: Text("On")
        case .declined: Text("Off")
        // Never "Off": that is a claim about the reader's consent, and this is a claim about the
        // check.
        case .couldNotTell: Text("Unknown")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(verbatim: state.permission.name)
                    .font(.system(size: scale.text.heading, weight: .medium))
                Spacer(minLength: scale.space.inline)
                status
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(verbatim: state.permission.blocks)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // **Only where the reader has actually been refused.** An unknown grant gets the line
            // below instead: naming a settings list, and offering to prompt for something that may
            // already be on, sends them to look at a switch that is already where it should be.
            if state.found == .declined {
                Text(verbatim: state.permission.location)
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
            // Says what happened and asks for nothing. A check that could not run is a fact about
            // this moment, not about the reader's consent, and the next refresh usually answers.
            if state.found == .couldNotTell {
                Text("This could not be checked just now. It will be asked again.")
                    .font(.system(size: scale.text.label))
                    .foregroundStyle(.tertiary)
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
    /// The local model's licence file, where a model is downloaded. It comes with the weights —
    /// from the upstream repository, because the MLX mirror carries none — so a reader who has the
    /// model has the licence it was published under.
    var modelLicence: URL?
    /// The licences of the open-source packages the app is built from, as the bundle carries them.
    /// Handed in rather than read here for the same reason the release is: a preview and a test
    /// would otherwise be looking at Xcode's bundle.
    var notices: URL?
    /// Shown when neither the downloaded licence nor the published one would open.
    @State private var licenceWouldNotOpen = false
    /// Shown when the notices are in the bundle and the system would not open them.
    @State private var noticesWouldNotOpen = false

    /// Built once and checked, rather than force-unwrapped at the call site. A link that is nil is
    /// a link that is not drawn — never a crash on a settings pane.
    private static let site = URL(string: "https://lixiaolai.com")
    /// The licence as published. **Readable before the download, not only after it**: a reader
    /// deciding whether to fetch 3 GB is owed the terms first, and the copy that comes with the
    /// weights does not exist yet. Once it does, it is the one opened — same text, no network.
    private static let licence = LocalModelAttribution.licenceURL

    /// Four subjects, four sections: which app this is, who made it, what the model it can download
    /// is licensed under, and what it is itself built from.
    var body: some View {
        Form {
            identity
            author
            localModel
            openSource
        }
        .formStyle(.grouped)
    }

    /// Which app this is, and which build.
    @ViewBuilder private var identity: some View {
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
    }

    /// Who made it, and where to find them.
    @ViewBuilder private var author: some View {
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

    /// Which model, whose, and under what terms — named whether or not it is downloaded.
    @ViewBuilder private var localModel: some View {
        Section("Local model") {
            LabeledContent("Model") { Text(verbatim: LocalModelAttribution.family) }
            LabeledContent("Made by") { Text(verbatim: LocalModelAttribution.publisher) }
            LabeledContent("Licence") {
                if let destination = modelLicence ?? Self.licence {
                    Button { open(destination) } label: { Text(verbatim: LocalModelAttribution.licenceName) }
                        .buttonStyle(.link)
                } else {
                    Text(verbatim: LocalModelAttribution.licenceName)
                }
            }
            if licenceWouldNotOpen {
                // The name is not a place. A reader who cannot open the link is given the address.
                Text("The licence could not be opened. It is published under \(LocalModelAttribution.licenceName), at \(LocalModelAttribution.licenceURL?.absoluteString ?? "apache.org").")
                    .textSelection(.enabled)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the app itself is built from. Both licences the dependencies carry — MIT and
    /// Apache-2.0 — ask that their notice travel with every copy of the software, and a static link
    /// leaves nothing in the bundle to say the code is there. The file is generated at build time
    /// from the packages SwiftPM resolved, so it cannot fall behind them.
    ///
    /// **Drawn only where the file is there.** Outside a built bundle — a preview, a test — there is
    /// nothing to open, and a button that cannot do anything is worse than no button.
    @ViewBuilder private var openSource: some View {
        if let notices {
            Section("Open source") {
                LabeledContent("Licences") {
                    Button { open(notices, missing: $noticesWouldNotOpen) } label: { Text("Third-party notices") }
                        .buttonStyle(.link)
                }
                if noticesWouldNotOpen {
                    // The reader is told where it is, so the text is reachable without this button.
                    Text("The notices could not be opened. They are in the app itself, at \(notices.path()).")
                        .textSelection(.enabled)
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Opens a file the app carries, and says so when the system refuses — the same rule as the
    /// licence below, without the published-copy fallback, because a file inside the bundle has no
    /// second address.
    private func open(_ url: URL, missing: Binding<Bool>) {
        missing.wrappedValue = !NSWorkspace.shared.open(url)
    }

    /// Opens the downloaded copy, and falls back to the published one where that will not open —
    /// a button that silently does nothing is worse than one that shows the same text from the web.
    /// **And says so where neither opens**, for the same reason: a link the system refuses must not
    /// read as a button the reader failed to press.
    private func open(_ url: URL) {
        // **Answered afresh on every attempt.** Set once and left, the message stood over the next
        // attempt, which worked.
        if NSWorkspace.shared.open(url) {
            licenceWouldNotOpen = false
            return
        }
        guard url != Self.licence, let published = Self.licence else {
            licenceWouldNotOpen = true
            return
        }
        licenceWouldNotOpen = !NSWorkspace.shared.open(published)
    }
}
