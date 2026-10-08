import Foundation

/// **`Package.swift`, read as text — the one reader of it every test uses.**
///
/// Moved here from `ModuleBoundaryTests` (2026-10-08) when the walkers whose subject is anywhere in the app came to
/// derive their roots from the manifest: a second reader in another test target would be a second spelling of the
/// same reading, free to disagree with this one. `ModuleBoundaryTests.theManifestReaderAgreesWithSwiftPM` holds this
/// one to SwiftPM's own evaluation of the manifest, so every test that reads targets through it inherits that check.
public enum Manifest {
    /// The target names `manifest` declares, but the tests: every `.target(` and `.executableTarget(`.
    ///
    /// **Any name SwiftPM accepts**, not a pattern of letters: `Unsafe2` was no target to this reader (the final
    /// closing pass, finding 4). SwiftPM takes any string and makes a module name of it, so the reader takes
    /// everything up to the closing quote.
    public static func targets(in manifest: String) throws -> [String] {
        let declared = try Regex(#"\.(?:executableT|t)arget\(\s*name: "([^"\\]+)""#)
        return manifest.matches(of: declared).map { String($0.output[1].substring ?? "") }
    }

    /// The in-package dependencies `manifest` gives each target, the tests included.
    ///
    /// **Split on the target declarations rather than searched forward from a name.** The first version looked for
    /// the *next* `target(name:` after the one it had found, and the manifest writes `.target(\n    name:` in places
    /// — so a target's "body" ran on into its neighbours and the test reported `LocalModel` depending on `LocalModel`
    /// and on `XiaolaiDictModelService`. That was the test being wrong, not the manifest, and it is the reason this
    /// returns the whole map at once: one parse whose boundaries are the declarations themselves.
    ///
    /// `.product(name: "MLX", package: …)` entries name external packages and are dropped — no check of this
    /// package's own graph has anything to say about them.
    public static func dependencyMap(of manifest: String) throws -> [String: Set<String>] {
        let ours = Set(try targets(in: manifest))
        let head = try Regex(#"\.(?:executableT|testT|t)arget\("#)
        var starts = manifest.ranges(of: head).map(\.lowerBound)
        starts.append(manifest.endIndex)
        let name = try Regex(#"name:\s*"([^"\\]+)""#)
        let quoted = try Regex(#""([^"\\]+)""#)
        var map: [String: Set<String>] = [:]
        for (start, end) in zip(starts, starts.dropFirst()) {
            let body = manifest[start..<end]
            guard let declared = try? name.firstMatch(in: String(body)),
                  let target = declared.output[1].substring.map(String.init)
            else { continue }
            // **Twice means the split went wrong, and a wrong split reads as "no dependencies".** A
            // `.target(name:)` inside a dependency list is a head to this reader, so the list ends
            // there; refusing is what stops that passing for an empty one.
            guard map[target] == nil else { throw Refused.declaredTwice(target) }
            guard let list = body.range(of: "dependencies:") else { map[target] = []; continue }
            let names = body[list.upperBound...].matches(of: quoted)
                .compactMap { $0.output[1].substring.map(String.init) }
                .filter { ours.contains($0) && $0 != target }
            map[target] = Set(names)
        }
        return map
    }

    /// `target` and every target it reaches through `dependencies`, read off `map` — what a product built from
    /// `target` links of this package.
    public static func closure(of target: String, in map: [String: Set<String>]) -> Set<String> {
        var reached: Set<String> = [], frontier = [target]
        while let next = frontier.popLast() {
            guard reached.insert(next).inserted else { continue }
            frontier += map[next, default: []]
        }
        return reached
    }

    /// A manifest this reader refuses to read, rather than read as something it is not.
    public enum Refused: Error, CustomStringConvertible {
        case declaredTwice(String)

        public var description: String {
            switch self {
            case .declaredTwice(let target):
                "\(target) reads as declared twice: write a dependency as its plain name, not `.target(name:)`"
            }
        }
    }
}
