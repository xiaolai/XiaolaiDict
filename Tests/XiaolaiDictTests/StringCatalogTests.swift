import Foundation
import Testing
import XiaolaiDictTestSupport

/// The string catalog is what a translator is given, and `Tools/strings.sh` generates it from the
/// source. Two things have to hold for that to mean anything: what the code says must be in it,
/// and what is in it must reach the reader.
struct StringCatalogTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // XiaolaiDictTests
            .deletingLastPathComponent()                             // Tests
            .deletingLastPathComponent()                             // the repository
    }

    private var catalogURL: URL { repository.appendingPathComponent("Strings/Localizable.xcstrings") }

    private func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func swiftFiles(under directory: String) throws -> [URL] {
        let root = repository.appendingPathComponent(directory)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// A literal the compiler would extract, as it appears in the source. Interpolated ones are
    /// skipped: their key holds `%@` rather than the source text, so matching them would need the
    /// compiler's own formatting rules. `verbatim:` never matches, which is the point of it.
    ///
    /// A sentence built with `+` across lines is joined back together, because that is how the
    /// longer ones in Settings are written and skipping them would leave the longest strings in
    /// the app unguarded.
    private func localizableLiterals(in file: URL) throws -> [String] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        let patterns = ["String(localized: \"", "Text(\""]
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            for pattern in patterns where line.contains(pattern) {
                guard let start = line.range(of: pattern) else { continue }
                guard var literal = Self.literal(from: String(line[start.upperBound...])) else { continue }
                // Joined across continuations. The `+` sits at the start of the next line in this
                // codebase and at the end of the current one elsewhere, so both count.
                var at = index
                var tail = String(String(line[start.upperBound...]).dropFirst(literal.count + 1))
                while at + 1 < lines.count {
                    let next = lines[at + 1].trimmingCharacters(in: .whitespaces)
                    let continues = tail.trimmingCharacters(in: .whitespaces).hasSuffix("+") || next.hasPrefix("+")
                    guard continues, let quote = next.firstIndex(of: "\""),
                          let piece = Self.literal(from: String(next[next.index(after: quote)...]))
                    else { break }
                    literal += piece
                    at += 1
                    tail = String(next[next.index(after: quote)...].dropFirst(piece.count + 1))
                }
                guard !literal.isEmpty, !literal.contains("\\("), !literal.contains("\\\"") else { continue }
                found.append(literal)
            }
        }
        return found
    }

    /// The text up to the next unescaped quote.
    private static func literal(from rest: String) -> String? {
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// **Every string the reader sees is in the catalog.** A string added without running
    /// `make strings` is one no translator will ever see, and nothing else would say so.
    ///
    /// It reads what the source says rather than what the compiler emits, so an interpolated
    /// string is skipped and a concatenated one is rejoined. The catalog stays the source of
    /// truth; this is the guard against the common way it goes stale.
    @Test func everyLiteralTheReaderSeesIsInTheCatalog() throws {
        let strings = try #require(try catalog()["strings"] as? [String: Any])
        var missing: [String] = []
        for directory in ["Sources/XiaolaiDictUI", "Sources/XiaolaiDict"] {
            for file in try swiftFiles(under: directory) {
                for literal in try localizableLiterals(in: file) where strings[literal] == nil {
                    missing.append("\(file.lastPathComponent): \(literal)")
                }
            }
        }
        #expect(missing.isEmpty, "run `make strings`; the catalog does not have: \(missing)")
    }

    /// The catalog's source language is what the keys are written in.
    @Test func theCatalogIsWrittenInEnglish() throws {
        #expect(try catalog()["sourceLanguage"] as? String == "en")
        let strings = try #require(try catalog()["strings"] as? [String: Any])
        #expect(strings.count > 50, "only \(strings.count) strings — extraction is not finding the source")
    }

    /// **No display text in the core.** It has no view layer, so a sentence there can be shown but
    /// never extracted, and `Tools/strings.sh` would not find it.
    @Test func theCoreHoldsNoDisplayText() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/XiaolaiDictCore") {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("String(localized:") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "these belong in the view layer: \(offenders)")
    }

    /// **And a translation in the catalog reaches the reader.** The bundle carries compiled
    /// `.strings`, one directory per language, which `xcstringstool compile` writes — so this
    /// compiles a copy of the real catalog with one string translated and reads it back. Nothing
    /// is translated in the shipped catalog yet, so without this the whole path from catalog to
    /// bundle would be unexercised until the first translator finished.
    @Test func aTranslatedStringCompilesIntoSomethingTheBundleCanRead() throws {
        var contents = try catalog()
        var strings = try #require(contents["strings"] as? [String: Any])
        let key = try #require(strings.keys.sorted().first { $0.count > 20 })
        strings[key] = ["localizations": ["de": ["stringUnit": ["state": "translated", "value": "ÜBERSETZT"]]]]
        contents["strings"] = strings

        let scratch = TemporaryDirectory(named: "xiaolaidict-catalog")
        let directory = scratch.url
        let copy = scratch.appending("Localizable.xcstrings")
        try JSONSerialization.data(withJSONObject: contents).write(to: copy)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["xcstringstool", "compile", copy.path, "--output-directory", directory.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0, "xcstringstool could not compile the catalog")

        let compiled = directory.appendingPathComponent("de.lproj/Localizable.strings")
        try #require(FileManager.default.fileExists(atPath: compiled.path),
                     "no de.lproj was produced, so a translation would never reach the bundle")
        let table = try #require(NSDictionary(contentsOf: compiled) as? [String: String])
        #expect(table[key] == "ÜBERSETZT", "the compiled table does not answer with the translation")
    }
}
