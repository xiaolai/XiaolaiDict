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
        // **Every set spelled this way, not the first.** The settings stage's validator came to carry one of its own
        // (2026-10-09, the Language Model pane), and a guard that read only the first would have let the second fall
        // behind exactly as the first once did.
        let lines = script.split(separator: "\n").filter { $0.hasPrefix("names = {") }
        #expect(lines.count >= 2, "e2e.sh declares \(lines.count) `names` set(s); the close and the settings report each hold one")
        let panes = Set(SettingsPane.allCases.map(\.name))
        for line in lines {
            // A name is letters and the spaces between words ("Language Model"); the punctuation between names is not one.
            let listed = Set(line.split(separator: "\"")
                .filter { $0.contains(where: \.isLetter) && $0.allSatisfy { $0.isLetter || $0 == " " } }
                .map(String.init))
            #expect(listed == panes, """
                e2e.sh knows \(listed.sorted()) and the app has \(panes.sorted()) — \
                update the `names` set in Tools/e2e.sh: \(line)
                """)
        }
    }
}
