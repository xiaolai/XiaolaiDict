import Foundation

/// Walking the source tree looking for a forbidden spelling.
///
/// **Extracted because two copies had drifted into the same two defects.**
/// `ScreenRecordingProbeTests` and `InstrumentTests` each carried their own walk, their own comment
/// filter, their own offender list and their own arbitrary `scanned > 20` floor — and both ignored
/// directory-traversal errors, so an unreadable subtree was silently skipped while the floor still
/// passed on the files that remained. `XiaolaiDictCore` alone holds 45 Swift files, so skipping the
/// whole of `XiaolaiDict` would not have moved the count below it.
public enum SourceScan {
    /// A directory that could not be walked, or a file that could not be read. **Thrown, never
    /// skipped**: a scanner that silently reads less than it claims passes forever and guards
    /// nothing, which is the failure this type exists to make impossible.
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(path: String, underlying: (any Error)?)

        public var description: String {
            switch self {
            case .unreadable(let path, let underlying):
                "could not read \(path)\(underlying.map { ": \($0)" } ?? "")"
            }
        }
    }

    /// Every `.swift` file under `root`, with full-line comments removed.
    ///
    /// Comments go first because these scanners look for API names that the code around them
    /// *explains* — `Permissions.swift` names `CGPreflightScreenCaptureAccess` in prose precisely to
    /// say it is not the one that decides, and a scanner that cannot tell a call from an
    /// explanation reports the explanation.
    public static func code(under root: URL) throws -> [(file: URL, code: String)] {
        var failure: (any Error)?
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in failure = error; return false })
        else { throw Failure.unreadable(path: root.path, underlying: nil) }

        var found: [(file: URL, code: String)] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            found.append((file, code))
        }
        // Checked after the walk: the handler runs during it, and returning `false` stops the
        // enumeration rather than throwing out of it.
        if let failure { throw Failure.unreadable(path: root.path, underlying: failure) }
        return found
    }

    /// The files whose code contains `spelling`, and how many were scanned.
    ///
    /// The count is returned rather than compared here so each caller states the floor its own tree
    /// justifies — an arbitrary `> 20` shared between two trees is a floor for neither.
    public static func offenders(of spelling: String, under root: URL) throws -> (names: [String], scanned: Int) {
        let files = try code(under: root)
        return (files.filter { $0.code.contains(spelling) }.map(\.file.lastPathComponent), files.count)
    }
}
