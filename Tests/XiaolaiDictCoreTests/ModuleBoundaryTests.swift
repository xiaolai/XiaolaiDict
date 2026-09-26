import Foundation
import Testing
import XiaolaiDictTestSupport

/// **The boundary the module split bought, asserted rather than described.**
///
/// `AGENTS.md` has said "`XiaolaiDictCore` carries no AppKit and no private API" since the project
/// began, and until this file nothing checked it. `XiaolaiDictCore` declares no target dependencies
/// that would stop `import AppKit`, so it was true only because nobody had typed it — in a
/// repository where `NoMagicValuesTests` rejects every numeric literal in a directory and
/// `everySuiteNameComesFromTemporaryDefaults` bans a spelling. The largest invariant in the file was
/// the one enforced by nothing.
///
/// It also records what each target *is allowed* to bind. That half is not defensive tidying: it is
/// how `Carbon.HIToolbox`, `Darwin`, `Dispatch`, `os` and `Synchronization` came to be in the core
/// without appearing in the sentence in `AGENTS.md` that lists what the core binds. A framework
/// arriving in a target below the view layer is now a line in a diff.
struct ModuleBoundaryTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every library target below the view layer, and the system modules it may bind.
    ///
    /// **Exact sets, not floors.** A floor would let a framework in silently, which is the whole
    /// thing being prevented; an exact set makes adding one a decision. Each target's own siblings
    /// (`XiaolaiDictBase`, `DictionaryModel`, `ModelKit`, `XiaolaiDictCore`) are checked separately
    /// against `Package.swift` below, so they are not listed here.
    static let allowed: [String: Set<String>] = [
        // No domain vocabulary, and so almost no framework. If this set grows, the target has
        // stopped being what it is for.
        "XiaolaiDictBase": ["Dispatch", "Synchronization"],
        // CryptoKit is here because `DictionarySense.hash` keys a sense the publisher gave no id by
        // a SHA-256 of its own text, and `DictionaryBridge` builds those values — so it is on the
        // dictionary service's own execution path and cannot be moved out of it.
        "DictionaryModel": ["Foundation", "NaturalLanguage", "CryptoKit"],
        // FoundationModels for `@Generable` and the refusal it reports; CryptoKit for the weights'
        // per-file hashes; NaturalLanguage for `TranslationCheck`. **No MLX** — that is the model
        // service executable's alone, and this target exists so the app can talk about a model it
        // never links.
        "ModelKit": ["Foundation", "FoundationModels", "CryptoKit", "NaturalLanguage", "Darwin"],
        // The reader's side. `Carbon.HIToolbox` is virtual key codes for `Shortcut`, never
        // registration — that is `Hotkey`, in the app.
        "XiaolaiDictCore": [
            "Foundation", "CoreGraphics", "NaturalLanguage", "CoreServices", "SQLite3",
            "FoundationModels", "Carbon.HIToolbox", "os",
        ],
        // What the model service *does* with a request, written against any `LanguageModel` so its
        // tests need no GPU.
        "LocalModel": ["Foundation", "FoundationModels", "Synchronization"],
        // The private DictionaryServices API, reached by `dlopen` rather than by linking it.
        "DictionaryBridge": ["Foundation", "Synchronization"],
    ]

    /// The view layer, which may bind AppKit and SwiftUI, and is excluded from the rule below.
    static let viewLayer: Set<String> = ["XiaolaiDictUI", "XiaolaiDict"]

    // MARK: - No view layer below the view layer

    /// **The invariant `AGENTS.md` has always stated and nothing has ever checked.**
    ///
    /// Two reasons it matters beyond tidiness: a target that binds AppKit stops being exhaustively
    /// testable without a window server, and the segfault-prone DictionaryServices calls stay behind
    /// the XPC boundary only while the targets on this side of it have no reason to draw.
    @Test func nothingBelowTheViewLayerBindsAppKitOrSwiftUI() throws {
        let forbidden = ["AppKit", "SwiftUI", "UIKit", "QuartzCore", "WebKit"]
        var offenders: [String] = []
        for target in Self.allowed.keys.sorted() {
            for (file, imports) in try Self.imports(of: target) {
                for module in imports where forbidden.contains(module) {
                    offenders.append("\(target)/\(file) imports \(module)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// **And the list of targets to check is read off `Package.swift`, not kept by hand.** A target
    /// added later and forgotten here is a target the rule above does not cover, and it would go on
    /// passing — the same shape as a source scan that names one directory.
    @Test func everyLibraryTargetIsEitherCheckedOrTheViewLayer() throws {
        let declared = try Self.targets()
        let accountedFor = Set(Self.allowed.keys)
            .union(Self.viewLayer)
            .union(["XiaolaiDictService", "XiaolaiDictModelService", "XiaolaiDictTestSupport"])
        #expect(Set(declared) == accountedFor, """
            declared in Package.swift: \(declared.sorted()); accounted for here: \
            \(accountedFor.sorted())
            """)
    }

    // MARK: - What each target binds

    @Test func eachTargetBindsOnlyWhatItIsAllowedTo() throws {
        var surprises: [String] = []
        for (target, permitted) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            let siblings = Set(Self.allowed.keys).union(Self.viewLayer)
            var bound: Set<String> = []
            for (_, imports) in try Self.imports(of: target) {
                bound.formUnion(imports.filter { !siblings.contains($0) })
            }
            let extra = bound.subtracting(permitted)
            let gone = permitted.subtracting(bound)
            if !extra.isEmpty { surprises.append("\(target) newly binds \(extra.sorted())") }
            // Reported too: a permitted framework nothing imports any more is a line that has
            // stopped meaning anything, and an allow-list nobody prunes is one nobody reads.
            if !gone.isEmpty { surprises.append("\(target) no longer binds \(gone.sorted()) — drop it from the list") }
        }
        #expect(surprises.isEmpty, "\(surprises)")
    }

    // MARK: - Imports and declared dependencies agree

    /// **An import with no declared edge, and a declared edge nothing imports.** Both directions,
    /// because each hides a different mistake: the first compiles only by accident, against a module
    /// still on the search path — which is exactly how every moved type read as "ambiguous for type
    /// lookup" during the split, three files having kept `import XiaolaiDictCore` after their target
    /// stopped depending on it. The second is a dependency nobody needs, which is how a target comes
    /// to link a subject it does not use.
    @Test func declaredDependenciesAndImportsAgree() throws {
        let declaredFor = try Self.dependencyMap()
        let ours = Set(try Self.targets())
        var problems: [String] = []
        // Test targets are excluded: a test target legitimately depends on a module it reaches only
        // through `@testable import`, and on modules whose types it names without importing them
        // directly. `XiaolaiDictTestSupport` ships nothing and is the fixture target.
        let libraries = try Self.targets().filter {
            !$0.hasSuffix("Tests") && $0 != "XiaolaiDictTestSupport"
        }
        for target in libraries {
            guard let declared = declaredFor[target] else {
                problems.append("\(target) has no declaration this test could read")
                continue
            }
            var imported: Set<String> = []
            for (_, imports) in try Self.imports(of: target) {
                imported.formUnion(imports.filter { ours.contains($0) })
            }
            for module in imported.subtracting(declared).sorted() {
                problems.append("\(target) imports \(module) without Package.swift naming it")
            }
            for module in declared.subtracting(imported).sorted() {
                problems.append("\(target) depends on \(module) and imports it nowhere")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: - Reading the tree and the manifest

    /// Every `.swift` under `Sources/<target>`, with its import lines. Comments stripped by
    /// `SourceScan` for the reason it strips them: a doc comment naming `AppKit` is not an import.
    private static func imports(of target: String) throws -> [(file: String, modules: [String])] {
        let root = repository.appending(path: "Sources").appending(path: target)
        let line = try Regex(#"^\s*(?:@preconcurrency\s+|@_implementationOnly\s+)?import\s+([A-Za-z_][A-Za-z0-9_.]*)"#)
        return try SourceScan.code(under: root).map { file, code in
            let modules = code.components(separatedBy: "\n").compactMap { row -> String? in
                guard let match = try? line.firstMatch(in: row) else { return nil }
                return String(match.output[1].substring ?? "")
            }
            return (file.lastPathComponent, modules)
        }
    }

    /// The target names `Package.swift` declares.
    private static func targets() throws -> [String] {
        let manifest = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
        let declared = try Regex(#"\.(?:executableT|t)arget\(\s*name: "([A-Za-z]+)""#)
        return manifest.matches(of: declared).map { String($0.output[1].substring ?? "") }
    }

    /// The in-package dependencies `Package.swift` gives each target.
    ///
    /// **Split on the target declarations rather than searched forward from a name.** The first
    /// version looked for the *next* `target(name:` after the one it had found, and the manifest
    /// writes `.target(\n    name:` in places — so a target's "body" ran on into its neighbours and
    /// the test reported `LocalModel` depending on `LocalModel` and on `XiaolaiDictModelService`.
    /// That was the test being wrong, not the manifest, and it is the reason this returns the whole
    /// map at once: one parse whose boundaries are the declarations themselves.
    ///
    /// `.product(name: "MLX", package: …)` entries name external packages and are dropped — the
    /// import check has nothing to say about them.
    private static func dependencyMap() throws -> [String: Set<String>] {
        let manifest = try String(contentsOf: repository.appending(path: "Package.swift"), encoding: .utf8)
        let ours = Set(try targets())
        let head = try Regex(#"\.(?:executableT|testT|t)arget\("#)
        var starts = manifest.ranges(of: head).map(\.lowerBound)
        starts.append(manifest.endIndex)
        let name = try Regex(#"name:\s*"([A-Za-z]+)""#)
        let quoted = try Regex(#""([A-Za-z]+)""#)
        var map: [String: Set<String>] = [:]
        for (start, end) in zip(starts, starts.dropFirst()) {
            let body = manifest[start..<end]
            guard let declared = try? name.firstMatch(in: String(body)),
                  let target = declared.output[1].substring.map(String.init)
            else { continue }
            guard let list = body.range(of: "dependencies:") else { map[target] = []; continue }
            let names = body[list.upperBound...].matches(of: quoted)
                .compactMap { $0.output[1].substring.map(String.init) }
                .filter { ours.contains($0) && $0 != target }
            map[target] = Set(names)
        }
        return map
    }
}
