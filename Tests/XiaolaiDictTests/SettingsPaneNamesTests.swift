import Foundation
import Testing
@testable import XiaolaiDictUI

/// **The harness's list of pane names is the app's, or it is nothing.**
///
/// `e2e.sh` carries a literal set of pane names to find the settings window by, because a shell
/// heredoc cannot import Swift. A set that falls behind finds no window, and the close that follows
/// then closes whichever surface the fallback names instead — quietly, with the stage still green.
///
/// It had already drifted when this was written: the Setup pane was added and the set was not
/// touched, which nothing would have reported.
struct SettingsPaneNamesTests {
    @Test func theHarnessKnowsEveryPaneByName() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tools/e2e.sh"),
            encoding: .utf8)
        let line = try #require(
            script.split(separator: "\n").first { $0.hasPrefix("names = {") },
            "e2e.sh no longer declares a `names` set, so this guard covers nothing")
        let listed = Set(line.split(separator: "\"").filter { $0.allSatisfy(\.isLetter) }.map(String.init))
        let panes = Set(SettingsPane.allCases.map(\.name))
        #expect(listed == panes, """
            e2e.sh knows \(listed.sorted()) and the app has \(panes.sorted()) — \
            update the `names` set in Tools/e2e.sh
            """)
    }
}
