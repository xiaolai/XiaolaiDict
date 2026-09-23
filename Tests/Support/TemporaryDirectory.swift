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

    deinit {
        // Permissions are put back first: a test about an unreadable store leaves 000 behind, and
        // `removeItem` cannot descend into that.
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        for case let entry as URL in walk ?? .init() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}
