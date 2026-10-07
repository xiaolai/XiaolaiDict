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

    /// The files whose code contains `spelling`, how many were scanned, and the name of every file
    /// read — the last for `unread(_:in:)`.
    ///
    /// The count is returned rather than compared here so each caller states the floor its own tree
    /// justifies — an arbitrary `> 20` shared between two trees is a floor for neither.
    public static func offenders(of spelling: String, under root: URL) throws
        -> (names: [String], scanned: Int, read: [String]) {
        let files = try code(under: root)
        return (files.filter { $0.code.contains(spelling) }.map(\.file.lastPathComponent), files.count,
                files.map(\.file.lastPathComponent))
    }

    /// **The canaries a walk did not read** — empty when every one was.
    ///
    /// A directory walk that shrinks fails silent: a count floor still passes on whatever files remain,
    /// and moving a file between targets is exactly how a walk shrinks. So every walker names files only
    /// its real subject holds, and asks this which it missed. A file read by a fixed path fails loud on
    /// its own — `String(contentsOf:)` throws when the file has moved — and needs no canary.
    ///
    /// The scans of source and test paths, classified on 2026-10-08 before `XiaolaiDictCore` was split
    /// (plan-macos-modularisation, P0):
    ///
    /// | Scan | Reads | Class | What makes a shrink loud |
    /// |---|---|---|---|
    /// | `AppShellTests.noWindowIsFoundByItsTitle` | `Sources/XiaolaiDict` | walker | canaries |
    /// | `InstrumentSerialisationTests` | `Sources/XiaolaiDict` | walker | canaries |
    /// | `HistoryDrawerSurfaceTests.noSourceFileKnowsAboutAChoiceOfGlass` | `XiaolaiDictUI`, `XiaolaiDict` | walker | canaries |
    /// | `LibraryWiringTests` (export labels) | targets below the view layer; `XiaolaiDict`, `XiaolaiDictUI` | walker | canary; the call sites must be found |
    /// | `SetupWiringTests.noViewInTheLayerBuildsApplesExplainerForItself` | `Sources/XiaolaiDictUI` | walker | canaries |
    /// | `ScreenRecordingProbeTests` | `Sources` | walker | canaries |
    /// | `DictionaryClientCancellationDriftTests` | `Sources` | walker | canaries |
    /// | `MarkedSentenceTests` | `Sources/XiaolaiDictUI` | walker | canaries |
    /// | `NoMagicValuesTests` (two view-layer walks) | `Sources/XiaolaiDictUI` | walker | canaries |
    /// | `StringCatalogTests.everyLiteralTheReaderSeesIsInTheCatalog` | `XiaolaiDictUI`, `XiaolaiDict` | walker | canaries |
    /// | `StringCatalogTests.noTargetBelowTheViewLayerHoldsDisplayText` | a root per target | walker | roots held to `Package.swift`; each root read |
    /// | `EndToEndTextTests` (reader text; mouse events) | `Sources`; `Tools/e2e` | walker | canaries |
    /// | `StudySurfaceTests` (calling roots) | a root per caller | walker | canaries per root |
    /// | `ReminderDeliveryTests`, `SelectedSittingWiringTests` | `Sources`, `XiaolaiDictUI` | walker | an exact positive answer (`== ["ReminderDelivery.swift"]`, `bound == 2`) |
    /// | `TemporaryDefaultsTests`, `TemporaryDirectoryTests`, `FixtureNamespaceTests` | `Tests` | walker | canaries |
    /// | `TestInventoryTests` | `Tests/<target>` | walker | exact floors, every directory on disk |
    /// | `ModuleBoundaryTests` | a root per manifest target | walker | roots read off `Package.swift`; a root read empty is refused |
    /// | `Tools/tests/ledger_schema.py` | the ledger's source directory | walker | canaries, then the tables it must find |
    /// | `Tools/strings.sh` | the app product's modules | product | follows `Package.swift`; refuses an empty or shrinking extraction |
    /// | `Tools/build-bundle.sh` (input digest), SwiftLint | all of `Sources` | whole tree | a moved file stays inside it |
    /// | `StudySurfaceTests.declaring`, `NoMagicValuesTests.placementFiles`, `EndToEndReportKeyTests.instruments` | named files | fixed path | each list checked on disk, or read with `try` |
    /// | `LedgerConnectionTests`, `LibraryPaneChromeTests` and every other `Sources/…/X.swift` read in `Tests` | named files | fixed path | the read throws |
    /// | `Tools/tests/test_service_boundaries.py`, `test_portability.py`, `test_reminder.py` | named files | fixed path | the read raises |
    public static func unread(_ canaries: [String], in read: [String]) -> [String] {
        let names = Set(read)
        return canaries.filter { !names.contains($0) }
    }

    /// `unread(_:in:)` for a walk that kept its files' URLs.
    public static func unread(_ canaries: [String], in read: [URL]) -> [String] {
        unread(canaries, in: read.map(\.lastPathComponent))
    }
}
