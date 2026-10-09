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
        // Named, not counted: users of scratch directories in three test targets (SourceScan.unread).
        let unread = SourceScan.unread(["ModelStoreTests.swift", "LocalModelControllerTests.swift",
                                        "PhraseInventoryStoreTests.swift"], in: files)
        try #require(unread.isEmpty, "the scan no longer reads \(unread)")
        // Built from parts so this file does not match its own search. **Two spellings**, because the
        // leak has two: `FileManager.default.temporaryDirectory` and Foundation's older
        // `NSTemporaryDirectory()`. Case-sensitive, so `TemporaryDirectory(named:)` — the fix — is not
        // mistaken for the defect.
        //
        // **Any use at all, not a use that makes a directory.** This used to let a *file* through,
        // on the theory that the ledger fixtures' `defer` removed it — but a ledger is never one file:
        // a migration writes `.schemaN.backup` beside it, and no fixture listed that suffix. 175
        // backups were sitting in the temporary directory on 2026-10-03 under a green scan. It also
        // matched one line at a time, so `temporaryDirectory` on one line and `createDirectory` on the
        // next — three fixtures had exactly that — passed. A rule with no exceptions has neither hole:
        // a file goes through `ScratchFile`, a directory through `TemporaryDirectory`.
        let spellings = ["." + "temporary" + "Directory", "NS" + "Temporary" + "Directory("]
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///"), spellings.contains(where: code.contains)
                else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty,
                "these reach the system's temporary directory themselves; use TemporaryDirectory or ScratchFile: \(offenders.joined(separator: ", "))")
    }

    /// **A scratch file is removed by the file that made it.** `ScratchFile.path` hands out a path, not an owner, so
    /// nothing removes its directory unless the caller does — and `DeveloperDataTests` never did: five ledgers left by
    /// every run, which `Tools/clean-test-scratch.sh` swept an hour later as "left by earlier runs" (2026-10-09). Counted
    /// per file, because a helper that makes the path usually hands back its removal beside it.
    @Test func everyScratchFileIsRemovedInTheFileThatMadeIt() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let support = tests.appendingPathComponent("Support").standardizedFileURL.path
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.standardizedFileURL.path.hasPrefix(support) }
        // Built from parts so this file does not count its own search.
        let made = "ScratchFile" + ".path(", removed = "ScratchFile" + ".remove("
        var makers = 0
        var offenders: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
            let paths = code.reduce(0) { $0 + $1.components(separatedBy: made).count - 1 }
            let removals = code.reduce(0) { $0 + $1.components(separatedBy: removed).count - 1 }
            if paths > 0 { makers += 1 }
            if paths > removals { offenders.append("\(file.lastPathComponent) (\(paths) made, \(removals) removed)") }
        }
        // The positive control: the scan is reading files that use the fixture at all.
        try #require(makers > 5, "only \(makers) files make a scratch file — the scan is not reading where they are")
        #expect(offenders.isEmpty, "these make scratch files they never remove: \(offenders.joined(separator: ", "))")
    }
}
