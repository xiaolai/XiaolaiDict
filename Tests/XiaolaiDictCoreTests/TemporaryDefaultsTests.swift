import Foundation
import Testing
import XiaolaiDictTestSupport

/// A throwaway defaults suite must leave nothing behind — and the first thing that needs
/// proving is that removing one actually removes it.
///
/// Measured 2026-09-22: 4,164 suites from this test suite had accumulated in
/// `~/Library/Preferences`, one per test per run, since the project began. Most tests never
/// cleaned up; the ones that did called `removePersistentDomain(forName:)`, which empties the
/// domain and **leaves its plist file in place** — with or without a synchronize after it. Only
/// removing the domain and deleting the file makes it go, and it stays gone after a later read.
struct TemporaryDefaultsTests {
    /// cfprefsd writes asynchronously, so the file is waited for rather than assumed.
    private func fileExists(_ name: String, within seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if FileManager.default.fileExists(atPath: TemporaryDefaults.file(of: name).path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    @Test func aRemovedSuiteLeavesNoFileBehind() throws {
        let name = TemporaryDefaults.name()
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set("x", forKey: "k")
        defaults.synchronize()
        try #require(fileExists(name), "the suite was never written, so this proves nothing")

        TemporaryDefaults.remove(name)

        #expect(!fileExists(name, within: 1), "the plist survived removal")
        // Nor does touching the suite again bring it back.
        _ = UserDefaults(suiteName: name)?.string(forKey: "k")
        #expect(!fileExists(name, within: 1), "a later read resurrected the plist")
    }

    /// **Every suite name a test uses comes from `TemporaryDefaults`, mechanically.** A suite
    /// named any other way is one nothing removes, and the leak was a dozen call sites doing
    /// exactly that; a rule that depends on each new test remembering is the rule that already
    /// failed. What it refuses, outside `Tests/Support` and outside comments:
    /// - a suite opened on anything but a plain name — a literal, an interpolation, a call —
    ///   because that is how every leaking site built one;
    /// - a file that opens suites by name without getting its names from `TemporaryDefaults`;
    /// - `removePersistentDomain`, the cleanup that leaves the file behind.
    @Test func everySuiteNameComesFromTemporaryDefaults() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let support = tests.appendingPathComponent("Support").standardizedFileURL.path
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.standardizedFileURL.path.hasPrefix(support) }
        try #require(files.count > 20, "found only \(files.count) test files — the scan is not looking where the tests are")
        // Built from parts so this file does not match its own search.
        let opening = "UserDefaults(" + "suiteName:"
        let emptying = "removePersistent" + "Domain("
        let byPlainName = try Regex(#"UserDefaults\(suiteName:\s*[A-Za-z_][A-Za-z0-9_]*\s*\)"#)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            var opensByName = false
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let place = "\(file.lastPathComponent):\(index + 1)"
                if code.contains(emptying) { offenders.append("\(place) empties a domain and leaves its file") }
                guard code.contains(opening) else { continue }
                if code.contains(byPlainName) { opensByName = true } else { offenders.append("\(place) names a suite itself") }
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            if opensByName, !text.contains("TemporaryDefaults.name()") {
                offenders.append("\(file.lastPathComponent) opens suites by name but never gets one from TemporaryDefaults")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
