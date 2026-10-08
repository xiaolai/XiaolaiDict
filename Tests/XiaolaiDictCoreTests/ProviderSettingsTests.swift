import Foundation
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// Which language-model source the reader chose (ADR-0053), and the settings beside it that are not secrets.
struct ProviderChoiceStoreTests {
    /// **Unset is `none`**, and so is anything this build cannot read: a half-written or foreign value must never
    /// turn a source on — a source the reader did not choose is a source that sends their sentence somewhere.
    @Test(arguments: [nil, "gibberish", "", "ClaudeCLI", "openai"] as [String?])
    func anythingUnreadableIsNone(stored: String?) {
        let defaults = TemporaryDefaults.suite()
        if let stored { defaults.set(stored, forKey: ProviderChoiceStore.defaultsKey) }
        #expect(ProviderChoiceStore(defaults: defaults).load() == .none)
    }

    /// A value of the wrong type — `defaults write … -int 2`, say — is unreadable too, never a crash.
    @Test func aValueOfTheWrongTypeIsNone() {
        let defaults = TemporaryDefaults.suite()
        defaults.set(2, forKey: ProviderChoiceStore.defaultsKey)
        #expect(ProviderChoiceStore(defaults: defaults).load() == .none)
        // The control: the same suite reads a real choice once one is written.
        defaults.set(ProviderChoice.codexCLI.rawValue, forKey: ProviderChoiceStore.defaultsKey)
        #expect(ProviderChoiceStore(defaults: defaults).load() == .codexCLI)
    }

    @Test(arguments: ProviderChoice.allCases)
    func whatIsSavedIsWhatComesBack(choice: ProviderChoice) {
        let defaults = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: defaults).save(choice)
        #expect(ProviderChoiceStore(defaults: defaults).load() == choice, "a choice did not survive a new store")
    }

    /// **The raw values are the stored spelling**, so renaming a case would strand every reader's choice. Pinned.
    @Test func theStoredSpellingsArePinned() throws {
        #expect(ProviderChoice.allCases.map(\.rawValue)
                == ["none", "claudeCLI", "codexCLI", "openAICompatible", "localModel"])
        #expect(ProviderChoiceStore.defaultsKey == "LanguageModelProvider")
        let encoded = try JSONEncoder().encode([ProviderChoice.openAICompatible])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["openAICompatible"]"#)
        #expect(try JSONDecoder().decode([ProviderChoice].self, from: encoded) == [.openAICompatible])
    }
}

struct ProviderSettingsStoreTests {
    /// **Nothing written is the defaults**: OpenAI's own endpoint, no model named, no path overrides, `haiku` for
    /// Claude and the server's own default for Codex (the empty string, which says "ask the server").
    @Test func nothingWrittenIsTheDefaults() {
        let settings = ProviderSettingsStore(defaults: TemporaryDefaults.suite()).load()
        #expect(settings == ProviderSettings())
        #expect(settings.endpointURL == "https://api.openai.com/v1")
        #expect(settings.endpointModel.isEmpty)
        #expect(settings.claudeCLIPath == nil)
        #expect(settings.codexCLIPath == nil)
        #expect(settings.claudeCLIModel == "haiku")
        #expect(settings.codexCLIModel.isEmpty)
        #expect(!settings.subscriptionCLIsEnabled, "the CLI sources are on before the reader turned them on")
    }

    /// The keys are the stored spelling, and the end-to-end stages will write them by name. Pinned.
    @Test func theKeysArePinned() {
        #expect(ProviderSettingsStore.Key.endpointURL == "ProviderEndpointURL")
        #expect(ProviderSettingsStore.Key.endpointModel == "ProviderEndpointModel")
        #expect(ProviderSettingsStore.Key.claudeCLIPath == "ClaudeCLIPath")
        #expect(ProviderSettingsStore.Key.codexCLIPath == "CodexCLIPath")
        #expect(ProviderSettingsStore.Key.claudeCLIModel == "ClaudeCLIModel")
        #expect(ProviderSettingsStore.Key.codexCLIModel == "CodexCLIModel")
        #expect(ProviderSettingsStore.Key.subscriptionCLIsEnabled == "SubscriptionCLIsEnabled")
    }

    @Test func whatIsSavedIsWhatComesBack() {
        let defaults = TemporaryDefaults.suite()
        let chosen = ProviderSettings(
            endpointURL: "http://127.0.0.1:11434/v1", endpointModel: "qwen3:4b",
            claudeCLIPath: "/opt/homebrew/bin/claude", codexCLIPath: "/opt/tools/bin/codex",
            claudeCLIModel: "sonnet", codexCLIModel: "gpt-6.1-sol", subscriptionCLIsEnabled: true)
        ProviderSettingsStore(defaults: defaults).save(chosen)
        #expect(ProviderSettingsStore(defaults: defaults).load() == chosen, "settings did not survive a new store")
    }

    /// **A value equal to its default is not written**, so a later build that changes a default reaches a reader
    /// who never chose one — and taking an override back (nil, or empty) removes it rather than storing nothing.
    @Test func aDefaultIsNotWrittenAndAnOverrideTakenBackIsRemoved() {
        let defaults = TemporaryDefaults.suite()
        let store = ProviderSettingsStore(defaults: defaults)
        store.save(ProviderSettings(claudeCLIPath: "/usr/local/bin/claude", claudeCLIModel: "sonnet",
                                    subscriptionCLIsEnabled: true))
        #expect(defaults.object(forKey: ProviderSettingsStore.Key.claudeCLIPath) as? String == "/usr/local/bin/claude")
        #expect(defaults.object(forKey: ProviderSettingsStore.Key.claudeCLIModel) as? String == "sonnet")
        #expect(defaults.object(forKey: ProviderSettingsStore.Key.subscriptionCLIsEnabled) as? Bool == true)
        store.save(ProviderSettings())
        for key in [ProviderSettingsStore.Key.endpointURL, ProviderSettingsStore.Key.endpointModel,
                    ProviderSettingsStore.Key.claudeCLIPath, ProviderSettingsStore.Key.codexCLIPath,
                    ProviderSettingsStore.Key.claudeCLIModel, ProviderSettingsStore.Key.codexCLIModel,
                    ProviderSettingsStore.Key.subscriptionCLIsEnabled] {
            #expect(defaults.object(forKey: key) == nil, "\(key) was written though it holds its default")
        }
        #expect(store.load() == ProviderSettings())
    }

    /// **Unreadable is the default, field by field**: a value of the wrong type, an empty or blank string, and a
    /// path override that is not absolute — a relative path would be resolved against whatever directory the app
    /// happened to start in, which is not a path the reader chose.
    @Test func anythingUnreadableIsItsDefault() {
        let defaults = TemporaryDefaults.suite()
        defaults.set(42, forKey: ProviderSettingsStore.Key.endpointURL)
        defaults.set(["a"], forKey: ProviderSettingsStore.Key.endpointModel)
        defaults.set("bin/claude", forKey: ProviderSettingsStore.Key.claudeCLIPath)
        defaults.set("~/.local/bin/codex", forKey: ProviderSettingsStore.Key.codexCLIPath)
        defaults.set("   ", forKey: ProviderSettingsStore.Key.claudeCLIModel)
        defaults.set(true, forKey: ProviderSettingsStore.Key.codexCLIModel)
        #expect(ProviderSettingsStore(defaults: defaults).load() == ProviderSettings())

        // The control: the same suite reads each field once it holds something readable.
        defaults.set(" https://api.deepseek.com/v1 ", forKey: ProviderSettingsStore.Key.endpointURL)
        defaults.set("/usr/local/bin/claude", forKey: ProviderSettingsStore.Key.claudeCLIPath)
        let read = ProviderSettingsStore(defaults: defaults).load()
        #expect(read.endpointURL == "https://api.deepseek.com/v1", "surrounding blanks are not part of a URL")
        #expect(read.claudeCLIPath == "/usr/local/bin/claude")
    }

    /// **The CLI switch is on only where a yes was written as one** — it is the reader's consent to this app starting
    /// their CLI, so a string, a number other than a boolean's, or anything else is off. The control: a real yes.
    @Test func theCLISwitchIsOffUnlessAYesWasWritten() {
        let stored: [Any] = ["YES", "true", 2, ["on"]]
        for value in stored {
            let defaults = TemporaryDefaults.suite()
            defaults.set(value, forKey: ProviderSettingsStore.Key.subscriptionCLIsEnabled)
            #expect(!ProviderSettingsStore(defaults: defaults).load().subscriptionCLIsEnabled, "\(value) turned it on")
            defaults.set(true, forKey: ProviderSettingsStore.Key.subscriptionCLIsEnabled)
            #expect(ProviderSettingsStore(defaults: defaults).load().subscriptionCLIsEnabled)
        }
    }

    /// An empty endpoint is no endpoint, so it reads as the default rather than as a URL nothing can parse.
    @Test func anEmptyEndpointIsTheDefault() {
        let defaults = TemporaryDefaults.suite()
        defaults.set("", forKey: ProviderSettingsStore.Key.endpointURL)
        #expect(ProviderSettingsStore(defaults: defaults).load().endpointURL == ProviderSettings.defaultEndpointURL)
    }
}

/// **The bundled model's setup is hidden unless the reader asked for it** (ADR-0053): `ShowLocalModelSetup`, in the
/// spellings `defaults write` writes a yes in.
struct LocalModelSetupFlagTests {
    @Test func unsetIsHidden() {
        #expect(!LocalModelSetupFlag(defaults: TemporaryDefaults.suite()).isSet())
        #expect(LocalModelSetupFlag.defaultsKey == "ShowLocalModelSetup")
    }

    /// `-bool YES`, `-bool true`, `-int 1` and `-string YES` all say yes; a no says no.
    @Test func aYesInAnySpellingShowsIt() {
        let spellings: [(stored: Any, shown: Bool)] = [
            (true, true), (1, true), ("YES", true), ("1", true), (false, false), ("NO", false), (0, false),
        ]
        for (stored, shown) in spellings {
            let defaults = TemporaryDefaults.suite()
            defaults.set(stored, forKey: LocalModelSetupFlag.defaultsKey)
            #expect(LocalModelSetupFlag(defaults: defaults).isSet() == shown, "\(stored)")
        }
    }
}
