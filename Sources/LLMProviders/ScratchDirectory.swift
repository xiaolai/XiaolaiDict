import Foundation
import os
import XiaolaiDictBase

/// **An empty directory a resident CLI runs in, removed when nothing holds it.**
///
/// Both CLIs read instructions from the directory they run in and its parents — `CLAUDE.md`, `AGENTS.md` — so they
/// run in one of this app's own, made empty and private to this user. Under the user's temporary directory rather than
/// beside the app's data, because a reader may keep such a file in their home directory, and every directory there has
/// it as a parent. Measured 2026-10-09: neither CLI wrote anything into it across ~45 Claude and ~10 Codex runs.
public final class ScratchDirectory: Sendable {
    public let url: URL

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    /// A new directory, or nil where one could not be made.
    public init?() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "XiaolaiDict-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            Self.log.error("a working directory for a CLI could not be made: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
