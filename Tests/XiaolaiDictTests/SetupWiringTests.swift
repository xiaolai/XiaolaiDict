import Foundation
import Testing

@testable import XiaolaiDictUI

/// **The board is handed everything it needs, by the app that owns it.**
///
/// `SetupView` takes seven parameters. `localModel` has no default any more — a board that does not
/// know what this Mac can do about the model is a state, not something to fall into by forgetting —
/// but the rest still default to nil, so a board built without them compiles, renders, and shows a
/// permanent "Asking which dictionaries are enabled…" with no dictionary to choose, no shortcut to
/// name and no way out to Settings. Every unit test over `SetupBoard` would still pass: they
/// construct the board directly.
///
/// That is the `HoverPause` defect's exact shape — a model that was complete, covered, and
/// connected to nothing, because a defaulted closure parameter nobody supplies is invisible to
/// every test that exercises the value itself. So this reads the call site instead.
///
/// It is a source scan rather than a rendered view because SwiftUI offers no way to ask a view
/// which arguments it was built with, and a test that rendered one would be asserting on the
/// pixels rather than on the wire.
struct SetupWiringTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        // Thrown by `String(contentsOf:)` rather than defaulted to "": a scanner that silently
        // reads nothing passes forever and guards nothing.
        #expect(!text.isEmpty, "\(relativePath) is empty")
        return text
    }

    /// The source with every line that is only a comment removed.
    ///
    /// The scanners below count brackets, and these files explain themselves at length —
    /// `XiaolaiDictScene.swift` spends a paragraph on why a `UtilityWindow` is *not* used. A
    /// comment line holding an unmatched bracket would end a call halfway through and red-light a
    /// call site that is correct; a scanner that cannot tell a declaration from an explanation
    /// reports the explanation as the offence.
    private func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func code(_ relativePath: String) throws -> String {
        withoutComments(try source(relativePath))
    }

    // MARK: - Reading a call site

    /// The text inside a bracket pair, found by **counting brackets** — nil when they never
    /// balance, which every caller turns into a failure that names what it could not read.
    ///
    /// What this replaced searched for a newline-and-eight-spaces-and-`)`, or else for a `)` at the
    /// end of a line. That was right only by accident of how these three call sites happen to be
    /// formatted: any nested `)` ending a line truncates the extraction, and a call read halfway
    /// through fails a call site that is correct. Returning nil rather than half a call is the
    /// point — a scanner that quietly returns half a call guards half a call.
    private func balanced(_ code: String, from opening: String.Index) -> String? {
        var depth = 1
        var index = opening
        while index < code.endIndex {
            switch code[index] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return String(code[opening..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// Everything between a call's own parentheses.
    private func callBody(_ code: String, of view: String) throws -> String {
        let start = try #require(code.range(of: "\(view)("), "nothing constructs \(view)")
        return try #require(
            balanced(code, from: start.upperBound),
            "the \(view) call's brackets never balance, so nothing could be read from it")
    }

    /// A call's arguments, split at the commas that are the call's own — never at one inside a
    /// closure, a nested call or a collection.
    private func arguments(_ code: String, of view: String) throws -> [String] {
        var found: [String] = []
        var current = ""
        var depth = 0
        for character in try callBody(code, of: view) {
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "," where depth == 0:
                found.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        found.append(current)
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// What one label is bound to, and nil where the call carries no argument under it.
    ///
    /// Read from **after that label's own colon**, so a value that merely appears somewhere in the
    /// call is not mistaken for one the label carries.
    private func value(of label: String, in call: [String]) -> String? {
        guard let argument = call.first(where: { $0.hasPrefix(label) }) else { return nil }
        return argument.drop { $0 != ":" }.dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **Each label carries its own value, and the pair is checked against one argument.**
    ///
    /// Matched independently over the whole call — which is what this did — `model:` and
    /// `app.setup` both pass while `model:` is bound to something else entirely and `app.setup`
    /// sits under another label. That is a board handed the wrong state by a test reporting that it
    /// was handed the right one.
    private func expectArguments(
        _ pairs: [(String, String)], of view: String, in code: String, _ why: String
    ) throws {
        let call = try arguments(code, of: view)
        for (label, expected) in pairs {
            guard let bound = value(of: label, in: call) else {
                Issue.record(Comment(rawValue: "\(view) is built without \(label); \(why)"))
                continue
            }
            #expect(
                bound.contains(expected),
                Comment(rawValue: "\(view)'s \(label) is bound to “\(bound)” rather than to"
                    + " \(expected); \(why)"))
        }
    }

    /// The modifiers chained onto **one** view, and nothing else in the file.
    ///
    /// `environment(\.translation, translation())` used to be searched for across the whole of
    /// `LookupPanel.swift`, so the same text attached to some other view passed the check for a
    /// panel whose card would read the environment's inert default and answer nothing. A chained
    /// modifier is a line indented further than the construction it hangs off, so the chain is the
    /// run of such lines under it; comment lines are already gone, and a blank one is not a
    /// modifier.
    private func modifiers(_ code: String, on view: String) throws -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let at = try #require(lines.firstIndex { $0.contains(view) }, "nothing constructs \(view)")
        let indent = { (line: Substring) in line.prefix { $0 == " " }.count }
        var chain: [Substring] = []
        for line in lines[(at + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard indent(line) > indent(lines[at]) else { break }
            chain.append(line)
        }
        return chain.joined(separator: "\n")
    }

    private func viewLayerFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root.appending(path: "Sources/XiaolaiDictUI"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - The scanner, which has to be able to fail

    /// **A value belongs to the label it sits under.** Fed to the real helpers, not a copy of them.
    ///
    /// Matched over the whole call — which is what this file used to do — a call with its two
    /// values swapped passes, because every label and every value is still somewhere in it. That
    /// is a board handed the wrong state under a green test.
    @Test func thescannerReadsEachLabelWithItsOwnValue() throws {
        let swapped = "Probe(\n    first: b(),\n    second: a())\n"
        #expect(swapped.contains("first:") && swapped.contains("a()"),
                "the whole-call match this replaced accepts the swap")
        let call = try arguments(swapped, of: "Probe")
        #expect(call == ["first: b()", "second: a()"])
        #expect(value(of: "first:", in: call) == "b()", "the value was read from another argument")
        #expect(value(of: "third:", in: call) == nil, "a label the call does not carry was found")
    }

    /// A comment inside a call is an explanation, not an argument. Scanned as code, a commented-out
    /// argument passes for the argument it used to be.
    @Test func acommentedOutArgumentIsNotAnArgument() throws {
        let code = withoutComments("Probe(\n    first: a(),\n    // second: b(),\n    third: c())\n")
        #expect(try arguments(code, of: "Probe") == ["first: a()", "third: c()"])
    }

    /// **The shape the old scan truncated at.** It ended a call at the first `)` that ended a line,
    /// so an ordinary nested call cut the extraction short — and a call site that was correct then
    /// failed for a formatting accident.
    @Test func anestedCloseBracketAtTheEndOfALineDoesNotEndTheCall() throws {
        let nested = "Probe(\n    first: run(\n        x)\n    , second: b())\n"
        #expect(nested.contains(")\n"), "the fixture does not have the shape this is about")
        let call = try arguments(nested, of: "Probe")
        #expect(call.count == 2, "the call was cut short at a nested bracket: \(call)")
        #expect(value(of: "second:", in: call) == "b()")
    }

    /// And brackets that never balance give nothing rather than half a call — the callers turn
    /// that into a failure naming what could not be read.
    @Test func anunbalancedCallIsRefusedRatherThanReadHalfway() throws {
        let open = "Probe(first: a("
        let at = try #require(open.range(of: "Probe("))
        #expect(balanced(open, from: at.upperBound) == nil, "half a call was read as a whole one")
    }

    // MARK: - The wires

    @Test func theAppHandsTheBoardEveryPartOfItsState() throws {
        try expectArguments(
            [
                ("model:", "app.setup"), ("dictionary:", "DictionaryChoice("),
                ("shortcut:", "app.shortcutChoice"), ("shortcutIsRegistered:", "app.shortcutIsRegistered"),
                ("localModel:", "app.models.choice"), ("openSettings:", "app.showSettings("),
                ("refreshDictionaries:", "app.refreshDictionaries("),
            ],
            of: "SetupView", in: try code("Sources/XiaolaiDict/XiaolaiDictScene.swift"),
            "the board would silently lose what it carries")
    }

    /// **The panel is handed both model panes.** The card's content reads the translator and the
    /// explainer from the environment, and both have inert defaults that say "could not" — so a
    /// panel built without them renders buttons that never answer, and every unit test over the
    /// card still passes. The explainer was one: it reached past the environment for Apple's model
    /// directly, which made the pane work only for readers who have Apple Intelligence.
    @Test func theAppHandsThePanelItsTranslatorAndItsExplainer() throws {
        let scene = try code("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        try expectArguments(
            [
                ("controller:", "panelController"), ("model:", "panelModel"),
                ("translation:", "models.translationActions"), ("explainer:", "models.explanationActions"),
            ],
            of: "LookupPanelSceneView", in: scene, "the pane it feeds would answer nothing")

        // And the panel puts both into the environment the card reads — **on the view that shows
        // the card**, not merely somewhere in the file.
        let chain = try modifiers(
            try code("Sources/XiaolaiDict/LookupPanel.swift"), on: "PanelView(content: content)")
        #expect(chain.contains("environment(\\.translation, translation())"),
                "the translator is not put into the environment on the view that draws the card")
        #expect(chain.contains("environment(\\.explainer, explainer())"),
                "the explainer is not put into the environment on the view that draws the card")
    }

    /// **And the card's content reads them from there.** The only check on this was a negative one
    /// — that one file did not build Apple's explainer for itself — which passes just as well for a
    /// view that reads neither, and for a view that no longer takes them at all. Both properties
    /// are asserted on `LookupPanelContent`'s own declaration, so deleting either fails here.
    @Test func thepanelsContentReadsBothModelPanesFromTheEnvironment() throws {
        let card = try code("Sources/XiaolaiDictUI/LookupCardView.swift")
        let start = try #require(card.range(of: "struct LookupPanelContent"), "there is no LookupPanelContent")
        let opening = try #require(card[start.upperBound...].firstIndex(of: "{"), "LookupPanelContent has no body")
        let declaration = try #require(
            balanced(card, from: card.index(after: opening)),
            "LookupPanelContent's braces never balance, so nothing could be read from it")
        #expect(declaration.contains("@Environment(\\.translation)"),
                "LookupPanelContent does not read the translator from the environment")
        #expect(declaration.contains("@Environment(\\.explainer)"),
                "LookupPanelContent does not read the explainer from the environment")
    }

    /// **Nothing in the view layer builds Apple's explainer for itself.**
    ///
    /// The ban ran over `LookupCardView.swift` alone while the offence sat in
    /// `LookupPanelViews.swift`: the superseded panel's `EntryChrome` constructed
    /// `OnDeviceSentenceExplainer()` at the click, so its pane answered nothing for a reader
    /// without Apple Intelligence — most of mainland China, the audience the LLM-pane decision
    /// names first. That panel has been deleted; the scan is what stops the next one arriving the
    /// same way, and it now reads every file in the layer.
    @Test func noViewInTheLayerBuildsApplesExplainerForItself() throws {
        let files = try viewLayerFiles()
        // A scan of nothing passes. Naming the count is what makes the pass mean something.
        #expect(files.count >= 6, "only \(files.count) view files were found to scan")
        var offenders: [String] = []
        for file in files {
            let text = withoutComments(try String(contentsOf: file, encoding: .utf8))
            if text.contains("OnDeviceSentenceExplainer(") { offenders.append(file.lastPathComponent) }
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "these reach past the environment for Apple's model, which readers"
                + " without Apple Intelligence do not have: \(offenders)"))
    }

    /// The other way in. §4 of the plan asks for both, and a menu item alone leaves a reader who is
    /// already in Settings with no way to the board.
    @Test func settingsCanOpenTheBoard() throws {
        try expectArguments(
            [("openSetup:", "app.showSetup(")],
            of: "SettingsView", in: try code("Sources/XiaolaiDict/XiaolaiDictScene.swift"),
            "the settings window cannot open the setup board")
    }

    /// About names the model's licence from the file that came with the weights. **The value, not
    /// the label**: `modelLicence: nil` passes a label check and leaves About linking only to the
    /// published copy, so a reader who downloaded the weights never sees the terms they came with.
    @Test func aboutIsHandedTheModelsLicence() throws {
        try expectArguments(
            [("modelLicence:", "app.models.licenceURL")],
            of: "SettingsView", in: try code("Sources/XiaolaiDict/XiaolaiDictScene.swift"),
            "About is not handed the licence that came with the weights")

        // **And `SettingsView` hands it on.** The scene's argument was the whole of the check, so
        // dropping the pass-through one level in left About with no licence and the suite green.
        // The `modelLicence:` argument specifically rather than the whole call: the pane takes
        // other arguments, and a verbatim match would fail the next one that is added.
        let settings = try code("Sources/XiaolaiDictUI/SettingsView.swift")
        let about = try #require(settings.range(of: "case .about:"),
                                 "the About pane is not reached from the settings switch")
        try expectArguments(
            [("modelLicence:", "modelLicence")],
            of: "AboutPane", in: String(settings[about.lowerBound...]),
            "the pane it opens is handed no licence, whatever the scene passed in")
    }

    /// And the menu, which is where a reader who is not in Settings looks.
    @Test func theMenuCanOpenTheBoard() throws {
        let menu = try source("Sources/XiaolaiDict/XiaolaiDictMenu.swift")
        #expect(menu.contains("showSetup()"), "no menu item opens the setup board")
    }

    /// The board's scene exists and is a `Window`. A `UtilityWindow` is created, reports
    /// `isVisible`, and is never composited — measured in this bundle.
    ///
    /// Comment lines are dropped first, for the same reason the Screen Recording scan drops them:
    /// this file explains at length why a `UtilityWindow` is *not* used, and a scanner that cannot
    /// tell a declaration from an explanation reports the explanation as the offence.
    @Test func theBoardIsAWindowSceneAndNotAUtilityWindow() throws {
        let scene = try source("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        #expect(scene.contains("Window(\"Set Up XiaolaiDict\", id: Self.setupID)"))
        #expect(!withoutComments(scene).contains("UtilityWindow"), "a UtilityWindow is created and never drawn")
    }
}
