import AppKit
import Capture
import DictionaryModel
import AVFoundation
import StudyPresentation
import SwiftUI

// MARK: - Reading

/// **What the speak button will sound like, and the one thing the reader can do about it.**
///
/// English, because that is the language of the words this dictionary is asked about: the button
/// speaks the headword. A reader looking a Chinese word up is told about that voice on the card
/// itself, where the sentence is known and the language can be detected.
///
/// It is here rather than on the setup board because it is a standing preference — the board is
/// for what a fresh install still needs, and a voice is neither missing nor blocking.
struct SpeakingVoiceSection: View {
    /// The words this dictionary is asked about.
    private static let language = "en"

    /// **What is drawn, held rather than recomputed in `body`.**
    ///
    /// It used to ask `Speech` from inside `body` and keep a `generation` counter that `body` never
    /// read — so the redraw rested on `@State` invalidation alone, with no visible dependency
    /// between the counter and anything on screen. Holding the answers makes the dependency the
    /// thing it actually is, and keeps a memoised-but-not-free lookup off the layout path.
    @State private var voiceName: String?
    @State private var caveat: String?
    @State private var advice: Speech.VoiceAdvice = .unknown

    var body: some View {
        Section {
            LabeledContent("Voice") {
                if let voiceName {
                    // A voice's name is a proper noun; macOS calls it that in every language.
                    Text(verbatim: voiceName)
                } else {
                    Text("None installed")
                }
            }
            if let caveat {
                Text(caveat)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Offered wherever there is somewhere to go — a named voice, or a language nobody
                // has checked, which is most of them. Withheld only where the absence is measured:
                // a button that leads nowhere is worse than none, and this is the one screen where
                // that would waste a trip.
                if advice != .nothingBetter {
                    // Bordered, not glass: glass is for controls floating over content, and
                    // this is a row of a form.
                    Button("Open VoiceOver Utility…") { Speech.openVoiceLibrary() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Speaking")
        }
        .task { refresh() }
        // **Delivered on the main queue explicitly.** `NotificationCenter`'s publisher fires on
        // whichever thread posted, and nothing documents which thread macOS posts this one from —
        // while everything the closure touches is main-actor isolated.
        .onReceive(NotificationCenter.default.publisher(
            for: AVSpeechSynthesizer.availableVoicesDidChangeNotification
        ).receive(on: DispatchQueue.main)) { _ in
            // Cleared here rather than waited for: the observer inside `Speech` hops to the main
            // actor through a `Task` and may land after this, leaving the row drawing the answer
            // it is redrawing to escape.
            Speech.forgetInstalledVoices()
            refresh()
        }
    }

    private func refresh() {
        voiceName = Speech.bestVoice(for: Self.language)?.name
        caveat = Speech.caveat(for: Self.language)
        advice = Speech.advice(for: Self.language)
    }
}

/// How a reading looks and sounds: the type, what a card carries, the voice.
///
/// What is saved for study and the command that deletes the reading history were here too, under
/// a text-size icon; they are the app's behaviour rather than a card's appearance and moved to
/// `GeneralPane` on 2026-10-02, which is where the reasoning is.
struct ReadingPane: View {
    var appearance: Appearance?

    var body: some View {
        Form {
            if let appearance {
                Bound(appearance: appearance)
            } else {
                Section { Unavailable() }
            }
            SpeakingVoiceSection()
        }
        .formStyle(.grouped)
    }

    /// Split out because `@Bindable` needs a non-optional, and unwrapping inside a `body` with a
    /// `$` binding is not something an `if let` can produce.
    private struct Bound: View {
        @Environment(\.scale) private var scale
        /// The specimen's accent follows the appearance, the way a card's does.
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Bindable var appearance: Appearance

        var body: some View {
            // A named list rather than a slider: every step is a size the surfaces have been
            // looked at, and a free number would let the reader build a layout nobody designed.
            //
            // **A pop-up, not segments.** It was segmented while there were four sizes. With six
            // — Extra Large and Huge arrived 2026-10-02 — the segments do not fit a 580-point
            // pane, and past about five choices a pop-up is the control for one-of-many anyway.
            // The sample below is what shows the difference; the menu only has to name it.
            Section {
                Picker("Size", selection: $appearance.textSize) {
                    ForEach(TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Picker("Mark the word", selection: $appearance.emphasis) {
                    ForEach(WordEmphasis.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text")
            } footer: {
                // Set in the chosen size and marked the chosen way, so the controls show what they
                // do rather than describing it. In the label colour a card's sentence is set in:
                // a grey sample would preview the size and misreport the contrast.
                Text(specimen)
                    .foregroundStyle(.primary)
                    .lineSpacing(appearance.scale.text.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, scale.space.stack)
            }

            Section {
                Toggle("Name the app a word was read in", isOn: $appearance.showsPlaceName)
                Toggle("Show the time a word was looked up", isOn: $appearance.showsTime)
            } header: {
                Text("On a Card")
            }

            Section {
                Toggle("Use a compact lookup card", isOn: $appearance.usesCompactLookup)
                    .help(Text("Show a short dictionary preview, with More meanings for the full reading card."))
                Toggle(
                    "Say when a word was read off the screen",
                    isOn: $appearance.warnsAboutScreenReading)
            } header: {
                Text("In the Lookup Window")
            } footer: {
                // One literal with backslash continuations, so it stays a literal: a `+` makes it
                // a String and SwiftUI takes the verbatim overload, which extracts nothing.
                Text("""
                     Words in a terminal, a canvas or an image are read from the pixels. That is \
                     the one way of reading a word that can be wrong rather than simply missing — \
                     and you can check it yourself, because the word it read is the one shown.
                     """)
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
                // Keyed by the word itself: a specimen has no lemma to look up, and all this needs
                // is the same word giving the same hue every time.
                accent: ReadingPalette.color(forLemma: emphasised, in: scheme, contrast: contrast))
        }
    }
}

// MARK: - Lookup

/// How a lookup starts: the shortcut, and hovering.
///
/// Every control here edits a field `HoverPolicy` has had since it was written and that nothing
/// could reach: the only policy that existed was the hardcoded `.shipped`. The exception is the
/// password-manager list, which is a rule rather than a preference and so is shown and not
/// offered — the ledger stores the sentence a word was read in, and in a password manager the
/// whole surface is secrets.
struct LookupPane: View {
    @Environment(\.scale) private var scale
    @Binding var policy: HoverPolicy
    /// Whether hover is running at all — the *watcher*, not a field of the policy, which is why it
    /// arrives separately. Nil where the pane is drawn without the app behind it.
    var hoverEnabled: Binding<Bool>?
    /// Reading the screen has stopped answering. **Said here because nothing else says it**: the
    /// one capture allowed at a time is held by a capture that never finished, so hover over a
    /// terminal does nothing, and a refusal on the hover path is otherwise silent.
    var captureStuck = false
    var shortcut: ShortcutChoice?
    /// The shortcut field's recorder. Held by the settings model, because ending it belongs to
    /// whoever knows the reader has left this pane — which this pane cannot see.
    var capture = ShortcutCapture()

    var body: some View {
        Form {
            shortcutSection
            hoverSection
            scriptsSection
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
                Unavailable()
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Looks up the text you have selected, in any app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What must be true before a hover looks anything up.
    private var hoverSection: some View {
        Section {
            // **The switch, above everything it governs.** It was in the menu bar menu and nowhere
            // else, so this pane could configure a hover that the reader had no way to turn off
            // from here — and when the menu was trimmed to the things a reader reaches for often,
            // switching hover off would have had nowhere left to live.
            //
            // Read from the watcher rather than from the setting: if starting it failed, this says
            // off, which is what is true.
            if let hoverEnabled {
                Toggle("Look up on hover", isOn: hoverEnabled)
            }

            // **Which key, and what the reader does with it — two questions, two rows.** The row
            // was labelled "Hold", which was right only while holding was the only gesture; a
            // label that names the wrong action is worse than none, because the reader does it
            // and nothing happens.
            Picker("Key", selection: $policy.modifier) {
                ForEach(HoverModifier.allCases, id: \.self) { modifier in
                    // Composed from a localized name and the key's own glyph, so it is verbatim
                    // here and the name is in the catalog — see `HoverLabels`.
                    Text(verbatim: "\(HoverLabels.name(of: modifier))  \(modifier.symbol)").tag(modifier)
                }
            }

            Picker("Gesture", selection: $policy.gesture) {
                ForEach(HoverGesture.allCases, id: \.self) { gesture in
                    Text(verbatim: "\(HoverLabels.name(of: gesture))  \(gesture.label(policy.modifier))").tag(gesture)
                }
            }
            .pickerStyle(.segmented)

            Picker("Rest the pointer", selection: $policy.settleMilliseconds) {
                ForEach(HoverPolicy.settleChoices) { Text(HoverLabels.name(of: $0)).tag($0.milliseconds) }
            }
            .pickerStyle(.segmented)

            if captureStuck {
                // **Only the hovers that need the screen**: Accessibility is still asked while a
                // capture is held, and only the capture path waits for the one guard.
                Text("""
                     Reading the screen has stopped answering, so words in apps that do not \
                     expose their text cannot be looked up. Quitting and reopening the app clears it.
                     """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Hover")
        } footer: {
            Text("A word is looked up when you use the key and the pointer has stopped over it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which writing systems a hover looks up.
    ///
    /// **Scripts, because only a script is decidable from one word.** A row saying "English only"
    /// would be a promise the code cannot keep: a single word gives `NLLanguageRecognizer` far too
    /// little to separate English from German, and the hover path often has no sentence to offer
    /// it. Naming the writing system says exactly what is checked.
    ///
    /// **Checkboxes, in a section of their own.** They were switches at the end of the hover
    /// section while the text around them said "ticked" — a set of independent choices is what a
    /// checkbox is for, and a switch is for one thing that is on or off.
    private var scriptsSection: some View {
        Section {
            ForEach(ProbeScript.allCases, id: \.self) { script in
                // **The last remaining box is disabled, not silently refused.** The binding
                // still guards — an empty set looks up almost nothing — but a control that
                // accepts a click and does nothing reads as a broken switch. Disabled, the
                // reason is visible before the click rather than inferred after it.
                Toggle(isOn: binding(for: script)) { Self.label(for: script) }
                    .toggleStyle(.checkbox)
                    .disabled(isTheOnlyScriptChosen(script))
            }
            if policy.scripts.count == 1 {
                Text("At least one script has to stay selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scripts")
        } footer: {
            // **This footer is where a silent refusal gets explained.** A word in a script that
            // is not selected is read and then dropped, and hover's refusals are otherwise silent
            // — "you did not hold the key" explains itself, this does not. A reader who never
            // opened this pane still gets the default, so the place they will go looking when
            // nothing happens over a Chinese word has to answer them.
            Text("""
                 Hover looks up only words written in the selected scripts, and Reading History \
                 shows only those. Looking up a selection works in any script. Nothing is \
                 deleted: selecting a script again shows its words again.
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
            Button("Add an App…") { addApp() }
        } header: {
            Text("Never Look Up in These Apps")
        } footer: {
            Text("""
                 Password managers cannot be removed. The sentence a word was read in is saved \
                 with it, and in a password manager every sentence is a secret.
                 """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sites XiaolaiDict never looks up on — **enforced**. It was removed on 2026-10-02 because the
    /// hover path never named a site, so the list refused nothing under a header that promised it
    /// would. Hover now resolves the page's host after the cheap gate and before any text or pixel
    /// is read, and only while this list has something in it. What a reader added before is here.
    private var sitesSection: some View {
        Section {
            ForEach(policy.excludedHosts.sorted(), id: \.self) { site in
                HStack {
                    Text(verbatim: site)
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
                    .disabled(HoverPolicy.siteHost(fromTyped: host) == nil)
            }
        } header: {
            Text("Never Look Up on These Sites")
        } footer: {
            // **The cost is said where the promise is made.** A page whose address cannot be read
            // might be one of these sites, so it is refused — and an app that exposes no text has
            // no page to read at all, which is every terminal.
            // **Hover's, and said so**: a selection the reader looked up with the shortcut is looked
            // up wherever it is, as the scripts setting already says for scripts.
            Text("""
                 Hover does not look up words on these sites; looking up a selection works anywhere. \
                 Subdomains are covered too, so example.com also excludes docs.example.com. \
                 While this list has a site in it, hover reads an app only where it can tell whether \
                 it is a web page — so not apps that do not expose their text, such as terminals.
                 """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var host = ""

    /// A pasted address is reduced to its host — stored whole, it could never match a page.
    private func addHost() {
        guard let site = HoverPolicy.siteHost(fromTyped: host) else { return }
        policy.excludedHosts.insert(site)
        host = ""
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
        // entirely in kanji and classifies as han, so a Japanese reader who selects only
        // "Japanese kana" is refused most of their own language. "Chinese characters" alone
        // hid that, and the reader had no way to find out except by it not working.
        case .han: Text("Chinese characters / Japanese kanji")
        case .hangul: Text("Korean")
        case .kana: Text("Japanese kana")
        }
    }

    /// Whether `script` is the only one left selected, which is what makes its box read-only.
    private func isTheOnlyScriptChosen(_ script: ProbeScript) -> Bool {
        policy.scripts == [script]
    }

    /// One box per script, and **the last one cannot be cleared**.
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
                    .frame(width: Token.Text.form, height: Token.Text.form)
                    .accessibilityHidden(true)
            }
            if let name = AppNames.name(for: bundleID) {
                Text(name)
            } else {
                Text(bundleID)
                    .font(.callout.monospaced())
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
    /// The dictionary the reader clicked, held until they confirm. Doubly optional because
    /// "Automatic" is itself a choice, and its tag is nil.
    @State private var pending: PendingSwitch?

    /// One switch awaiting the reader's answer.
    private struct PendingSwitch: Equatable {
        let key: String?
    }

    var body: some View {
        Form {
            Section {
                if let choice, let available = choice.available {
                    let shown = StudyDictionaryPresentation.of(
                        available: available, chosen: choice.chosen, automatic: choice.automatic)
                    switch shown {
                    case .automatic(let capability), .chosen(let capability):
                        Text(DictionaryLabels.studying(from: capability))
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Use a different dictionary") { list(choice, available) }
                    case .listOnly:
                        list(choice, available)
                    }
                } else if let choice, !choice.hasAsked {
                    Text("Looking for your dictionaries…").foregroundStyle(.secondary)
                } else if let choice {
                    // **Asked and answered with nothing is not still asking.** The pane said
                    // "Asking…" for as long as it was open whenever discovery finished without
                    // a list — a spinner that never resolves, describing a request that had
                    // already come back. `hasAsked` is the flag the app already sets and
                    // `SetupView` already reads; this pane was simply not looking at it.
                    VStack(alignment: .leading) {
                        Text("Your dictionaries could not be read.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { choice.reask() }
                    }
                } else {
                    Unavailable()
                }
            } header: {
                Text("Study From")
            } footer: {
                // **A plain note, and the warning at the moment it applies.** This was a
                // permanent orange triangle, shown whether or not anything was being switched —
                // a caution that is always on is one nobody reads. The cost of switching is now
                // asked about when the reader switches.
                Text("""
                     Study progress is kept separately for each dictionary. Your reading history \
                     is kept whichever you choose.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Switch the study dictionary?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { switching in
            Button("Switch Dictionary") { choice?.choose(switching.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("""
                 Review starts over with the new dictionary: what you have learned is kept with \
                 the dictionary it was learned from, and is there again if you switch back. Your \
                 reading history is not affected.
                 """)
        }
    }

    /// The full list, for the reader who wants a dictionary other than the one their language names.
    @ViewBuilder private func list(_ choice: DictionaryChoice, _ available: [DictionaryCapability]) -> some View {
                    // **Radio buttons, because it is one of several and each needs its note.**
                    // `.inline` in a grouped form drew the unselected choices as filled grey
                    // discs at the trailing edge, which read as disabled. A pop-up would fit
                    // eight names and lose the line under each that says what choosing it gives.
                    Picker("Dictionary", selection: binding(choice)) {
                        Group {
                            if choice.automatic == nil {
                                Text("The dictionary for my language (none of your dictionaries suits it)")
                            } else {
                                Text("The dictionary for my language")
                            }
                        }
                        .disabled(choice.automatic == nil)
                        .tag(String?.none)
                        ForEach(available, id: \.identity.key) { capability in
                            // What choosing it can key, under its name: a dictionary that marks
                            // senses with nothing a parser can read only ever gives whole-entry
                            // cards, and the reader should see that before choosing rather than
                            // after a week of them.
                            VStack(alignment: .leading) {
                                Text(verbatim: capability.identity.name)
                                Text(DictionaryLabels.capability(capability))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(String?.some(capability.identity.key))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
    }

    /// A binding rather than a button per row, so the pane says "one of these" the way the
    /// decision does. **A change is asked about before it is made** — switching starts study
    /// over, and the control used to apply it on one click under a warning nobody was reading.
    private func binding(_ choice: DictionaryChoice) -> Binding<String?> {
        Binding(get: { choice.chosen }, set: { wanted in
            guard wanted != choice.chosen else { return }
            pending = PendingSwitch(key: wanted)
        })
    }
}

/// What a dictionary can do for study, in the reader's words.
///
/// **Here, and not on `DictionaryCapability`.** It had a `note` property, below the view layer,
/// answering "senses", "senses, by position" and "whole entries only" — unlocalized, and in the
/// parser's vocabulary. It was drawn verbatim in this pane and on the setup pane, which is the
/// same defect the hover pickers had; these were its only two readers, so it is deleted. Both
/// functions switch over the key kind, so a kind added later fails to compile here.
enum DictionaryLabels {
    /// The line under a dictionary's name in the picker.
    static func capability(_ capability: DictionaryCapability) -> String {
        guard capability.probed else {
            return String(localized: "Not checked yet",
                          comment: "Under a dictionary's name: what it can do for study is not known yet")
        }
        return switch capability.senseKeyKind {
        case .publisher:
            String(localized: "Marks the meaning you met",
                   comment: "Under a dictionary's name: it can mark which meaning a word had")
        case .position:
            String(localized: "Marks the meaning you met, by its place in the entry",
                   comment: "Under a dictionary's name: it can mark a meaning, by position rather than by the publisher's id")
        case .none:
            String(localized: "Whole entries only",
                   comment: "Under a dictionary's name: it cannot mark a single meaning")
        }
    }

    /// The setup row's sentence about the dictionary being studied from.
    static func studying(from capability: DictionaryCapability) -> String {
        let name = capability.identity.name
        guard capability.probed else {
            return String(localized: "Studying from \(name).")
        }
        return switch capability.senseKeyKind {
        case .publisher:
            String(localized: "Studying from \(name). It can mark the meaning you met.")
        case .position:
            String(localized: "Studying from \(name). It can mark the meaning you met, by its place in the entry.")
        case .none:
            String(localized: "Studying from \(name). It shows whole entries and cannot mark a single meaning.")
        }
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
    /// The author's own page. The Author row opened `site`, the same address as the Website row
    /// under it — two rows, one destination.
    private static let profile = URL(string: "https://github.com/xiaolai")
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
                    // Semantic fonts, like every other pane: this one and Setup were set from
                    // the reader's text size, so the window changed type size from tab to tab.
                    Text("XiaolaiDict")
                        .font(.title2.weight(.semibold))
                    Text("A menu-bar dictionary for macOS.")
                        .foregroundStyle(.secondary)
                    // Nothing is invented where the bundle says nothing: a pane that printed
                    // "unknown" would be claiming to have looked and found that answer.
                    if let release {
                        // Secondary: tertiary is how an unavailable control is drawn, and this
                        // is text a reader copies into a bug report.
                        Text(release.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                if let profile = Self.profile {
                    Link(destination: profile) { Text(verbatim: "@xiaolai") }
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
        Section("Local Model") {
            LabeledContent("Model") { Text(verbatim: LocalModelAttribution.family) }
            LabeledContent("Made by") { Text(verbatim: LocalModelAttribution.publisher) }
            // "License", as the licence itself is named beside it — the row read "Licence — Apache
            // License 2.0", two spellings of one word a line apart.
            LabeledContent("License") {
                if let destination = modelLicence ?? Self.licence {
                    Button { open(destination) } label: { Text(verbatim: LocalModelAttribution.licenceName) }
                        .buttonStyle(.link)
                } else {
                    Text(verbatim: LocalModelAttribution.licenceName)
                }
            }
            if licenceWouldNotOpen {
                // The name is not a place. A reader who cannot open the link is given the address.
                Text("The license could not be opened. It is published under \(LocalModelAttribution.licenceName), at \(LocalModelAttribution.licenceURL?.absoluteString ?? "apache.org").")
                    .textSelection(.enabled)
                    .font(.callout)
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
            Section("Open Source") {
                LabeledContent("Licenses") {
                    Button { open(notices, missing: $noticesWouldNotOpen) } label: { Text("Third-Party Notices") }
                        .buttonStyle(.link)
                }
                if noticesWouldNotOpen {
                    // The reader is told where it is, so the text is reachable without this button.
                    Text("The notices could not be opened. They are in the app itself, at \(notices.path()).")
                        .textSelection(.enabled)
                        .font(.callout)
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
