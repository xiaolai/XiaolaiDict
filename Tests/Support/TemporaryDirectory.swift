import Foundation

/// A directory of a test's own, **removed when the test that made it is done with it**.
///
/// The same defect as the defaults suites, in the other resource: every fixture that wanted a store
/// or a ledger made a UUID-named directory under the system's temporary directory and left it
/// there. Measured 2026-09-23: **16,363 of them**, some holding model files and one with its
/// permissions set to 000 by a test about unreadable stores. Nothing swept them, because nothing
/// owned them.
///
/// A class rather than a function, so the lifetime is the thing that cleans up: hold it for as long
/// as the directory is wanted and let it go out of scope. `deinit` is enough here — unlike the
/// defaults suites, a directory has no daemon writing to it after the process exits.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    /// `named` only labels it for a person reading `ls`; uniqueness comes from the UUID.
    public init(named name: String = "xiaolaidict") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path inside it, which the caller may create or not.
    public func appending(_ component: String) -> URL { url.appending(path: component) }

    deinit { Self.remove(url) }

    /// Removes `url` and everything in it. Permissions are put back first: a test about an
    /// unreadable store leaves 000 behind, and `removeItem` cannot descend into that.
    static func remove(_ url: URL) {
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        for case let entry as URL in walk ?? .init() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

/// A file of a test's own — a scratch ledger, say — **in a directory of its own**, for a fixture that
/// hands out a path rather than holding an object.
///
/// A ledger is never one file. SQLite keeps `-wal` and `-shm` beside it, and a migration copies the
/// ledger to `.schemaN.backup` before it changes the shape — so a fixture that put the file straight
/// into the temporary directory and deleted the suffixes it knew of left every backup behind:
/// **175 of them** after one day's test runs, measured 2026-10-03. Removing the directory takes
/// whatever the code under test wrote beside the file, including what nobody listed.
///
/// The directory is named `xiaolaidict-…`, so one a crashed test never removed is still swept by
/// `Tools/clean-test-scratch.sh`.
public enum ScratchFile {
    /// `<temporary>/xiaolaidict-<label>-<UUID>/<file>`, its directory created.
    public static func path(_ label: String, file: String = "ledger.sqlite") -> String {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "xiaolaidict-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: file).path
    }

    /// A path in a directory **nobody makes**, for a store that must be empty: a `ModelStore` at a
    /// root that does not exist creates nothing until something is installed. If something is, it
    /// lands under a `xiaolaidict-…` name the sweep removes, rather than a bare UUID it never would.
    public static func unmade(_ label: String, file: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "xiaolaidict-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: file, directoryHint: .isDirectory)
    }

    /// Removes the directory `path` was made in, and everything in it. **Only one `path(_:file:)`
    /// made**: a path anywhere else is left alone, since removing its parent could remove anything.
    public static func remove(_ path: String) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("xiaolaidict-") else { return }
        TemporaryDirectory.remove(directory)
    }
}
