import Foundation
import Testing
import XiaolaiDictTestSupport

/// **A directory a test makes is a directory a test removes.**
///
/// The same defect as the defaults suites, in the other resource. Measured 2026-09-23: **16,363
/// UUID-named directories** under the system's temporary directory, left by every store and ledger
/// fixture since the project began — some holding model files, one with its permissions set to 000
/// by a test about unreadable stores, and nothing anywhere that would ever sweep them.
struct TemporaryDirectoryTests {
    @Test func itRemovesItselfWhenTheTestIsDoneWithIt() throws {
        var path = ""
        do {
            let scratch = TemporaryDirectory(named: "xiaolaidict-selftest")
            path = scratch.url.path
            #expect(FileManager.default.fileExists(atPath: path))
            try Data("weights".utf8).write(to: scratch.appending("model.safetensors"))
        }
        #expect(!FileManager.default.fileExists(atPath: path), "the directory outlived the test that made it")
    }

    /// Even one a test made unreadable: `removeItem` cannot descend into 000, and the fixture that
    /// proves an unreadable store is refused is exactly the one that would be left behind for ever.
    @Test func itRemovesOneItCannotReadIntoEither() throws {
        var path = ""
        do {
            let scratch = TemporaryDirectory(named: "xiaolaidict-selftest")
            path = scratch.url.path
            let inner = scratch.appending("staging")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inner.path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// **Nothing else may make one.** The leak was a dozen fixtures each writing the same three
    /// lines, so the rule is mechanical rather than remembered — the same shape as
    /// `everySuiteNameComesFromTemporaryDefaults`, and for the same reason.
    @Test func everyScratchDirectoryComesFromTemporaryDirectory() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let support = tests.appendingPathComponent("Support").standardizedFileURL.path
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.standardizedFileURL.path.hasPrefix(support) }
        try #require(files.count > 20, "found only \(files.count) test files — the scan is not looking where the tests are")
        // Built from parts so this file does not match its own search, and matched without regard
        // to case because the leak has two spellings: `FileManager.temporaryDirectory` and
        // Foundation's older `NSTemporaryDirectory()`. Searching for the first alone left the
        // second making UUID-named directories under a rule written to stop exactly that.
        let making = "temporary" + "directory"
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.lowercased().contains(making) else { continue }
                // A *file* under it is cleaned up by the `defer` the ledger fixtures already have;
                // what leaks is a directory, which is what `appending(path:` with a directory hint
                // or `createDirectory` makes.
                guard code.contains("directoryHint") || code.contains("createDirectory") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty,
                "these make a directory the system will keep for ever; use TemporaryDirectory: \(offenders.joined(separator: ", "))")
    }
}
