import Foundation
import Testing

@testable import XiaolaiDictUI

/// **The board is handed everything it needs, by the app that owns it.**
///
/// `SetupView` takes four parameters and every one of them defaults to nil, so a board built with
/// none of them compiles, renders, and shows a permanent "Asking which dictionaries are enabled…"
/// with no dictionary to choose, no shortcut to name and no way out to Settings. Every unit test
/// over `SetupBoard` would still pass: they construct the board directly.
///
/// That is the `HoverPause` defect's exact shape — a model that was complete, covered, and
/// connected to nothing, because a defaulted closure parameter nobody supplies is invisible to
/// every test that exercises the value itself. So this reads the call site instead.
///
/// It is a source scan rather than a rendered view because SwiftUI offers no way to ask a view
/// which arguments it was built with, and a test that rendered one would be asserting on the
/// pixels rather than on the wire.
struct SetupWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
        // Thrown by `String(contentsOf:)` rather than defaulted to "": a scanner that silently
        // reads nothing passes forever and guards nothing.
        #expect(!text.isEmpty, "\(relativePath) is empty")
        return text
    }

    /// The call in `XiaolaiDictScene.swift`, from `SetupView(` to the line that closes it.
    private func callSite(_ text: String, of view: String) throws -> String {
        let start = try #require(text.range(of: "\(view)("), "nothing constructs \(view)")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n        )") ?? rest.range(of: ")\n"),
                               "could not find the end of the \(view) call")
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    @Test func theAppHandsTheBoardEveryPartOfItsState() throws {
        let scene = try source("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        let call = try callSite(scene, of: "SetupView")
        for argument in ["model:", "dictionary:", "shortcut:", "openSettings:"] {
            #expect(
                call.contains(argument),
                "SetupView is built without \(argument); that parameter defaults to nil, so the board would silently lose what it carries")
        }
    }

    /// The other way in. §4 of the plan asks for both, and a menu item alone leaves a reader who is
    /// already in Settings with no way to the board.
    @Test func settingsCanOpenTheBoard() throws {
        let scene = try source("Sources/XiaolaiDict/XiaolaiDictScene.swift")
        #expect(
            try callSite(scene, of: "SettingsView").contains("openSetup:"),
            "the settings window cannot open the setup board")
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
        let code = scene.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("UtilityWindow"), "a UtilityWindow is created and never drawn")
    }

    /// Nothing calls `SelfRelaunch` yet, and that is deliberate — item 5 is blocked on a
    /// measurement. **Asserted rather than assumed**, so the day it is wired, this test is what
    /// says the measurement was meant to come first.
    @Test func nothingRelaunchesTheAppYet() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(
            !app.contains("SelfRelaunch"),
            "something now relaunches the app — was the Screen Recording measurement done first?")
    }
}
