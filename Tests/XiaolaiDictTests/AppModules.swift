import Foundation
import Testing
import XiaolaiDictTestSupport

/// **The modules the app links, read off `Package.swift`, each held to a file it must be seen to hold** — the roots of
/// every scan whose subject is anywhere in the app: a window found by its title (`SceneShellTests`), a choice of glass
/// (`HistoryDrawerSurfaceTests`), a report serialised outside `Instrument.write` (`InstrumentSerialisationTests`).
///
/// Each of those walked `Sources/XiaolaiDict` — the glass check the view layer too — while the split moved 22 of the
/// app's files into `StudyModels`, `MacCapture` and `XiaolaiDictBase`, and each went on passing on two named files and
/// a count floor: the window check stopped reading the ten capture readers, which speak AppKit and read other apps'
/// windows (a review in refute mode counted it, 2026-10-08). So the roots are not a list kept by hand. They are the app
/// and every target it reaches through its dependencies, read by the manifest reader `ModuleBoundaryTests` holds to
/// SwiftPM — a module the app comes to link is walked the day the edge is written — and each root is held to a
/// witness named here, so a root that read other files, or none, fails by name rather than by count.
enum AppModules {
    /// The repository this test file is in.
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// **One file each module the app links holds, and no other module does** (`Tools/strings.sh` refuses two source
    /// files of one name). Exact, in both directions, against what `Package.swift` says the app links: a module that
    /// joins the app is refused until it is named here, and a row for one that left is refused too.
    static let witnesses: [String: String] = [
        "XiaolaiDict": "XiaolaiDictApp.swift",
        "XiaolaiDictUI": "LibraryView.swift",
        "StudyModels": "LedgerStore.swift",
        "StudyPresentation": "LibraryPresentation.swift",
        "MacCapture": "HoverWatcher.swift",
        "StudyKit": "Ledger.swift",
        "Capture": "HoverPolicy.swift",
        "XiaolaiDictCore": "SenseSelector.swift",
        "CaptureModel": "ReadingPlace.swift",
        "ReviewKit": "MemoryScheduler.swift",
        "ModelKit": "ModelProtocol.swift",
        "DictionaryModel": "DictionaryProtocol.swift",
        "XiaolaiDictBase": "XiaolaiDictIdentity.swift",
        "LLMProviders": "OpenAICompatibleProvider.swift",
    ]

    /// Every module the app links, its Swift files with full-line comments removed (`SourceScan.code`), and every way
    /// the walk fell short of that — a module with no witness, a witness for a module the app does not link, a root
    /// whose witness was not read. **A caller asserts `problems` is empty before it trusts `files`.**
    struct Scan {
        let files: [(module: String, file: URL, code: String)]
        let problems: [String]

        /// The names of every file read, for `SourceScan.unread`.
        var read: [URL] { files.map(\.file) }
    }

    /// The modules the executable `app` links in the manifest at `repository`, and their sources under `Sources/`.
    static func scan(repository: URL = repository, app: String = "XiaolaiDict",
                     witnesses: [String: String] = witnesses) throws -> Scan {
        let manifest = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
        let linked = Manifest.closure(of: app, in: try Manifest.dependencyMap(of: manifest))
        var problems = linked.subtracting(witnesses.keys).sorted()
            .map { "the app links \($0), and AppModules.witnesses names no file of it" }
        problems += Set(witnesses.keys).subtracting(linked).sorted()
            .map { "AppModules.witnesses names \($0), which the app does not link" }
        var files: [(module: String, file: URL, code: String)] = []
        for module in linked.sorted() {
            let read = try SourceScan.code(under: repository.appending(path: "Sources").appending(path: module))
            files += read.map { (module, $0.file, $0.code) }
            if let witness = witnesses[module], !SourceScan.unread([witness], in: read.map(\.file)).isEmpty {
                problems.append("the walk of Sources/\(module) did not read \(witness)")
            }
        }
        return Scan(files: files, problems: problems)
    }
}

/// The roots, and the controls that show each way they can fall short is refused.
struct AppModulesTests {
    /// **The witnesses name exactly the modules the app links, and every walk reads each one.**
    @Test func everyModuleTheAppLinksIsWalkedAndReadsItsWitness() throws {
        let scan = try AppModules.scan()
        #expect(scan.problems.isEmpty, "\(scan.problems)")
        // What the app links now, read off the manifest by the same reader — so this line moves only with a decision.
        #expect(Set(scan.files.map(\.module)) == Set(AppModules.witnesses.keys))
    }

    /// **The controls, in a scratch repository of their own**, never in `Sources`: a module the app comes to link with
    /// no witness named, a witness for a module it does not link, and a root that does not hold its witness — each
    /// refused by name; and the clean tree passes.
    @Test func eachWayARootFallsShortIsRefused() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-app-modules")
        func write(_ text: String, to path: String) throws {
            let url = scratch.appending(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
            .executableTarget(name: "App", dependencies: ["Shown"]),
            .target(name: "Shown", dependencies: ["Base"]),
            .target(name: "Base"),
            .target(name: "Elsewhere"),
            .testTarget(name: "AppTests", dependencies: ["App"]),
            """, to: "Package.swift")
        try write("let app = 1\n", to: "Sources/App/App.swift")
        try write("let shown = 1\n", to: "Sources/Shown/Shown.swift")
        try write("let base = 1\n", to: "Sources/Base/Base.swift")
        let named = ["App": "App.swift", "Shown": "Shown.swift", "Base": "Base.swift"]

        let clean = try AppModules.scan(repository: scratch.url, app: "App", witnesses: named)
        #expect(clean.problems.isEmpty, "\(clean.problems)")
        #expect(Set(clean.files.map(\.module)) == ["App", "Shown", "Base"], "the walk is the closure, transitively")

        var short = named
        short["Base"] = nil
        short["Elsewhere"] = "Elsewhere.swift"
        short["Shown"] = "Moved.swift"
        #expect(try AppModules.scan(repository: scratch.url, app: "App", witnesses: short).problems == [
            "the app links Base, and AppModules.witnesses names no file of it",
            "AppModules.witnesses names Elsewhere, which the app does not link",
            "the walk of Sources/Shown did not read Moved.swift",
        ])
    }
}
