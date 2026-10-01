import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport

@testable import XiaolaiDictUI

/// **Settings opens where the reader left it — unless setup still needs them.**
///
/// The window opened on Setup at every launch, so a reader who changed their text size and came
/// back was shown a board saying everything was ready. The rule has two halves and each can fail
/// on its own, which is why they are tested apart.
@MainActor
struct SettingsPaneStoreTests {
    /// A fresh install has never been told setup is finished, so it opens on Setup — whatever
    /// else is or is not stored.
    @Test func aFreshInstallOpensOnSetup() {
        let defaults = TemporaryDefaults.suite()
        #expect(SettingsPaneStore(defaults: defaults).openingPane() == .setup)
        #expect(SettingsModel(defaults: defaults).pane == .setup)
    }

    /// The finding itself: the chosen pane survives a relaunch once setup is done.
    @Test func theChosenPaneIsRestoredOnceSetupIsFinished() {
        let defaults = TemporaryDefaults.suite()
        let first = SettingsModel(defaults: defaults)
        first.note(setupUnfinished: false)
        first.choose(.reading)
        #expect(SettingsModel(defaults: defaults).pane == .reading)
    }

    /// **Setup wins while something there is still needed**, even over a pane the reader chose:
    /// a reader opening Settings with a permission missing is there for the permission.
    @Test func anUnfinishedSetupOpensOnSetupWhateverWasChosen() {
        let defaults = TemporaryDefaults.suite()
        let first = SettingsModel(defaults: defaults)
        first.note(setupUnfinished: false)
        first.choose(.lookup)
        first.note(setupUnfinished: true)
        #expect(SettingsModel(defaults: defaults).pane == .setup)
        // And goes back to their pane when it is finished again — the choice was kept.
        first.note(setupUnfinished: false)
        #expect(SettingsModel(defaults: defaults).pane == .lookup)
    }

    /// **Only a choice is stored.** `--settings-report` walks every pane to measure the window,
    /// and the lookup window links straight to the Dictionary pane; neither is the reader saying
    /// where Settings should open. The report ended on Reading, so with a `didSet` writer every
    /// end-to-end run would have moved the test Mac's window to a pane nobody chose.
    @Test func selectingAPaneFromCodeIsNotRemembered() {
        let defaults = TemporaryDefaults.suite()
        let model = SettingsModel(defaults: defaults)
        model.note(setupUnfinished: false)
        model.choose(.about)
        model.pane = .dictionary
        #expect(model.pane == .dictionary, "the window did not move")
        #expect(SettingsModel(defaults: defaults).pane == .about)
    }

    /// A stored name no pane has — a pane removed by a later version — is not a pane.
    @Test func aPaneThatNoLongerExistsFallsBackToSetup() {
        let defaults = TemporaryDefaults.suite()
        defaults.set(false, forKey: SettingsPaneStore.setupUnfinishedKey)
        defaults.set("permissions", forKey: SettingsPaneStore.paneKey)
        #expect(SettingsPaneStore(defaults: defaults).openingPane() == .setup)
    }

    /// Without a suite nothing is kept and nothing is read: a preview, or a test about something
    /// else, must not reach for the reader's preferences.
    @Test func withoutASuiteItKeepsNothing() {
        let model = SettingsModel()
        model.choose(.about)
        #expect(SettingsModel().pane == .setup)
        #expect(SettingsModel().showsMenuBarIcon)
    }

    /// The window uses `choose` for its tabs. Read from the source because a `TabView`'s
    /// selection binding cannot be asked what it calls.
    @Test func theTabsGoThroughChoose() throws {
        let view = try SettingsSources.code("SettingsView.swift")
        #expect(view.contains("TabView(selection: Binding(get: { model.pane }, set: { model.choose($0) }))"))
        #expect(!view.contains("TabView(selection: $model.pane)"),
                "a tab bound straight to `pane` moves the window and remembers nothing")
    }
}

/// **The menu bar icon's setting: one key, shown unless the reader says otherwise.**
///
/// The status item lives in the app target and reads this key; the toggle lives in Settings and
/// writes it. The key and its default are the whole contract between them, so they are pinned.
@MainActor
struct MenuBarIconSettingTests {
    @Test func theKeyIsTheOneTheStatusItemReads() {
        #expect(MenuBarIconSetting.key == "ShowsMenuBarIcon")
    }

    /// `bool(forKey:)` answers false for a key never written, which would hide the icon on the
    /// first launch after an update.
    @Test func anUnwrittenKeyMeansShown() {
        let defaults = TemporaryDefaults.suite()
        #expect(defaults.object(forKey: MenuBarIconSetting.key) == nil, "the fixture is not fresh")
        #expect(MenuBarIconSetting(defaults: defaults).load())
        #expect(SettingsModel(defaults: defaults).showsMenuBarIcon)
    }

    @Test func theToggleWritesABoolUnderThatKey() {
        let defaults = TemporaryDefaults.suite()
        let model = SettingsModel(defaults: defaults)
        model.showsMenuBarIcon = false
        #expect(defaults.object(forKey: "ShowsMenuBarIcon") as? Bool == false)
        #expect(!SettingsModel(defaults: defaults).showsMenuBarIcon)
        model.showsMenuBarIcon = true
        #expect(defaults.object(forKey: "ShowsMenuBarIcon") as? Bool == true)
    }

    /// The toggle is in the window and bound to the model, and says how to get back. A setting
    /// that hides the only door has to name the other one.
    @Test func theGeneralPaneOffersItAndSaysTheWayBack() throws {
        let pane = try SettingsSources.code("GeneralSettings.swift")
        #expect(pane.contains("Toggle(\"Show in menu bar\", isOn: $model.showsMenuBarIcon)"))
        #expect(pane.contains("from Finder or Spotlight"))
        #expect(pane.contains("Toggle(\"Open at login\""))
    }
}

/// **What the recorder does with a combination**, decided without a key press.
@MainActor
struct ShortcutVerdictTests {
    private static func us(_ code: UInt32) -> String? {
        [kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_Q: "q", kVK_ANSI_K: "k"][Int(code)]
    }

    private func verdict(_ key: Int, _ modifiers: Int) -> ShortcutField.Verdict {
        ShortcutField.verdict(
            on: Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)), keyName: Self.us)
    }

    /// The defect: ⌘C and ⌘Q were taken and registered as a global hot key.
    @Test func aStandardShortcutIsRefusedWithAReason() throws {
        for key in [kVK_ANSI_C, kVK_ANSI_Q, kVK_Space] {
            guard case .coach(let line) = verdict(key, cmdKey) else {
                Issue.record("⌘ with key code \(key) was accepted")
                continue
            }
            #expect(line.contains("standard shortcut"), "the refusal does not say why: \(line)")
            #expect(line.contains("⌘"), "the refusal does not name what was pressed: \(line)")
        }
    }

    /// A bare key is still refused, and for its own reason — the two refusals must not share a
    /// sentence, because what the reader should try next is different.
    @Test func aBareKeyIsRefusedForItsOwnReason() {
        guard case .coach(let bare) = verdict(kVK_ANSI_K, 0),
              case .coach(let standard) = verdict(kVK_ANSI_C, cmdKey)
        else {
            Issue.record("one of the two refusals was accepted")
            return
        }
        #expect(bare.contains("needs"))
        #expect(bare != standard)
    }

    /// **The positive control.** A rule that refused everything would pass both tests above.
    @Test func anOrdinaryCombinationIsAccepted() {
        #expect(verdict(kVK_ANSI_D, controlKey | optionKey) == .accept)
        #expect(verdict(kVK_ANSI_K, cmdKey | optionKey) == .accept)
        #expect(verdict(kVK_ANSI_C, cmdKey | optionKey) == .accept, "⌥⌘C is not Copy")
    }

    /// A refusal keeps the field listening: only `.accept` reaches `choose` and ends the
    /// recording. Read from the source, since the alternative is a synthesised key press.
    @Test func aRefusalKeepsListening() throws {
        let field = try SettingsSources.code("ShortcutField.swift")
        let take = try #require(field.range(of: "private func take(_ shortcut: Shortcut) {"))
        let body = field[take.upperBound...].prefix(600)
        let coach = try #require(body.range(of: "case .coach"))
        let accept = try #require(body.range(of: "case .accept"))
        #expect(!body[coach.upperBound..<accept.lowerBound].contains("capture.end()"),
                "a coached refusal ends the recording, so the reader has to arm the field again")
        #expect(body[accept.upperBound...].contains("capture.end()"))
    }

    /// VoiceOver is given words. `⌃⌥D` is read as the names of three symbols.
    @Test func theShortcutIsSpokenInWords() {
        // The words and their order, not the separator: the keys are joined as the locale's own
        // list, so what stands between them is the locale's and no literal of this app's.
        func words(_ spoken: String) -> [String] {
            spoken.split { !$0.isLetter }.map(String.init).filter { $0 != "and" }
        }
        let spoken = ShortcutField.spoken(.defaultLookUp, keyName: Self.us)
        #expect(words(spoken) == ["Control", "Option", "D"])
        #expect(!spoken.contains("⌃") && !spoken.contains("⌥"))
        #expect(words(ShortcutField.spoken(
            Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)), keyName: Self.us))
            == ["Shift", "Command", "Space"])
    }

    /// The field has a name, a value and a hint, and announces the line under it.
    @Test func theRecorderIsNamedForVoiceOver() throws {
        let field = try SettingsSources.code("ShortcutField.swift")
        #expect(field.contains(".accessibilityLabel(Text(\"Lookup shortcut\"))"))
        #expect(field.contains(".accessibilityValue("))
        #expect(field.contains(".accessibilityHint(Text(\"Records a new shortcut\"))"))
        #expect(field.contains("AccessibilityNotification.Announcement(latest).post()"))
        #expect(!field.contains(".monospaced()"), "the recorder's glyphs are drawn in a monospaced face again")
    }
}

/// The hover pickers' labels exist for every case, and come from the UI module.
struct HoverLabelsTests {
    @Test func everyCaseHasALabel() {
        for modifier in HoverModifier.allCases { #expect(!HoverLabels.name(of: modifier).isEmpty) }
        for gesture in HoverGesture.allCases { #expect(!HoverLabels.name(of: gesture).isEmpty) }
        for rest in HoverPolicy.Settle.allCases { #expect(!HoverLabels.name(of: rest).isEmpty) }
        #expect(Set(HoverPolicy.Settle.allCases.map(HoverLabels.name(of:))).count == HoverPolicy.Settle.allCases.count)
    }

    /// The pickers draw these and not a string from the core.
    @Test func thePickersDrawTheLocalizedNames() throws {
        let panes = try SettingsSources.code("SettingsPanes.swift")
        #expect(panes.contains("HoverLabels.name(of: modifier)"))
        #expect(panes.contains("HoverLabels.name(of: gesture)"))
        #expect(panes.contains("HoverLabels.name(of: $0)"))
        #expect(!panes.contains("modifier.name") && !panes.contains("gesture.name"))
    }
}

/// **What the settings window is built from**, read from the source — a grouped `Form`
/// rasterises to nothing under `ImageRenderer`, so none of this can be pixel-tested.
struct SettingsChromeTests {
    /// Every file the settings window is drawn from.
    static let files = [
        "SettingsView.swift", "SettingsPanes.swift", "SetupView.swift", "ShortcutField.swift",
        "EraseReadingSection.swift", "GeneralSettings.swift",
    ]

    /// Glass is for what floats over content; these are rows of a form. Twelve buttons in Setup
    /// and one in Reading were `.glass` or `.glassProminent`.
    @Test(arguments: files)
    func noButtonInAFormIsGlass(file: String) throws {
        let code = try SettingsSources.code(file)
        #expect(!code.contains(".buttonStyle(.glass"), "\(file) puts a glass button in a form row")
        #expect(!code.contains(".glassEffect("), "\(file) puts glass inside a grouped form")
    }

    /// **One filled button on the Setup pane, at most** — the first step still needing the
    /// reader. Four could show at once on a fresh install. The style is written in one place, and
    /// every call that asks for it asks through `isNext`.
    @Test func prominenceIsDecidedInOnePlaceAndOnlyForTheNextStep() throws {
        let setup = try SettingsSources.code("SetupView.swift")
        #expect(setup.components(separatedBy: "buttonStyle(.borderedProminent)").count - 1 == 1,
                "prominence is written at more than one site, so nothing keeps it to one button")
        let asked = setup.components(separatedBy: ".stepAction(prominent:").dropFirst()
        #expect(!asked.isEmpty, "nothing on the pane is ever prominent — the scan matched nothing")
        for call in asked {
            #expect(call.hasPrefix(" isNext("), "a button is prominent without being the next step: \(call.prefix(40))")
        }
        #expect(setup.contains("board.outstanding.first == step"))
        for file in Self.files where file != "SetupView.swift" {
            #expect(!(try SettingsSources.code(file)).contains(".borderedProminent"),
                    "\(file) has a filled button; Settings has no primary action outside Setup")
        }
    }

    /// Orange as text is retired, and tertiary is for what is disabled.
    @Test(arguments: files)
    func noOrangeAndNoTertiaryText(file: String) throws {
        let code = try SettingsSources.code(file)
        #expect(!code.contains(".foregroundStyle(.orange)"), "\(file) sets something in orange")
        #expect(!code.contains(".tertiary"), "\(file) draws readable text in the disabled style")
    }

    /// Settings is chrome: its type is the system's, not the reader's reading size. The one
    /// exception is the specimen in the Reading pane, which exists to show that size.
    @Test(arguments: files)
    func theTypeIsTheSystemsNotTheReadersSize(file: String) throws {
        let code = try SettingsSources.code(file)
        #expect(!code.contains(".font(.system(size: scale.text."),
                "\(file) sets a row from the reader's text size, so this pane's type differs from its neighbours'")
    }

    /// The words the plan retires, in the strings a reader sees.
    @Test(arguments: files)
    func noInternalVocabularyReachesTheReader(file: String) throws {
        let banned = ["ticked", "The gate", "sense id", "fast hover path", "In the panel", "ledger",
                      "drawer", "This pane is not connected", "This board"]
        let literals = SettingsSources.literals(in: try SettingsSources.code(file))
        for word in banned {
            let found = literals.filter { $0.localizedCaseInsensitiveContains(word) }
            #expect(found.isEmpty, "\(file) says \"\(word)\" to the reader: \(found)")
        }
    }

    /// **The positive control for the scan above**: it reads literals at all, and would see one.
    @Test func theLiteralScanSeesAStringAndSkipsAComment() {
        let sample = """
            // The gate is explained here, in a comment.
            Text("The gate")
            """
        let code = sample.split(separator: "\n").filter { !$0.hasPrefix("//") }.joined(separator: "\n")
        #expect(SettingsSources.literals(in: code) == ["The gate"])
    }

    /// The glass picker is gone, with the choice it set.
    @Test func thereIsNoGlassSetting() throws {
        let panes = try SettingsSources.code("SettingsPanes.swift")
        #expect(!panes.contains("drawerGlass") && !panes.contains("DrawerGlass"))
        #expect(!SettingsSources.literals(in: panes).contains { $0.contains("Frosted") })
    }

    /// The site list did nothing; it is not offered.
    @Test func thereIsNoSiteExclusionControl() throws {
        let panes = try SettingsSources.code("SettingsPanes.swift")
        #expect(!panes.contains("excludedHosts"), "the Lookup pane edits a list nothing enforces")
        #expect(!SettingsSources.literals(in: panes).contains { $0.contains("these sites") })
    }

    /// **The setup pane has no mover of its own.** It kept `.fitsItsContent(width:)` from when
    /// it was a window: a second, unclamped mover on the settings window. The modifier is deleted
    /// so it cannot come back by habit.
    @Test func theSetupPaneHasNoMoverOfItsOwn() throws {
        let setup = try SettingsSources.code("SetupView.swift")
        #expect(!setup.contains("fitsItsContent"))
        #expect(!setup.contains(".frame(width: Token.Panel.settingsWidth)"))
        #expect(!(try SettingsSources.code("SettingsWindowFit.swift")).contains("func fitsItsContent(width:"))
    }

    /// One permission poll in the window, not two.
    @Test func thereIsOnePermissionPoll() throws {
        let polls = try Self.files.map { try SettingsSources.code($0) }
            .map { $0.components(separatedBy: "Token.Timing.permissionPoll").count - 1 }
            .reduce(0, +)
        #expect(polls == 1, "\(polls) loops poll the permissions; the settings model's fed nothing")
    }

    /// The model choice is a radio group, and removing a model asks.
    @Test func theModelChoiceIsARadioGroupAndRemovalAsks() throws {
        let setup = try SettingsSources.code("SetupView.swift")
        #expect(setup.contains(".pickerStyle(.radioGroup)"))
        #expect(!setup.contains("largecircle.fill.circle"), "the radio is drawn by hand again")
        #expect(setup.contains(".confirmationDialog("))
        let removals = setup.components(separatedBy: "removeModel(").count - 1
        #expect(removals == 1, "a model is removed from \(removals) places; only the confirmed one may")
        let confirmed = try #require(setup.range(of: ".confirmationDialog("))
        let remove = try #require(setup.range(of: "removeModel("))
        #expect(remove.lowerBound > confirmed.lowerBound, "the removal is not inside the confirmation")
    }

    /// Switching the study dictionary asks first, where the cost is; the permanent warning is gone.
    @Test func switchingTheStudyDictionaryAsksFirst() throws {
        let panes = try SettingsSources.code("SettingsPanes.swift")
        #expect(panes.contains("\"Switch the study dictionary?\""))
        #expect(!panes.contains("exclamationmark.triangle"), "the Dictionary pane warns permanently again")
        let chooses = panes.components(separatedBy: "choice?.choose(").count - 1
            + panes.components(separatedBy: "choice.choose(").count - 1
        #expect(chooses == 1, "the dictionary is switched from \(chooses) places; only the confirmed one may")
    }

    /// The erase preview: counts inflect, zero disables, Cancel comes first and takes Escape.
    @Test func theErasePreviewFollowsThePlatform() throws {
        let erase = try SettingsSources.code("EraseReadingSection.swift")
        let literals = SettingsSources.literals(in: erase)
        // " lookups", with its space: the count's own name, `impact.lookups`, is inside the
        // interpolation and is not a word the reader sees.
        #expect(!literals.contains { $0.contains(" lookups") }, "a count is not inflected: \(literals.filter { $0.contains(" lookups") })")
        #expect(erase.contains("^[\\(impact.lookups) Reading](inflect: true)"))
        #expect(erase.contains(".disabled(impact.lookups == 0)"))
        #expect(erase.contains("\"There is no reading history to delete.\""))
        #expect(erase.contains(".keyboardShortcut(.cancelAction)"))
        let cancel = try #require(erase.range(of: "Button(\"Cancel\", role: .cancel)"))
        let delete = try #require(erase.range(of: "role: .destructive"))
        #expect(cancel.lowerBound < delete.lowerBound, "the destructive button comes before Cancel")
        #expect(erase.contains("StatusLabel(\n                    .caution"))
    }

    /// Button titles are title case. The ones that were not.
    @Test func theButtonsAreTitleCase() throws {
        let all = try Self.files.map { try SettingsSources.code($0) }.joined(separator: "\n")
        for title in ["Check Again", "Try Again", "Not Now", "Add an App…", "Delete All Reading History…",
                      "Open System Settings…", "Request Access…", "Open VoiceOver Utility…"] {
            #expect(all.contains("\"\(title)\""), "no button is titled \(title)")
        }
        for old in ["\"Check again\"", "\"Try again\"", "\"Not now\"", "\"Add an app…\"", "\"Ask again\"",
                    "\"Open Settings…\"", "\"Ask macOS…\"", "\"Delete all reading history…\""] {
            #expect(!all.contains(old), "\(old) is still a button title")
        }
        #expect(all.contains("\"Download Larger Model (\\(Self.bytes(larger.manifest.totalBytes)))\""))
        #expect(!all.contains("Use the larger model"))
    }
}

/// Reading the settings window's sources.
enum SettingsSources {
    /// A file of `Sources/XiaolaiDictUI`, with comment lines removed — these files explain at
    /// length what they no longer do, and a scan that cannot tell a call from an explanation
    /// reports the explanation.
    static func code(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The single-line string literals in `code`, and each line of a multi-line one.
    static func literals(in code: String) -> [String] {
        var found: [String] = []
        var inBlock = false
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\"\"\"") {
                inBlock.toggle()
                continue
            }
            if inBlock {
                found.append(trimmed)
                continue
            }
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "\"") {
                let after = rest.index(after: open)
                guard let close = rest[after...].firstIndex(of: "\"") else { break }
                found.append(String(rest[after..<close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return found.filter { !$0.isEmpty }
    }
}
