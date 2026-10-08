import Foundation
@testable import LLMProviders
import Testing
import XiaolaiDictTestSupport

/// **The reader's sign-in is theirs** (ADR-0053): the providers start the reader's unmodified CLI and never read what
/// it keeps — its configuration directories, its `auth.json`, its token variable, its Keychain item — and never start
/// it bare, which reads no subscription. A rule a grep can hold, held by one.
struct CredentialBoundaryTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/LLMProviders")

    /// Built from parts, so this file never matches its own search. **Two spellings of each directory**, with and
    /// without the home prefix, because a path is joined from parts as often as it is written whole.
    static let forbidden = [
        "/." + "claude", "." + "claude/", "/." + "codex", "." + "codex/", "auth" + ".json",
        "CLAUDE_CODE_" + "OAUTH_TOKEN", "--" + "bare", "Claude Code" + "-credentials",
    ]

    static func offenders(under root: URL) throws -> [String] {
        try SourceScan.code(under: root).flatMap { file, code in
            forbidden.filter { code.contains($0) }.map { "\(file.lastPathComponent): \($0)" }
        }
    }

    @Test func nothingInTheProvidersNamesWhatACLIKeepsForItsSignIn() throws {
        let files = try SourceScan.code(under: Self.sources)
        // Named, so a scan that stopped reading the files that start the CLIs fails rather than passes empty.
        let unread = SourceScan.unread(["ClaudeCLIProvider.swift", "CodexCLIProvider.swift", "CLILocator.swift",
                                        "ChildProcess.swift"], in: files.map(\.file))
        try #require(unread.isEmpty, "the scan no longer reads \(unread)")
        #expect(try Self.offenders(under: Self.sources).isEmpty)
    }

    /// **The positive control**: each spelling, planted in a file the scan reads, is found — and in a comment is not,
    /// which is where this module explains the rule.
    @Test func eachForbiddenSpellingIsFoundWherePlanted() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-credential-scan")
        for (index, spelling) in Self.forbidden.enumerated() {
            try Data("let planted\(index) = \"\(spelling)\"\n// explained: \(spelling)\n".utf8)
                .write(to: scratch.appending("Planted\(index).swift"))
        }
        #expect(try Self.offenders(under: scratch.url).count == Self.forbidden.count)
    }

    /// The working directory a CLI runs in is made empty, private to this user, and removed with its owner.
    @Test func aScratchDirectoryIsEmptyPrivateAndRemovedWithItsOwner() throws {
        var path = ""
        do {
            let scratch = try #require(ScratchDirectory())
            path = scratch.url.path
            #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            #expect(mode == 0o700)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
