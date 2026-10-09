import LLMProviders
import ModelKit
import SwiftUI

/// **Settings › Language Model** (ADR-0053, plan §6): which service the translation and explanation panes ask — none, the
/// reader's own `claude` or `codex`, an OpenAI-compatible endpoint, or the bundled model where its setup is shown — and,
/// for that source, what it needs and what is sent to it.
///
/// Every decision here is `LanguageModelPaneModel`'s, where a test can ask it: a grouped `Form` renders as nothing under
/// `ImageRenderer`, so this file only words what the model decides. A control that cannot act is disabled, and the
/// reason is beside it rather than discovered by clicking.
struct LanguageModelPane: View {
    var model: LanguageModelPaneModel?
    /// Whether the bundled model is offered — `LocalModelChoice.isShown`.
    var showsLocalModel: Bool

    var body: some View {
        if let model {
            Bound(model: model, showsLocalModel: showsLocalModel)
        } else {
            Form { Section { Unavailable() } }.formStyle(.grouped)
        }
    }

    /// The fields a text box can hold the caret in. A field the reader leaves is kept, as Return keeps it.
    private enum Field: Hashable {
        case endpointURL, endpointModel, cliModel, cliPath
    }

    private struct Bound: View {
        @Environment(\.scale) private var scale
        @Bindable var model: LanguageModelPaneModel
        let showsLocalModel: Bool
        /// The key as it is typed. **Held by this view and nowhere else**, and emptied once it is filed: the model never
        /// holds a key, and a key typed is not a key kept until the reader saves it.
        @State private var keyDraft = ""
        @FocusState private var focused: Field?

        /// **The form is this view's own**, so what follows is attached once: on a `Group` each modifier is applied to
        /// every section in it, and the pane would reload, and keep what is typed, once per section.
        var body: some View {
            Form {
                sourceSection
                switch model.choice {
                case .claudeCLI where model.effectiveChoice == .claudeCLI: cliSection(.claudeCLI)
                case .codexCLI where model.effectiveChoice == .codexCLI: cliSection(.codexCLI)
                case .openAICompatible: endpointSection
                case .none, .localModel, .claudeCLI, .codexCLI: EmptyView()
                }
                disclosureSection
            }
            .formStyle(.grouped)
            // Read when the pane appears: the reader may have changed a setting elsewhere, and whether a key is filed
            // is asked of the Keychain here and nowhere earlier.
            .task { model.reload() }
            .onChange(of: focused) { left, _ in
                if left != nil { model.commitDrafts() }
            }
            .onDisappear { model.commitDrafts() }
        }

        // MARK: - The source

        private var sourceSection: some View {
            Section {
                Toggle("Use my Claude and Codex subscriptions", isOn: Binding(
                    get: { model.settings.subscriptionCLIsEnabled }, set: { model.setSubscriptionCLIs($0) }))
                    .accessibilityIdentifier("language-model-subscriptions")
                Picker("Source", selection: Binding(get: { model.choice }, set: { model.choose($0) })) {
                    ForEach(model.offered(showingLocalModel: showsLocalModel), id: \.self) { choice in
                        Self.label(of: choice)
                            .tag(choice)
                            .disabled(model.refusal(of: choice) != nil)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("language-model-source")
                // **Why two choices are greyed, said where they are greyed.**
                if model.refusal(of: .claudeCLI) == .subscriptionCLIsOff {
                    Text("Claude and Codex can be chosen once the switch above is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Source")
            } footer: {
                Text("""
                     The switch lets this app start the claude or codex program you installed and signed in to. Each \
                     question uses your subscription, whose limits are shared with everything else you use it for. \
                     Nothing here signs you in, and nothing those programs keep for their sign-in is read.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        /// A choice as the list names it.
        @ViewBuilder static func label(of choice: ProviderChoice) -> some View {
            switch choice {
            case .none: Text("None — the dictionary and Apple's own engines")
            case .claudeCLI: Text("Claude, through your claude program")
            case .codexCLI: Text("Codex, through your codex program")
            case .openAICompatible: Text("A service with an OpenAI-compatible address")
            case .localModel: Text("The model downloaded to this Mac")
            }
        }

        // MARK: - A CLI

        @ViewBuilder private func cliSection(_ tool: ProviderChoice) -> some View {
            Section {
                status(checkTitle: "Check Again")
                TextField("Model", text: tool == .claudeCLI ? $model.drafts.claudeCLIModel : $model.drafts.codexCLIModel,
                          prompt: tool == .claudeCLI
                              ? Text(verbatim: ProviderSettings.defaultClaudeCLIModel) : Text("Codex's own default"))
                    .focused($focused, equals: .cliModel)
                    .onSubmit { model.commitDrafts() }
                    .accessibilityIdentifier("language-model-cli-model")
                let path = tool == .claudeCLI ? $model.drafts.claudeCLIPath : $model.drafts.codexCLIPath
                TextField("Location", text: path, prompt: Text("Found where it was installed"))
                    .focused($focused, equals: .cliPath)
                    .onSubmit { model.commitDrafts() }
                    .accessibilityIdentifier("language-model-cli-path")
                if model.pathRefusal(path.wrappedValue) == .notAbsolute {
                    Text("Not used: a location is a full path, starting with /.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                tool == .claudeCLI ? Text(verbatim: "Claude") : Text(verbatim: "Codex")
            } footer: {
                Text("""
                     It runs in the background while this app is open, so a question is answered without starting \
                     it again. Leave the location empty unless it was installed somewhere unusual.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        // MARK: - An endpoint

        private var endpointSection: some View {
            Section {
                TextField("Address", text: $model.drafts.endpointURL,
                          prompt: Text(verbatim: ProviderSettings.defaultEndpointURL))
                    .focused($focused, equals: .endpointURL)
                    .onSubmit { model.commitDrafts() }
                    .accessibilityIdentifier("language-model-endpoint-url")
                if let refusal = model.addressRefusal {
                    Self.addressRefusal(refusal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Model", text: $model.drafts.endpointModel, prompt: Text("Required — the service's name for it"))
                    .focused($focused, equals: .endpointModel)
                    .onSubmit { model.commitDrafts() }
                    .accessibilityIdentifier("language-model-endpoint-model")
                SecureField("API Key", text: $keyDraft, prompt: Text("Not needed for a server on this Mac"))
                    .onSubmit(saveKey)
                    .accessibilityIdentifier("language-model-key")
                HStack(spacing: scale.space.stack) {
                    Button("Save Key", action: saveKey)
                        .disabled(model.keyRefusal(keyDraft) != nil)
                        .accessibilityIdentifier("language-model-save-key")
                    if case .saved = model.key {
                        Button("Remove Key") { model.removeKey() }
                            .accessibilityIdentifier("language-model-remove-key")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                keyLine
                status(checkTitle: "Check Connection")
            } header: {
                Text("Service")
            } footer: {
                Text("""
                     The key is kept in your keychain for this address alone. Change the address to another server \
                     and no key is sent there until you save one for it.
                     """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func saveKey() {
            if model.saveKey(keyDraft) { keyDraft = "" }
        }

        /// Why the address in the field is not kept, in the reader's terms.
        @ViewBuilder static func addressRefusal(_ refusal: EndpointAddress.Refusal) -> some View {
            switch refusal {
            case .notAnAddress:
                Text("Not used: an address starts with https:// and names a server — or http:// for a server on this Mac.")
            case .carriesCredentials:
                Text("Not used: an address cannot hold a name or a password. Save the key below instead.")
            case .unencrypted:
                Text("""
                     Not used: a server that is not on this Mac needs an address starting with https://, so the key and \
                     your sentence are encrypted on their way to it.
                     """)
            }
        }

        /// Whether a key is filed, and why one cannot be saved — the second only once something is typed, or where the
        /// address is the reason.
        @ViewBuilder private var keyLine: some View {
            VStack(alignment: .leading, spacing: scale.space.line) {
                switch model.key {
                case .unknown: EmptyView()
                case .noAddress: Text("A key can be saved once the address above is usable.")
                case .absent(let host): Text("No key is saved for \(host).")
                case .saved(let host): Text("A key is saved for \(host).")
                case .unreadable: Text("Whether a key is saved could not be read from your keychain.")
                }
                if !keyDraft.isEmpty, model.keyRefusal(keyDraft) == .notAHeaderValue {
                    Text("A key is one run of letters, digits and punctuation, with no spaces.")
                }
                if model.keyFailure != nil {
                    Text("The key could not be kept in your keychain.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // One element, so the harness and VoiceOver each find the line once.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("language-model-key-state")
        }

        // MARK: - What the source said

        /// The check's button and what the source last said, in the reader's terms.
        @ViewBuilder private func status(checkTitle: LocalizedStringKey) -> some View {
            HStack(spacing: scale.space.stack) {
                Button(checkTitle) { Task { await model.check() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.checkRefusal != nil)
                    .accessibilityIdentifier("language-model-check")
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
            }
            VStack(alignment: .leading) {
                if let readiness = model.shownReadiness {
                    advice(ProviderAdvice.of(readiness, from: model.source))
                } else if model.isChecking {
                    Text("Checking…")
                } else {
                    Text("Not checked yet.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // One element, so the harness and VoiceOver each find the line once.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("language-model-readiness")
        }

        @ViewBuilder private func advice(_ advice: ProviderAdvice) -> some View {
            switch advice {
            case .ready(let version?, let answeredIn):
                Text("Ready — version \(version), answered in \(Self.seconds(answeredIn)).")
            case .ready(nil, let answeredIn):
                Text("Ready — answered in \(Self.seconds(answeredIn)).")
            case .install:
                Text("Not installed. Install it, sign in to it in Terminal, then choose Check Again.")
            case .fixLocation:
                Text("The location above is not a program. Correct it, or empty it to have the program found.")
            case .signIn(let command):
                Text("Not signed in. In Terminal, run \(command) and sign in, then choose Check Again.")
            case .update(let version?):
                Text("Version \(version) is too old for this app. Update it, then choose Check Again.")
            case .update(nil):
                Text("It is too old for this app. Update it, then choose Check Again.")
            case .completeEndpoint:
                Text("Enter an address this app can use and the name of a model.")
            case .checkKey:
                Text("The service refused the key, or wants one. Save the key it gave you for this address.")
            case .checkModel:
                Text("The service does not know the model named. Check its name.")
            case .checkAddress:
                Text("Nothing answered at this address. Check it, and that the server is running.")
            case .tryLater:
                Text("It did not answer this time — it may be busy or limited. Try again later.")
            case .unexpectedAnswer:
                Text("It answered with something that is not an answer. It may not be a service of this kind.")
            }
        }

        /// A duration as the reader reads one: "0.9 sec".
        private static func seconds(_ duration: Duration) -> String {
            duration.formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
        }

        // MARK: - What leaves this Mac

        private var disclosureSection: some View {
            Section {
                disclosure(LanguageModelDisclosure.of(model.source))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("language-model-disclosure")
            } header: {
                Text("What Leaves This Mac")
            }
        }

        @ViewBuilder private func disclosure(_ said: LanguageModelDisclosure) -> some View {
            switch said {
            case .nothingLeaves:
                Text("Nothing is sent off this Mac.")
            case .staysOnThisMac(let host):
                Text("""
                     Your sentence and the dictionary's meanings go to the server at \(host), which is on this Mac. \
                     Nothing is sent off it.
                     """)
            case .sentenceOnly(let destination):
                Text("""
                     When you ask for a translation or an explanation, the sentence and the word you looked up are sent \
                     to \(Self.name(of: destination)). The dictionary's own text is never sent, so it does not choose \
                     which meaning you met.
                     """)
            case .sentenceAndDictionaryText(let destination):
                Text("""
                     When you ask for a translation or an explanation, the sentence, the word you looked up and the \
                     dictionary's meanings for it are sent to \(Self.name(of: destination)).
                     """)
            }
        }

        /// Where a remote source's questions go, as a reader would name it.
        private static func name(of destination: LanguageModelDisclosure.Destination) -> String {
            switch destination {
            case .claude: String(localized: "Anthropic, through your claude program",
                                 comment: "Where a question goes: the reader's own Claude Code CLI, which sends it to Anthropic")
            case .codex: String(localized: "OpenAI, through your codex program",
                                comment: "Where a question goes: the reader's own Codex CLI, which sends it to OpenAI")
            case .endpoint(let host?): host
            case .endpoint(nil): String(localized: "the address above",
                                        comment: "Where a question goes: an endpoint whose address names no server")
            }
        }
    }
}
